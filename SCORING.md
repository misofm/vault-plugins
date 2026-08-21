# Plugin Safety Scoring

This repository is intended to evolve into a curated plugin directory similar
to the WordPress plugin directory: packages are discoverable, but installation
decisions are informed by reproducible checks, explicit permissions, and a
visible safety score.

The score is advisory and generated offchain. The vault itself only knows that
a witness type was installed; it cannot inspect bytecode quality or determine
which package version is currently executing.

## Hard rejection checks

A package is incompatible with the directory if any of these checks fail:

- deployed bytecode cannot be matched to published source;
- the canonical type is not `0xpkg::witness::Witness`;
- `Witness` has `copy`, `store`, or `key` instead of exactly `drop`;
- downstream packages can construct or receive the witness;
- privileged functions return the witness or `&mut UID`;
- the manifest omits a dependency or requested permission;
- known malicious behavior or an unresolved critical vulnerability exists.

## Proposed 100-point score

| Category | Weight | Evidence |
|---|---:|---|
| Upgrade safety | 40 | Immutable package; otherwise upgrade policy, `UpgradeCap` owner, multisig threshold, timelock, and upgrade history |
| Source and dependencies | 20 | Reproducible source-to-bytecode match, pinned dependencies, and transitive upgrade analysis |
| Authority surface | 20 | Entry-only privileged endpoints, bounded operations, no authority escape, and least-privilege object permissions |
| Assurance | 15 | Independent audits, adversarial tests, coverage, formal properties, and reviewed commit |
| Operations | 5 | Maintainer history, disclosure process, monitoring, and incident response |

Immutability receives the largest weight because `TypeName` does not bind an
installed witness to a bytecode version. `with_defining_ids<Witness>()` names
the package version that first introduced the type, and upgraded code retains
access to that same type.

Suggested score caps:

- single-signer, unrestricted `UpgradeCap`: maximum 50;
- unverified transitive dependency source: maximum 60;
- no independent audit: maximum 80;
- immutable package with reproducible bytecode: no upgrade-related cap.

## Permission declaration

Each plugin manifest should enumerate its authority explicitly:

- target classes: Composition, Recording, and/or Release;
- dynamic-field namespaces read, written, or removed;
- objects or funds it can receive or transfer;
- permissionless versus admin-triggered operations;
- external packages and shared objects touched;
- whether privileged endpoints are composable or entry-only.

Clients should display this declaration alongside the score before asking for
the `VaultAdminCap` signature required to install the plugin.

## Registry record

A future registry entry should include at least:

```json
{
  "network": "mainnet",
  "originalPackageId": "0x...",
  "witnessType": "0x...::witness::Witness",
  "sourceRepository": "https://github.com/...",
  "sourceCommit": "...",
  "upgradeStatus": "immutable",
  "permissions": ["composition.dynamic_fields.write"],
  "audits": [],
  "score": 0,
  "scoredAt": "..."
}
```

Scores must be reproducible from recorded evidence and recalculated whenever a
package, dependency, upgrade authority, audit, or incident changes.
