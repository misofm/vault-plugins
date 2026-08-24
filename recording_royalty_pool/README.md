# Recording Royalty Pool Plugin

Vault-authorized business logic that creates canonical royalty pools for Miso
Recordings and safely folds funds sent to a Recording into its pool.

## Model

The plugin is installed on a `Vault<RecordingAdminCap<RecordingShare>>`.
Each authority-bearing endpoint constructs the package-only
`recording_royalty_pool::witness::Witness`, leases the complete admin cap, uses
it only to access the Recording UID, and returns it before invoking external
pool logic.

The `RoyaltyPool<RecordingShare, Currency>` remains derived from the
Recording—not the Vault. Its address is therefore stable if the admin cap is
moved into a replacement Vault. `RoyaltyPoolKey<RecordingShare, Currency>`
includes both phantom types so a pool created with a wrong share type derives
to a different address and cannot squat the canonical one.

## Operations

- `install`: Admin-only. Authorizes the canonical package witness on the Vault.
- `uninstall`: Admin-only. Immediately revokes the package witness.
- `initialize_pool`: Admin-only and installation-gated. Creates and shares the
  one Recording-derived pool for a `RecordingShare`/`Currency` pair.
- `receive_and_deposit`: Permissionless after installation. Receives selected
  `Coin<Currency>` objects sent to the Recording and deposits their combined
  balance into the canonical pool.
- `sweep_and_deposit`: Permissionless after installation. Reads the Recording's
  funds settled at the start of the current consensus commit from the shared
  `AccumulatorRoot`, redeems that entire reported amount, and deposits it into the
  canonical pool. It aborts when no funds of that currency are settled; funds
  sent during the current commit remain for a later sweep. The framework caps
  the reported value at `u64::MAX`, so a larger balance requires subsequent
  sweeps.
- `is_installed` and `pool_address`: Read-only, composable views.

All privileged production endpoints are composable `public fun`s so callers can
install and configure the plugin on a Vault created earlier in the same PTB.
None returns the leased cap, Vault receipt, witness, or a privileged reference.

## Permission declaration

- Target: `miso::recording::Recording`.
- Host writes: claims a derived-object ID under the Recording during pool
  initialization; receives transferred coins and redeems accumulated balances
  through the Recording UID.
- Funds: can move funds held at the Recording address only into the
  `RoyaltyPool` derived from that same Recording and matching type arguments.
- Initialization: requires the matching `VaultAdminCap`.
- Folding: permissionless after installation; callers choose coin tickets or
  sweep the full settled balance, but cannot choose a different destination
  pool or accumulator amount.
- External packages: `miso`, `vault`, `royalty_pool`, and `hikida` at the exact
  revisions pinned in `Move.toml`.

## Build and test

The package includes `sui::test_scenario` flows covering canonical shared-pool
creation, cross-transaction receives, canonical-pool enforcement for sweeps,
and explicit empty-sweep behavior. The local Move test harness does not
populate `AccumulatorRoot` snapshots from native accumulator writes, so a
nonzero sweep is covered by build/type checks rather than a synthetic balance
snapshot.

```sh
sui move build
sui move test --coverage
```
