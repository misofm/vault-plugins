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
- `initialize_pool`: Admin-only and installation-gated. Creates and shares the
  one Composition-derived pool for a `CompositionShare`/`Currency` pair.
- `receive_and_deposit`: Permissionless after installation. Receives selected
  `Coin<Currency>` objects sent to the Composition and deposits their combined
  balance into the canonical pool.
- `redeem_and_deposit`: Permissionless after installation. Redeems a selected
  amount from the Composition's funds accumulator and deposits it into the
  canonical pool.
- `is_installed` and `pool_address`: Read-only, composable views.

All privileged production endpoints are `entry fun`; none returns the leased
cap, Vault receipt, witness, or a privileged reference.

## Permission declaration

- Target: `miso::composition::Composition`.
- Host writes: claims a derived-object ID under the Composition during pool
  initialization; receives transferred coins and redeems accumulated balances
  through the Composition UID.
- Funds: can move funds held at the Composition address only into the
  `RoyaltyPool` derived from that same Composition and matching type arguments.
- Initialization: requires the matching `VaultAdminCap`.
- Folding: permissionless after installation; callers choose tickets or amount,
  but cannot choose a different destination pool.
- External packages: `miso`, `vault`, `royalty_pool`, and `hikida` at the exact
  revisions pinned in `Move.toml`.

## Build and test

```sh
sui move build
sui move test --coverage
```
