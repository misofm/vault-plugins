"""Exact, fail-closed policy used by check_plugin_abi.py."""

from __future__ import annotations

import copy
import json
import re
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "scripts" / "fixtures"
ACTION_REV = "439096790e41293a4d74df32334590e943dd3f88"


def fail(message: str) -> None:
    raise AssertionError(message)


def git(git_url: str, rev: str, subdir: str = ".") -> dict[str, str]:
    return {"git": git_url, "subdir": subdir, "rev": rev}


SOURCES = {
    "MoveStdlib": git("https://github.com/MystenLabs/sui.git", "2a0becb2fcc6989e492981104af67f62f2c9511a", "crates/sui-framework/packages/move-stdlib"),
    "Sui": git("https://github.com/MystenLabs/sui.git", "2a0becb2fcc6989e492981104af67f62f2c9511a", "crates/sui-framework/packages/sui-framework"),
    "bps": git("https://github.com/unconfirmedlabs/bps.git", "4ca1972a67d35c972ca567de7b08315e3778e52b"),
    "hikida": git("https://github.com/unconfirmedlabs/hikida.git", "4abe4c1ff482655693698fa6ab8a6e2b58f8c635"),
    "miso": git("https://github.com/misonetwork/protocol.git", "6de5f9881ee62c81c57ce16832efc24dc33ae429"),
    "miso_share": git("https://github.com/misonetwork/share.git", "561cfad98e4aaa63e6b34d5a6f4c22e397c70a52"),
    "royalty_pool": git("https://github.com/misonetwork/royalty-pool.git", "2a55f9d8d47c8011ada5c74d181c807167d78da3"),
    "routed_stake": git("https://github.com/misonetwork/routed-stake.git", "b469541340109c38c12ef0fb5cb46b033c9282c7"),
    "vault": git("https://github.com/misofm/vault.git", "a171b3ad5a69868da857a361cbfb3503ff64e780"),
}
for _action in (
    "composition_royalty_pool", "recording_royalty_pool",
    "release_revenue_distributor", "composition_routed_stake",
):
    SOURCES[_action] = git(
        "https://github.com/misonetwork/protocol-actions.git", ACTION_REV, _action
    )


def dependency(name: str, test: bool = False) -> dict[str, Any]:
    value: dict[str, Any] = dict(SOURCES[name])
    if value.get("subdir") == ".":
        value.pop("subdir")
    if test:
        value["modes"] = ["test"]
    return value


MANIFESTS = {
    "composition_royalty_pool_plugin": {
        "composition_royalty_pool": dependency("composition_royalty_pool"),
        "vault": dependency("vault"), "miso": dependency("miso"),
        "royalty_pool": dependency("royalty_pool"), "hikida": dependency("hikida", True),
    },
    "recording_royalty_pool_plugin": {
        "recording_royalty_pool": dependency("recording_royalty_pool"),
        "vault": dependency("vault"), "miso": dependency("miso"),
        "royalty_pool": dependency("royalty_pool"),
    },
    "release_revenue_distributor_plugin": {
        "release_revenue_distributor": dependency("release_revenue_distributor"),
        "vault": dependency("vault"), "miso": dependency("miso"),
        "composition_royalty_pool": dependency("composition_royalty_pool", True),
        "composition_routed_stake": dependency("composition_routed_stake", True),
        "recording_royalty_pool": dependency("recording_royalty_pool", True),
        "royalty_pool": dependency("royalty_pool", True),
        "routed_stake": dependency("routed_stake", True),
    },
}
LOCK_NAMES = {
    "composition_royalty_pool_plugin": {"MoveStdlib", "Sui", "bps", "composition_royalty_pool", "composition_royalty_pool_plugin", "hikida", "miso", "miso_share", "royalty_pool", "vault"},
    "recording_royalty_pool_plugin": {"MoveStdlib", "Sui", "bps", "hikida", "miso", "miso_share", "recording_royalty_pool", "recording_royalty_pool_plugin", "royalty_pool", "vault"},
    "release_revenue_distributor_plugin": {"MoveStdlib", "Sui", "bps", "composition_routed_stake", "composition_royalty_pool", "hikida", "miso", "miso_share", "recording_royalty_pool", "release_revenue_distributor", "release_revenue_distributor_plugin", "routed_stake", "royalty_pool", "vault"},
}

