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
- `new_pool`: Admin-only and installation-gated. Returns the one
  Recording-derived pool unshared so a PTB can register fresh holder stakes
  before sharing it.
- `initialize_pool`: Admin-only and installation-gated. Creates and shares the
  one Recording-derived pool for a `RecordingShare`/`Currency` pair. This is
  the convenience wrapper for callers that do not need pre-share setup.
- `receive_and_deposit`: Permissionless after installation. Receives selected
  `Coin<Currency>` objects sent to the Recording and deposits their combined
  balance into the canonical pool.
- `redeem_and_deposit`: Permissionless after installation. Redeems a selected
  amount from the Recording's funds accumulator and deposits it into the
  canonical pool.
- `is_installed` and `pool_address`: Read-only, composable views.

All privileged production endpoints are composable `public fun`s so callers can
install and configure the plugin on a Vault created earlier in the same PTB.
`new_pool` returns only the canonical unshared pool; none returns the leased
cap, Vault receipt, witness, or a privileged reference.

## Permission declaration

- Target: `miso::recording::Recording`.
- Host writes: claims a derived-object ID under the Recording during pool
  initialization; receives transferred coins and redeems accumulated balances
  through the Recording UID.
- Funds: can move funds held at the Recording address only into the
  `RoyaltyPool` derived from that same Recording and matching type arguments.
- Initialization: requires the matching `VaultAdminCap`.
- Folding: permissionless after installation; callers choose coin tickets or an
  accumulator amount, but cannot choose a different destination pool.
- External packages: `miso`, `vault`, `royalty_pool`, and `hikida` at the exact
  revisions pinned in `Move.toml`.

## Build and test

To redeem all currently settled funds, compose two Move calls in one PTB: call
`sui::balance::settled_funds_value<Currency>` with the shared
`AccumulatorRoot` and the Recording address, then pass its `u64` result to
`redeem_and_deposit`. The calls are atomic; a zero result aborts in `hikida`,
and the framework's `u64::MAX` cap means larger balances require another PTB.

The package includes `sui::test_scenario` flows covering canonical shared-pool
creation, cross-transaction receive and exact-redemption deposits, and
canonical-pool enforcement. Exact-redemption scenarios also cover permissionless
cranking, partial withdrawals across transactions, revocation, and direct
type-safe feeding of the framework reader's zero result into the plugin API.

```sh
sui move build
sui move test --coverage
```
