# Miso Vault Plugins

Thin, first-party adapters that let a Miso capability held by
[`misofm/vault`](https://github.com/misofm/vault) execute a matching Miso
Action.

## Extensions, Actions, and plugins

- **Extensions** attach declarative state to a protocol object. They do not
  define an operational custody path.
- **Actions** own domain workflows. They are public, composable raw-cap
  functions and contain all validation, arithmetic, transfers, events, and
  derivation logic.
- **Vault plugins** only adapt Vault custody to Actions. An administrator
  installs or uninstalls a package-local witness. Each operation then borrows
  the exact raw cap, calls one matching Action, and immediately puts the cap
  back.

There is no Party plugin. Party wallet behavior is an Action. There is also no
Composition routed-stake plugin: its lifecycle is a governance Action, while
the routed-stake core already exposes permissionless sweeping.

## Retained packages

| Package | Permissionless operations after install |
|---|---|
| [`composition_royalty_pool_plugin`](./composition_royalty_pool_plugin) | Receive or redeem Composition revenue into its canonical royalty pool. |
| [`recording_royalty_pool_plugin`](./recording_royalty_pool_plugin) | Receive or redeem Recording revenue into its canonical royalty pool. |
| [`release_revenue_distributor_plugin`](./release_revenue_distributor_plugin) | Receive Release coins or redeem the full canonical settled snapshot and distribute it through the immutable tracklist. |

Pool creation is deliberately not a plugin API. Administrators call the
corresponding Action directly with the raw cap (including a cap borrowed via
`Vault::borrow_as_admin`).

## Entry-point caveat

Operational functions are private `entry fun`s. A transaction can invoke
them as top-level commands, but other Move modules cannot call them and they
cannot be composed as public Move functions. They intentionally return `()`
and accept no `VaultAdminCap`, sender, recipient, destination, address, or
`TxContext`. Test-only public wrappers exist solely because external Move test
modules cannot invoke private entry functions.

Install, uninstall, and `is_installed` remain public composable functions.
Installation controls whether the package witness may lease the raw cap; it
does not authorize the transaction sender. Anyone can crank an installed
operation, and the Action fixes the target and funds flow.

The Release redemption crank accepts the canonical `AccumulatorRoot`, never a
caller-selected amount. It snapshots and redeems all funds settled for the
Release at the start of the consensus commit. A zero snapshot is an idempotent
no-op; excess beyond the framework's `u64` snapshot and later funds remain for
a subsequent crank. This prevents permissionless callers from fragmenting a
settlement into dust-sized distributions.

## Dependency pinning

Every immutable dependency is pinned to an exact Git commit. Action dependencies
use the matching `protocol-actions` package subdirectory so one package identity
is resolved throughout each build. A fresh plugin package identity must not reuse
a copied `Published.toml`.

## Verification

Run the compiler-backed ABI and bytecode gate from the repository root:

```sh
./scripts/check_plugin_abi.py --self-test
./scripts/check_plugin_abi.py
```

The gate force-compiles disassembly with warnings and lints as errors. It
checks exact function schemas and call sequences, witness opacity, dependency
Git revisions and resolved package identities, and rejects ambiguous summaries,
unparsed instructions, operational authority/address parameters, or any
executor call graph other than
`witness::new -> borrow_as_plugin -> matching Action -> put_back`.

For an unpublished dependency such as the fresh Vault, the compiler assigns a
deterministic symbolic build address. The Git-source allowlist and absence of
publication metadata establish that it is unpublished; the retired Vault
original ID is not accepted as current.

Each package is independently buildable and testable:

```sh
cd composition_royalty_pool_plugin
sui move build --build-env testnet
sui move test --build-env testnet --coverage
sui move coverage summary
```

Positive receive paths use transferred `Coin` tickets in the Move VM. A
separate test pins the zero settled-accumulator boundary; positive consensus
settlement remains a network integration check.

## License

[Apache-2.0](./LICENSE)