COMMON_EDGES = {
    "MoveStdlib": {},
    "Sui": {"MoveStdlib": "MoveStdlib"},
    "bps": {"std": "MoveStdlib", "sui": "Sui"},
    "hikida": {"std": "MoveStdlib", "sui": "Sui"},
    "miso": {"bps": "bps", "miso_share": "miso_share", "std": "MoveStdlib", "sui": "Sui"},
    "miso_share": {"std": "MoveStdlib", "sui": "Sui"},
    "royalty_pool": {"hikida": "hikida", "std": "MoveStdlib", "sui": "Sui"},
    "routed_stake": {"royalty_pool": "royalty_pool", "std": "MoveStdlib", "sui": "Sui"},
    "vault": {"std": "MoveStdlib", "sui": "Sui"},
    "composition_royalty_pool": {
        "hikida": "hikida", "miso": "miso", "royalty_pool": "royalty_pool",
        "std": "MoveStdlib", "sui": "Sui", "vault": "vault",
    },
    "recording_royalty_pool": {
        "hikida": "hikida", "miso": "miso", "royalty_pool": "royalty_pool",
        "std": "MoveStdlib", "sui": "Sui", "vault": "vault",
    },
    "release_revenue_distributor": {
        "hikida": "hikida", "miso": "miso", "std": "MoveStdlib",
        "sui": "Sui", "vault": "vault",
    },
    "composition_routed_stake": {
        "hikida": "hikida", "miso": "miso", "routed_stake": "routed_stake",
        "royalty_pool": "royalty_pool", "std": "MoveStdlib", "sui": "Sui",
        "vault": "vault",
    },
}
LOCK_EDGES = {
    "composition_royalty_pool_plugin": {
        **{name: COMMON_EDGES[name] for name in LOCK_NAMES["composition_royalty_pool_plugin"] if name in COMMON_EDGES},
        "composition_royalty_pool_plugin": {
            "composition_royalty_pool": "composition_royalty_pool", "hikida": "hikida",
            "miso": "miso", "royalty_pool": "royalty_pool", "std": "MoveStdlib",
            "sui": "Sui", "vault": "vault",
        },
    },
    "recording_royalty_pool_plugin": {
        **{name: COMMON_EDGES[name] for name in LOCK_NAMES["recording_royalty_pool_plugin"] if name in COMMON_EDGES},
        "recording_royalty_pool_plugin": {
            "miso": "miso", "recording_royalty_pool": "recording_royalty_pool",
            "royalty_pool": "royalty_pool", "std": "MoveStdlib", "sui": "Sui",
            "vault": "vault",
        },
    },
    "release_revenue_distributor_plugin": {
        **{name: COMMON_EDGES[name] for name in LOCK_NAMES["release_revenue_distributor_plugin"] if name in COMMON_EDGES},
        "release_revenue_distributor_plugin": {
            "composition_routed_stake": "composition_routed_stake",
            "composition_royalty_pool": "composition_royalty_pool", "miso": "miso",
            "recording_royalty_pool": "recording_royalty_pool",
            "release_revenue_distributor": "release_revenue_distributor",
            "routed_stake": "routed_stake", "royalty_pool": "royalty_pool",
            "std": "MoveStdlib", "sui": "Sui", "vault": "vault",
        },
    },
}


def addr(suffix: str) -> str:
    return "0x" + suffix.rjust(64, "0")


