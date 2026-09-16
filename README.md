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
| [`composition_royalty_pool_plugin`](./composition_royalty_pool_plugin) | Receive Composition coins or redeem the full canonical settled snapshot into its canonical royalty pool. |
| [`recording_royalty_pool_plugin`](./recording_royalty_pool_plugin) | Receive Recording coins or redeem the full canonical settled snapshot into its canonical royalty pool. |
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
does not authorize the transaction sender. In the Move API, `cap` names the
`VaultAdminCap`; `vaulted_cap` names the borrowed custodied capability. Anyone can crank an installed
operation, and the Action fixes the target and funds flow.

Installation and uninstallation rely on the Vault's typed
`PluginAuthorizedEvent` and `PluginRevokedEvent`; the plugin packages emit no
duplicate lifecycle wrappers. Operation results remain observable through the
underlying Vault, Action, royalty-pool, and routed-stake events, which are the
canonical source for custody and business facts. Plugins do not re-read state
to create wrapper notifications.

Consumers migrating from earlier plugin generations should read permanent
custody and permission changes from Vault events and deposit/distribution
results from the matching Action and extension events. Temporary borrowing and
return are silent. The plugin-specific borrow, coin-deposit,
fund-deposit, coin-distribution, and fund-distribution event types are removed;
their similarly named Action events remain. Operational entry signatures and
install/uninstall signatures and `is_installed` behavior are unchanged. Historical event decoding
must continue to use the schema for the originating package generation.

Every redemption crank (`redeem_all_and_distribute` for a Release,
`redeem_all_and_deposit` for a Composition or Recording) accepts the canonical
`AccumulatorRoot`, never a caller-selected amount. It snapshots and redeems all
funds settled for the object at the start of the consensus commit. A zero
snapshot is a no-op, and the pool cranks are also a no-op that redeems
nothing while the pool has no registered stake, so a batched permissionless
crank passes untouched over an item cranked in an earlier commit or an
unstaked item. Excess beyond the framework's `u64` snapshot and later funds
remain for a subsequent crank. This prevents permissionless callers from
fragmenting a settlement into dust-sized distributions.

The no-op holds only across consensus commits. The settled snapshot is
written solely by the settlement system transaction and is constant for every
transaction in a commit, so cranking the same object twice in one PTB, or
from two crankers in the same commit, withdraws the snapshot twice and the
network fails that whole transaction with `InsufficientFundsForWithdraw` (a
transaction-level failure with no Move abort code). A crank must include each
object at most once per PTB and treat that status as "retry next commit",
not as a poisoned item.

## Dependency pinning

Every immutable dependency is pinned to an exact Git commit. Action dependencies
use the matching `musicos-actions` package subdirectory so one package identity
is resolved throughout each build. A fresh plugin package identity must not reuse
a copied `Published.toml`. The current Vault layout/API requires a fresh Vault
package and registry, followed by plugins published against that new identity;
the checked-in historical publication IDs do not establish this source ABI.
Action test dependencies and plugin dependencies pin the same Vault revision so
test-mode resolution compiles every caller against the same API.

## Verification

Each package is independently buildable and testable:

```sh
cd composition_royalty_pool_plugin
sui move build --build-env testnet
sui move test --build-env testnet --coverage
sui move coverage summary
```

Positive receive paths use transferred `Coin` tickets in the Move VM. The
redemption cranks are exercised against a real zero settled snapshot, and the
pool plugins' funded path runs the borrow/Action/put-back sequence through the
Action's test-only settled-value helper (the Move VM cannot settle a positive
`AccumulatorRoot` snapshot); positive consensus settlement remains a network
integration check.

## License

[Apache-2.0](./LICENSE)
