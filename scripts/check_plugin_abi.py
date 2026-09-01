#!/usr/bin/env python3
"""Compiler-backed ABI and bytecode gate for retained Vault plugins."""

from __future__ import annotations

import json
import copy
import re
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from plugin_abi_policy import run as run_hardened_gate


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "scripts" / "fixtures"
PACKAGES = {
    "composition_royalty_pool_plugin": (
        "composition_royalty_pool",
        ("receive_and_deposit", "redeem_and_deposit"),
    ),
    "recording_royalty_pool_plugin": (
        "recording_royalty_pool",
        ("receive_and_deposit", "redeem_and_deposit"),
    ),
    "release_revenue_distributor_plugin": (
        "release_revenue_distributor",
        ("receive_and_distribute", "redeem_all_and_distribute"),
    ),
}
FORBIDDEN_OPERATIONAL_NAMES = {
    "address",
    "destination",
    "recipient",
    "sender",
    "tx_context",
    "vault_admin_cap",
}
ALLOWED_EXECUTOR_OPS = {
    "Call",
    "CopyLoc",
    "ImmBorrowLoc",
    "MoveLoc",
    "Ret",
    "StLoc",
}
ALLOWED_ENTRY_OPS = {"Call", "MoveLoc", "Ret"}


def fail(message: str) -> None:
    raise AssertionError(message)


def function_block(disassembly: str, name: str) -> list[str]:
    marker = f"{name}<"
    fallback = f"{name}("
    lines = disassembly.splitlines()
    start = next(
        (
            index
            for index, line in enumerate(lines)
            if (marker in line or fallback in line)
            and line.rstrip().endswith("{")
            and not line.lstrip().startswith("use ")
        ),
        None,
    )
    if start is None:
        fail(f"missing disassembled function {name}")
    end = next(
        (index for index in range(start + 1, len(lines)) if lines[index] == "}"),
        None,
    )
    if end is None:
        fail(f"unterminated disassembled function {name}")
    return lines[start : end + 1]


def instructions(block: list[str]) -> tuple[list[str], list[str]]:
    opcodes: list[str] = []
    calls: list[str] = []
    for line in block:
        stripped = line.strip()
        if not stripped or not stripped[0].isdigit() or ": " not in stripped:
            continue
        instruction = stripped.split(": ", 1)[1]
        opcode = instruction.split(" ", 1)[0].split("[", 1)[0]
        opcodes.append(opcode)
        if opcode == "Call":
            calls.append(instruction.removeprefix("Call ").split("(", 1)[0].split("<", 1)[0])
    return opcodes, calls


def abi_values(value: object) -> str:
    values: list[str] = []

    def visit(current: object) -> None:
        if isinstance(current, str):
            values.append(current.lower())
        elif isinstance(current, list):
            for item in current:
                visit(item)
        elif isinstance(current, dict):
            for item in current.values():
                visit(item)

    visit(value)
    return " ".join(values)


def contains_witness_type(value: object) -> bool:
    if isinstance(value, list):
        return any(contains_witness_type(item) for item in value)
    if not isinstance(value, dict):
        return False
    datatype = value.get("Datatype")
    if isinstance(datatype, dict) and datatype.get("name") == "Witness":
        return True
    return any(contains_witness_type(item) for item in value.values())


def check_witness_abi(package: str, witness_abi: dict[str, object]) -> None:
    structs = witness_abi.get("structs")
    functions = witness_abi.get("functions")
    if not isinstance(structs, dict) or not isinstance(functions, dict):
        fail(f"{package}::witness: malformed ABI summary")

    witness = structs.get("Witness")
    if not isinstance(witness, dict) or witness.get("abilities") != ["Drop"]:
        fail(f"{package}::witness::Witness must have exactly drop")

    for name, function in functions.items():
        if not isinstance(function, dict):
            fail(f"{package}::witness::{name}: malformed function ABI")
        if not contains_witness_type(function.get("return_", [])):
            continue
        if function.get("visibility") == "Public" or function.get("entry"):
            fail(
                f"{package}::witness::{name}: externally callable function must not return Witness"
            )

    constructor = functions.get("new")
    if (
        not isinstance(constructor, dict)
        or constructor.get("visibility") != "Package"
        or constructor.get("entry")
        or not contains_witness_type(constructor.get("return_", []))
    ):
        fail(f"{package}::witness::new must be package-private and return Witness")