COMMON_IDS = {
    "std": addr("1"), "sui": addr("2"),
    "miso": "0x5788d67e76b7e6de85ba335731a068ef7cbac7b17504577f293d41c5ba3d1ff0",
    # The compiler assigns an unpublished dependency a deterministic symbolic
    # address; exact Git/source checks prove that this is not a published ID.
    "vault": addr("ff13"),
}
ORIGINAL_IDS = {
    "composition_royalty_pool_plugin": {
        **COMMON_IDS, "composition_royalty_pool_plugin": addr("0"),
        "composition_royalty_pool": addr("e451"),
        "royalty_pool": "0x8021942b5e91c5ef5e383ad481102ee96f52dd77b9b3dbcdf06bb133cd7c91ed",
    },
    "recording_royalty_pool_plugin": {
        **COMMON_IDS, "recording_royalty_pool_plugin": addr("0"),
        "recording_royalty_pool": addr("a0b7"),
        "royalty_pool": "0x8021942b5e91c5ef5e383ad481102ee96f52dd77b9b3dbcdf06bb133cd7c91ed",
    },
    "release_revenue_distributor_plugin": {
        **COMMON_IDS, "release_revenue_distributor_plugin": addr("0"),
        "release_revenue_distributor": addr("c4c2"),
    },
}

TypeShape = Any


def tp(name: str) -> TypeShape:
    return ("tp", name)


def dt(package: str, module: str, name: str, *args: tuple[bool, TypeShape]) -> TypeShape:
    return ("dt", package, module, name, args)


def ref(mutable: bool, value: TypeShape) -> TypeShape:
    return ("ref", mutable, value)


def vec(value: TypeShape) -> TypeShape:
    return ("vec", value)


@dataclass(frozen=True)
class FunctionSpec:
    visibility: str
    entry: bool
    type_parameters: tuple[str, ...]
    parameters: tuple[tuple[str, TypeShape], ...]
    returns: tuple[TypeShape, ...] = ()


def fn(visibility: str, entry: bool, tps: tuple[str, ...], params: list[tuple[str, TypeShape]], returns: tuple[TypeShape, ...] = ()) -> FunctionSpec:
    return FunctionSpec(visibility, entry, tps, tuple(params), returns)


def schemas(package: str) -> tuple[dict[str, FunctionSpec], str, tuple[str, ...]]:
    if package.startswith("composition_"):
        share, currency = tp("CompositionShare"), tp("Currency")
        cap = dt("miso", "composition", "CompositionAdminCap", (True, share))
        subject = dt("miso", "composition", "Composition", (True, share))
        pool = dt("royalty_pool", "pool", "RoyaltyPool", (True, share), (True, currency))
        subject_name, install_tps = "composition", ("CompositionShare",)
        operation_tps = ("CompositionShare", "Currency")
        operations, action = ("receive_and_deposit", "redeem_and_deposit"), "composition_royalty_pool"
    elif package.startswith("recording_"):
        share, composition_share, currency = tp("RecordingShare"), tp("CompositionShare"), tp("Currency")
        cap = dt("miso", "recording", "RecordingAdminCap", (True, share))
        subject = dt("miso", "recording", "Recording", (True, share), (True, composition_share))
        pool = dt("royalty_pool", "pool", "RoyaltyPool", (True, share), (True, currency))
        subject_name, install_tps = "recording", ("RecordingShare",)
        operation_tps = ("RecordingShare", "CompositionShare", "Currency")
        operations, action = ("receive_and_deposit", "redeem_and_deposit"), "recording_royalty_pool"
    else:
        currency, pool = tp("Currency"), None
        cap = dt("miso", "release", "ReleaseAdminCap")
        subject = dt("miso", "release", "Release")
        subject_name, install_tps, operation_tps = "release", (), ("Currency",)
        operations, action = ("receive_and_distribute", "redeem_all_and_distribute"), "release_revenue_distributor"
    vault = dt("vault", "vault", "Vault", (False, cap))
    admin = dt("vault", "vault", "VaultAdminCap", (True, cap))
    result = {
        "install": fn("Public", False, install_tps, [("vault", ref(True, vault)), ("vault_admin_cap", ref(False, admin))]),
        "uninstall": fn("Public", False, install_tps, [("vault", ref(True, vault)), ("vault_admin_cap", ref(False, admin))]),
        "is_installed": fn("Public", False, install_tps, [("vault", ref(False, vault))], (("primitive", "bool"),)),
    }
    coin = dt("sui", "coin", "Coin", (True, currency))
    receiving = dt("sui", "transfer", "Receiving", (True, coin))
    for operation in operations:
        params = [("vault", ref(True, vault)), (subject_name, ref(True, subject))]
        if pool is not None:
            params.append(("pool", ref(True, pool)))
        if operation.startswith("receive"):
            params.append(("coins", vec(receiving)))
        elif pool is not None:
            params.append(("value", ("primitive", "u64")))
        else:
            params.append(("root", ref(False, dt("sui", "accumulator", "AccumulatorRoot"))))
        result[operation] = fn("Private", True, operation_tps, params)
        result[f"execute_{operation}"] = fn("Private", False, operation_tps, params)
    return result, action, operations


