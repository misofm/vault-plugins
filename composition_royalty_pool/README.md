# Composition Royalty Pool Plugin

Vault-authorized business logic that creates canonical royalty pools for Miso
Compositions and safely folds funds sent to a Composition into its pool.

## Model

The plugin is installed on a `Vault<CompositionAdminCap<CompositionShare>>`.
Each authority-bearing endpoint constructs the package-only
`composition_royalty_pool::witness::Witness`, leases the complete admin cap,
uses it only to access the Composition UID, and returns it before invoking
external pool logic.

The `RoyaltyPool<CompositionShare, Currency>` remains derived from the
Composition—not the Vault. Its address is therefore stable if the admin cap is
moved into a replacement Vault. `RoyaltyPoolKey<CompositionShare, Currency>`
includes both phantom types so a pool created with a wrong share type derives
to a different address and cannot squat the canonical one.

## Operations

- `install`: Admin-only. Authorizes the canonical package witness on the Vault.
- `uninstall`: Admin-only. Immediately revokes the package witness.
- `new_pool`: Admin-only and installation-gated. Returns the one
  Composition-derived pool unshared so a PTB can register fresh holder stakes
  before sharing it.
- `initialize_pool`: Admin-only and installation-gated. Creates and shares the
  one Composition-derived pool for a `CompositionShare`/`Currency` pair. This
  is the convenience wrapper for callers that do not need pre-share setup.
- `receive_and_deposit`: Permissionless after installation. Receives selected
  `Coin<Currency>` objects sent to the Composition and deposits their combined
  balance into the canonical pool.
- `sweep_and_deposit`: Permissionless after installation. Reads the `Currency`
  balance settled at the Composition address at the start of the current
  consensus commit and deposits up to `u64::MAX` per call into the canonical
  pool. It aborts with `ENoSettledFunds` when no positive amount is eligible;
  a larger balance requires repeated calls, and funds sent later in the same
  commit remain for a subsequent sweep.
- `is_installed` and `pool_address`: Read-only, composable views.

All privileged production endpoints are composable `public fun`s so callers can
install and configure the plugin on a Vault created earlier in the same PTB.
`new_pool` returns only the canonical unshared pool; none returns the leased
cap, Vault receipt, witness, or a privileged reference.

## Permission declaration

- Target: `miso::composition::Composition`.
- Host writes: claims a derived-object ID under the Composition during pool
  initialization; receives transferred coins and redeems accumulated balances
  through the Composition UID.
- Funds: can move funds held at the Composition address only into the
  `RoyaltyPool` derived from that same Composition and matching type arguments.
- Initialization: requires the matching `VaultAdminCap`.
- Folding: permissionless after installation; callers choose receiving tickets
  or sweep the settled accumulator balance, but cannot choose a different
  destination pool.
- External packages: `miso`, `vault`, `royalty_pool`, and `hikida` at the exact
  revisions pinned in `Move.toml`.

## Build and test

The package includes `sui::test_scenario` flows covering canonical shared-pool
creation, cross-transaction receives, sweep destination validation, and the
explicit empty-sweep abort. The local Move harness does not execute consensus
settlement, so it cannot materialize a nonzero `AccumulatorRoot` snapshot from
`send_funds`; nonzero sweep behavior relies on the pinned framework's
`settled_funds_value` and withdrawal primitives and must be exercised in a
network integration test.

```sh
sui move build
sui move test --coverage
```