def run_self_test() -> None:
    package_private = json.loads((FIXTURES / "witness_package_private.json").read_text())
    public_forge = json.loads((FIXTURES / "witness_public_forge.json").read_text())
    check_witness_abi("fixture_package_private", package_private)
    try:
        check_witness_abi("fixture_public_forge", public_forge)
    except AssertionError as error:
        if "forge: externally callable function must not return Witness" not in str(error):
            raise
    else:
        fail("adversarial public forge(): Witness fixture was accepted")


def check_package(package: str, action_module: str, operations: tuple[str, ...]) -> None:
    package_dir = ROOT / package
    subprocess.run(
        [
            "sui",
            "move",
            "build",
            "--build-env",
            "testnet",
            "--warnings-are-errors",
            "--lint",
            "--disassemble",
        ],
        cwd=package_dir,
        check=True,
        stdout=subprocess.DEVNULL,
    )

    summary_root = package_dir / "package_summaries"
    module_summary = next(summary_root.rglob(f"{package}.json"))
    summary_dir = module_summary.parent
    abi = json.loads(module_summary.read_text())
    witness_abi = json.loads((summary_dir / "witness.json").read_text())
    disassembly = (
        package_dir / "build" / package / "disassembly" / f"{package}.mvb"
    ).read_text()
    source = (package_dir / "sources" / f"{package}.move").read_text()

    expected_functions = {
        "install",
        "uninstall",
        "is_installed",
        *(operations),
        *(f"execute_{operation}" for operation in operations),
    }
    functions = abi["functions"]
    if set(functions) != expected_functions:
        fail(f"{package}: unexpected production functions: {sorted(set(functions) ^ expected_functions)}")

    for name in ("install", "uninstall", "is_installed"):
        function = functions[name]
        if function["visibility"] != "Public" or function["entry"]:
            fail(f"{package}::{name}: installation/view API must be composable public, not entry")

    for operation in operations:
        entry = functions[operation]
        if entry["visibility"] != "Private" or not entry["entry"] or entry["return_"]:
            fail(f"{package}::{operation}: operation must be private entry and unit-returning")
        entry_text = abi_values(entry["parameters"])
        if any(name in entry_text for name in FORBIDDEN_OPERATIONAL_NAMES):
            fail(f"{package}::{operation}: forbidden authority/address parameter")

        executor_name = f"execute_{operation}"
        executor = functions[executor_name]
        if executor["visibility"] != "Private" or executor["entry"] or executor["return_"]:
            fail(f"{package}::{executor_name}: executor must remain private and unit-returning")
        executor_text = abi_values(executor["parameters"])
        if any(name in executor_text for name in FORBIDDEN_OPERATIONAL_NAMES):
            fail(f"{package}::{executor_name}: forbidden authority/address parameter")

        entry_ops, entry_calls = instructions(function_block(disassembly, operation))
        if set(entry_ops) - ALLOWED_ENTRY_OPS or entry_calls != [executor_name]:
            fail(f"{package}::{operation}: entry must only forward to {executor_name}")

        executor_ops, executor_calls = instructions(function_block(disassembly, executor_name))
        expected_calls = [
            "witness::new",
            "vault::borrow_as_plugin",
            f"{action_module}::{operation}",
            "vault::put_back",
        ]
        if set(executor_ops) - ALLOWED_EXECUTOR_OPS or executor_calls != expected_calls:
            fail(
                f"{package}::{executor_name}: expected only witness, borrow, Action, put_back; "
                f"got calls={executor_calls}, opcodes={executor_ops}"
            )

    if "vault_id" in source:
        fail(f"{package}: VaultAdminCap::vault_id access is forbidden")
    check_witness_abi(package, witness_abi)


def main() -> int:
    return run_hardened_gate(sys.argv[1:])


if __name__ == "__main__":
    raise SystemExit(main())