PACKAGES = {package: schemas(package) for package in MANIFESTS}


def parse_toml(path: Path) -> dict[str, Any]:
    try:
        return tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as error:
        fail(f"{path}: invalid or duplicate TOML declaration: {error}")


def check_manifest(package: str, value: dict[str, Any]) -> None:
    metadata = value.get("package")
    if not isinstance(metadata, dict) or metadata.get("name") != package:
        fail(f"{package}: package identity drift")
    if metadata.get("edition") != "2024" or metadata.get("license") != "Apache 2.0":
        fail(f"{package}: edition/license drift")
    if value.get("dependencies") != MANIFESTS[package]:
        fail(f"{package}: exact manifest dependency allowlist mismatch")
    unexpected = {"addresses", "dev-dependencies", "environments"} & set(value)
    if unexpected:
        fail(f"{package}: unexpected manifest sections {sorted(unexpected)}")


def check_lock(package: str, value: dict[str, Any]) -> None:
    if value.get("move") != {"version": 4}:
        fail(f"{package}: Move.lock format drift")
    pinned = value.get("pinned")
    if not isinstance(pinned, dict) or set(pinned) != {"testnet"}:
        fail(f"{package}: lock must contain exactly testnet")
    packages = pinned["testnet"]
    if not isinstance(packages, dict) or set(packages) != LOCK_NAMES[package]:
        fail(f"{package}: exact lock package allowlist mismatch")
    for name, item in packages.items():
        if not isinstance(item, dict) or set(item) != {
            "source", "use_environment", "manifest_digest", "deps"
        }:
            fail(f"{package}: exact lock entry keys mismatch for {name}")
        if item.get("use_environment") != "testnet":
            fail(f"{package}: malformed lock entry {name}")
        digest = item.get("manifest_digest")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9A-F]{64}", digest) is None:
            fail(f"{package}: invalid manifest_digest for {name}")
        expected = {"root": True} if name == package else SOURCES.get(name)
        if item.get("source") != expected:
            fail(f"{package}: disallowed local/override/revision for {name}")
        deps = item.get("deps")
        if deps != LOCK_EDGES[package][name]:
            fail(f"{package}: exact dependency-edge map mismatch for {name}")


def check_lock_bytes_unchanged(package: str, before: bytes, after: bytes) -> None:
    if after != before:
        fail(f"{package}: compiler normalized or mutated Move.lock bytes")


def shape(value: object) -> TypeShape:
    if isinstance(value, str):
        return ("primitive", value)
    if not isinstance(value, dict) or len(value) != 1:
        fail(f"malformed ABI type {value!r}")
    if "NamedTypeParameter" in value:
        return tp(str(value["NamedTypeParameter"]))
    if "Reference" in value:
        item = value["Reference"]
        if not isinstance(item, list) or len(item) != 2 or not isinstance(item[0], bool):
            fail(f"malformed ABI reference {value!r}")
        return ref(item[0], shape(item[1]))
    if "vector" in value:
        return vec(shape(value["vector"]))
    if "Datatype" in value:
        item = value["Datatype"]
        if not isinstance(item, dict) or set(item) != {"module", "name", "type_arguments"}:
            fail(f"malformed ABI datatype {value!r}")
        module, arguments = item["module"], item["type_arguments"]
        if not isinstance(module, dict) or set(module) != {"address", "name"} or not isinstance(arguments, list):
            fail(f"malformed ABI datatype module {value!r}")
        parsed = []
        for argument in arguments:
            if not isinstance(argument, dict) or set(argument) != {"phantom", "argument"} or not isinstance(argument["phantom"], bool):
                fail(f"malformed ABI type argument {argument!r}")
            parsed.append((argument["phantom"], shape(argument["argument"])))
        return dt(str(module["address"]), str(module["name"]), str(item["name"]), *parsed)
    fail(f"unknown ABI type encoding {value!r}")


def check_function(label: str, value: object, expected: FunctionSpec) -> None:
    if not isinstance(value, dict):
        fail(f"{label}: malformed function summary")
    type_parameters, parameters, returns = (
        value.get("type_parameters"), value.get("parameters"), value.get("return_")
    )
    if not all(isinstance(item, list) for item in (type_parameters, parameters, returns)):
        fail(f"{label}: incomplete function summary")
    got_tps = []
    for parameter in type_parameters:
        if not isinstance(parameter, dict) or set(parameter) != {"name", "constraints"} or parameter["constraints"] != []:
            fail(f"{label}: malformed/constrained type parameter")
        got_tps.append(str(parameter["name"]))
    got_params = []
    for parameter in parameters:
        if not isinstance(parameter, dict) or not isinstance(parameter.get("name"), str) or "type_" not in parameter:
            fail(f"{label}: malformed parameter")
        got_params.append((parameter["name"], shape(parameter["type_"])))
    got = FunctionSpec(
        str(value.get("visibility")), bool(value.get("entry")), tuple(got_tps),
        tuple(got_params), tuple(shape(item) for item in returns),
    )
    if got != expected:
        fail(f"{label}: exact ABI mismatch\nexpected={expected!r}\ngot={got!r}")


def has_witness(value: object) -> bool:
    if isinstance(value, list):
        return any(has_witness(item) for item in value)
    if not isinstance(value, dict):
        return False
    datatype = value.get("Datatype")
    if isinstance(datatype, dict) and datatype.get("name") == "Witness":
        return True
    return any(has_witness(item) for item in value.values())


def check_witness(package: str, value: dict[str, Any]) -> None:
    functions, structs = value.get("functions"), value.get("structs")
    if not isinstance(functions, dict) or not isinstance(structs, dict):
        fail(f"{package}::witness: malformed summary")
    for name, function in functions.items():
        if not isinstance(function, dict):
            fail(f"{package}::witness::{name}: malformed function")
        external = function.get("visibility") == "Public" or function.get("entry") is True
        if external and has_witness(function.get("parameters", [])):
            fail(f"{package}::witness::{name}: external Witness consumer")
        if external and has_witness(function.get("return_", [])):
            fail(f"{package}::witness::{name}: external Witness producer")
    if set(functions) != {"new"} or set(structs) != {"Witness"}:
        fail(f"{package}::witness: exact APIs must be functions={{new}}, structs={{Witness}}")
    witness = structs["Witness"]
    if not isinstance(witness, dict) or witness.get("abilities") != ["Drop"] or witness.get("type_parameters") != []:
        fail(f"{package}::witness::Witness: exact drop-only zero-arity schema required")
    check_function(
        f"{package}::witness::new", functions["new"],
        fn("Package", False, (), [], (dt(package, "witness", "Witness"),)),
    )


def function_block(disassembly: str, name: str) -> list[str]:
    pattern = re.compile(rf"^(?:(?:public(?:\(friend\))?|entry)\s+)?{re.escape(name)}(?:<[^>]+>)?\(")
    lines = disassembly.splitlines()
    starts = [index for index, line in enumerate(lines) if pattern.match(line.strip())]
    if len(starts) != 1:
        fail(f"{name}: expected exactly one disassembled function, found {len(starts)}")
    start = starts[0]
    ends = [index for index in range(start + 1, len(lines)) if lines[index] == "}"]
    if not ends:
        fail(f"{name}: unterminated disassembly")
    return lines[start : ends[0] + 1]


def instructions(block: list[str]) -> tuple[list[str], list[str]]:
    opcodes, calls, expected_index = [], [], 0
    for offset, line in enumerate(block):
        stripped = line.strip()
        if offset == 0 or not stripped or stripped == "}" or re.match(r"^(?:L\d+:|B\d+:)", stripped):
            continue
        match = re.match(r"^(\d+): (.+)$", stripped)
        if match is None:
            fail(f"unparsed disassembly line {line!r}")
        if int(match.group(1)) != expected_index:
            fail(f"non-contiguous instruction {line!r}")
        expected_index += 1
        instruction = match.group(2)
        opcode = re.match(r"^([A-Za-z][A-Za-z0-9]*)(?:\[[^\]]+\])?", instruction)
        if opcode is None:
            fail(f"unparsed instruction {instruction!r}")
        opcodes.append(opcode.group(1))
        if opcode.group(1) == "Call":
            call = re.match(
                r"^Call ((?:[A-Za-z_][A-Za-z0-9_]*::)?[A-Za-z_][A-Za-z0-9_]*)",
                instruction,
            )
            if call is None:
                fail(f"unparsed call {instruction!r}")
            calls.append(call.group(1))
    if not opcodes:
        fail("no instructions parsed")
    return opcodes, calls


def check_bytecode(disassembly: str, name: str, expected_opcodes: list[str], expected_calls: list[str]) -> None:
    opcodes, calls = instructions(function_block(disassembly, name))
    if opcodes != expected_opcodes or calls != expected_calls:
        fail(f"{name}: exact bytecode mismatch: opcodes={opcodes}, calls={calls}")


def unique_summary(root: Path, package: str, module: str) -> Path:
    matches = []
    for path in root.rglob(f"{module}.json"):
        try:
            value = json.loads(path.read_text())
        except json.JSONDecodeError as error:
            fail(f"invalid summary JSON {path}: {error}")
        if isinstance(value, dict) and value.get("id") == {"address": package, "name": module}:
            matches.append(path)
    if len(matches) != 1:
        fail(f"{package}::{module}: expected one fresh summary, found {len(matches)}")
    return matches[0]


def check_ids(package: str, root: Path) -> None:
    mapping = json.loads((root / "address_mapping.json").read_text())
    if mapping != ORIGINAL_IDS[package]:
        fail(
            f"{package}: exact resolved original-ID allowlist mismatch: "
            f"expected={ORIGINAL_IDS[package]!r}, got={mapping!r}"
        )
    ids = [
        value for name, value in mapping.items()
        if name not in {package, "std", "sui"} and value != addr("0")
    ]
    if len(ids) != len(set(ids)):
        fail(f"{package}: duplicate resolved original IDs")


def check_package(package: str) -> None:
    package_dir = ROOT / package
    lock_path = package_dir / "Move.lock"
    lock_before = lock_path.read_bytes()
    check_manifest(package, parse_toml(package_dir / "Move.toml"))
    check_lock(package, parse_toml(lock_path))
    subprocess.run(
        ["sui", "move", "build", "--build-env", "testnet", "--force", "--warnings-are-errors", "--lint", "--disassemble"],
        cwd=package_dir, check=True, stdout=subprocess.DEVNULL,
    )
    with tempfile.TemporaryDirectory(prefix=f"{package}-summary-") as temporary:
        root = Path(temporary)
        subprocess.run(
            ["sui", "move", "summary", "--build-env", "testnet", "--force", "--warnings-are-errors", "--lint", "--disassemble", "--output-directory", str(root)],
            cwd=package_dir, check=True, stdout=subprocess.DEVNULL,
        )
        abi = json.loads(unique_summary(root, package, package).read_text())
        witness = json.loads(unique_summary(root, package, "witness").read_text())
        check_ids(package, root)
    check_manifest(package, parse_toml(package_dir / "Move.toml"))
    check_lock(package, parse_toml(lock_path))
    check_lock_bytes_unchanged(package, lock_before, lock_path.read_bytes())
    expected, action, operations = PACKAGES[package]
    functions = abi.get("functions")
    if not isinstance(functions, dict) or set(functions) != set(expected):
        fail(f"{package}: exact production function API mismatch")
    for name, spec in expected.items():
        check_function(f"{package}::{name}", functions[name], spec)
    check_witness(package, witness)
    disassembly_dir = package_dir / "build" / package / "disassembly"
    disassembly = (disassembly_dir / f"{package}.mvb").read_text()
    witness_disassembly = (disassembly_dir / "witness.mvb").read_text()
    check_bytecode(witness_disassembly, "new", ["LdFalse", "Pack", "Ret"], [])
    check_bytecode(disassembly, "install", ["MoveLoc", "MoveLoc", "Call", "Call", "Ret"], ["witness::new", "vault::authorize_plugin"])
    check_bytecode(disassembly, "uninstall", ["MoveLoc", "MoveLoc", "Call", "Ret"], ["vault::revoke_plugin"])
    check_bytecode(disassembly, "is_installed", ["MoveLoc", "Call", "Ret"], ["vault::is_plugin_authorized"])
    for operation in operations:
        parameter_count = len(expected[operation].parameters)
        executor = f"execute_{operation}"
        check_bytecode(
            disassembly, operation,
            ["MoveLoc"] * parameter_count + ["Call", "Ret"], [executor],
        )
        check_bytecode(
            disassembly, executor,
            ["CopyLoc", "Call", "Call", "StLoc", "StLoc", "MoveLoc", "ImmBorrowLoc"]
            + ["MoveLoc"] * (parameter_count - 2)
            + ["Call", "MoveLoc", "MoveLoc", "MoveLoc", "Call", "Ret"],
            ["witness::new", "vault::borrow_as_plugin", f"{action}::{operation}", "vault::put_back"],
        )


def rejected(label: str, action: Callable[[], None]) -> None:
    try:
        action()
    except (AssertionError, tomllib.TOMLDecodeError):
        return
    fail(f"self-test accepted adversarial mutation: {label}")


def external_constructor_is_opaque() -> None:
    with tempfile.TemporaryDirectory(prefix="witness-attacker-") as temporary:
        root = Path(temporary)
        (root / "sources").mkdir()
        (root / "Move.toml").write_text(
            "[package]\nname = \"witness_attacker\"\nedition = \"2024\"\n"
            "[dependencies]\ncomposition_royalty_pool_plugin = { local = \""
            + str(ROOT / "composition_royalty_pool_plugin") + "\" }\n"
        )
        (root / "sources" / "attacker.move").write_text(
            (FIXTURES / "external_witness_attacker.move").read_text()
        )
        result = subprocess.run(
            ["sui", "move", "build", "--build-env", "testnet", "--force", "--warnings-are-errors", "--lint"],
            cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        output = result.stdout.lower()
        if result.returncode == 0:
            fail("external package compiled the package-private Witness constructor")
        if "new" not in output or not any(word in output for word in ("visibility", "unbound", "invalid")):
            fail("external constructor compile-negative failed ambiguously")


def valid_lock_fixture(package: str) -> dict[str, Any]:
    entries = {}
    for name in LOCK_NAMES[package]:
        source = {"root": True} if name == package else SOURCES[name]
        entries[name] = {
            "source": source,
            "use_environment": "testnet",
            "manifest_digest": "A" * 64,
            "deps": copy.deepcopy(LOCK_EDGES[package][name]),
        }
    return {"move": {"version": 4}, "pinned": {"testnet": entries}}


def run_self_test() -> None:
    valid = json.loads((FIXTURES / "witness_package_private.json").read_text())
    check_witness("fixture_package_private", valid)
    for name in ("witness_public_forge.json", "witness_public_input.json", "witness_public_output_alias.json"):
        value = json.loads((FIXTURES / name).read_text())
        rejected(name, lambda value=value: check_witness("fixture", value))

    expected = PACKAGES["release_revenue_distributor_plugin"][0]["redeem_all_and_distribute"]
    base = {"visibility": "Private", "entry": True, "type_parameters": [{"name": "Currency", "constraints": []}], "parameters": [], "return_": []}
    forbidden = {
        "custom_authority": {"Datatype": {"module": {"address": "evil", "name": "auth"}, "name": "Authority", "type_arguments": []}},
        "mutable_uid": {"Reference": [True, {"Datatype": {"module": {"address": "sui", "name": "object"}, "name": "UID", "type_arguments": []}}]},
        "destination": "address",
        "tx_context": {"Reference": [True, {"Datatype": {"module": {"address": "sui", "name": "tx_context"}, "name": "TxContext", "type_arguments": []}}]},
        "vault_admin_cap": {"Datatype": {"module": {"address": "vault", "name": "vault"}, "name": "VaultAdminCap", "type_arguments": []}},
    }
    for name, type_value in forbidden.items():
        value = copy.deepcopy(base)
        value["parameters"].append({"name": name, "type_": type_value})
        rejected(name, lambda value=value: check_function(f"fixture::{name}", value, expected))

    side_effect = "public install(v: u8) {\nB0:\n\t0: MoveLoc[0](v: u8)\n\t1: Call evil::side_effect()\n\t2: Ret\n}\n"
    rejected("install side effects", lambda: check_bytecode(side_effect, "install", ["MoveLoc", "Ret"], []))
    malformed = "entry op() {\nB0:\n\tthis is not an instruction\n}\n"
    rejected("unparsed instruction", lambda: instructions(function_block(malformed, "op")))
    malicious = "execute_op() {\nB0:\n\t0: Call evil::op()\n\t1: Ret\n}\n"
    rejected("same-named malicious Action", lambda: check_bytecode(malicious, "execute_op", ["Call", "Ret"], ["action::op"]))

    drift = {"package": {"name": "composition_royalty_pool_plugin", "edition": "2024", "license": "Apache 2.0"}, "dependencies": copy.deepcopy(MANIFESTS["composition_royalty_pool_plugin"])}
    drift["dependencies"]["composition_royalty_pool"]["rev"] = "0" * 40
    rejected("dependency drift", lambda: check_manifest("composition_royalty_pool_plugin", drift))
    lock_package = "composition_royalty_pool_plugin"
    valid_lock = valid_lock_fixture(lock_package)
    check_lock(lock_package, valid_lock)
    local_lock = copy.deepcopy(valid_lock)
    local_lock["pinned"]["testnet"]["vault"]["source"] = {"local": "../vault"}
    rejected("production local", lambda: check_lock(lock_package, local_lock))

    missing_digest = copy.deepcopy(valid_lock)
    del missing_digest["pinned"]["testnet"]["vault"]["manifest_digest"]
    rejected("missing manifest digest", lambda: check_lock(lock_package, missing_digest))
    wrong_digest = copy.deepcopy(valid_lock)
    wrong_digest["pinned"]["testnet"]["vault"]["manifest_digest"] = "not-64-hex"
    rejected("wrong manifest digest", lambda: check_lock(lock_package, wrong_digest))
    wrong_edge = copy.deepcopy(valid_lock)
    wrong_edge["pinned"]["testnet"]["vault"]["deps"] = {"std": "MoveStdlib"}
    rejected("valid but wrong dependency edge", lambda: check_lock(lock_package, wrong_edge))
    extra_key = copy.deepcopy(valid_lock)
    extra_key["pinned"]["testnet"]["vault"]["override"] = True
    rejected("extra lock entry key", lambda: check_lock(lock_package, extra_key))
    rejected(
        "compiler-normalized lock drift",
        lambda: check_lock_bytes_unchanged(lock_package, b"canonical\n", b"normalized\n"),
    )
    rejected("duplicate TOML", lambda: tomllib.loads("[dependencies]\na = { local = \"a\" }\na = { local = \"b\" }\n"))
    with tempfile.TemporaryDirectory(prefix="summary-fixture-") as temporary:
        root = Path(temporary)
        rejected("stale/missing summary", lambda: unique_summary(root, "p", "m"))
        for index in (1, 2):
            path = root / str(index) / "m.json"
            path.parent.mkdir()
            path.write_text(json.dumps({"id": {"address": "p", "name": "m"}}))
        rejected("duplicate summary", lambda: unique_summary(root, "p", "m"))
    external_constructor_is_opaque()


def run(arguments: list[str]) -> int:
    try:
        run_self_test()
        if arguments == ["--self-test"]:
            print("plugin ABI gate adversarial self-test passed")
            return 0
        if arguments:
            fail(f"unsupported arguments: {' '.join(arguments)}")
        for package in PACKAGES:
            check_package(package)
    except (AssertionError, FileNotFoundError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"plugin ABI gate failed: {error}", file=sys.stderr)
        return 1
    print("plugin ABI gate passed for all retained packages")
    return 0
