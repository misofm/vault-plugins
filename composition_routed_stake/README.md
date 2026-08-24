# Composition Routed Stake Plugin

Vault-authorized control over Recording shares owned by a Miso Composition.

## Model

The plugin is installed on a `Vault<CompositionAdminCap<CompositionShare>>`.
It redeems Recording shares held at the Composition address and places them in
the generic `routed_stake::routed_stake::RoutedStake` primitive. The routed
stake remains an independently shared object, derived from the Composition.

The two layers enforce different boundaries:

- `vault` protects the Composition admin capability and authorizes lifecycle
  changes.
- `RoutedStake` protects the Recording-share principal and makes reward
  sweeping permissionless without exposing a freely claimable reward balance.

`routed_stake::sweep` sends rewards only into the RoyaltyPool derived from the
same Composition. It remains a direct, permissionless library call and does
not borrow the Composition capability.

## Operations

- `install`: Admin-only. Authorizes the canonical package witness.
- `uninstall`: Admin-only. Immediately revokes the package witness.
- `create_stake`: Admin-only and installation-gated. Redeems Composition-owned
  Recording shares, creates the derived `RoutedStake`, and shares it.
- `register`: Admin-only. Registers against the canonical pool derived from the
  supplied Recording.
- `unregister`: Admin-only. Removes a drained pool registration.
- `unstake`: Admin-only. Returns principal to the Composition address; it never
  returns a caller-controlled Coin or Balance.
- `restake`: Admin-only. Refills an empty wrapper from the Composition address.
- `is_installed` and `stake_address`: Read-only, composable views.

All authority-bearing production endpoints are composable `public fun`s so
callers can install and configure the plugin on a Vault created earlier in the
same PTB. None returns the leased cap, Vault receipt, witness, principal, or
privileged reference.

## Permission declaration

- Target: `miso::composition::Composition<CompositionShare>`.
- Host access: claims a derived `RoutedStake` ID and redeems Recording shares
  through the Composition UID.
- Principal: can enter only the Composition-derived routed stake and can leave
  only by returning to the same Composition address.
- Rewards: the generic routed-stake primitive can send them only to the
  Composition-derived royalty pool.
- Lifecycle: requires the matching `VaultAdminCap` and plugin installation.
- External packages: `miso`, `vault`, `hikida`, `royalty_pool`, and
  `routed_stake` at the exact revisions pinned in `Move.toml`.

## Build and test

The package includes a complete `sui::test_scenario` lifecycle across multiple
transactions and senders, plus focused authorization and destination tests.

```sh
sui move build
sui move test --coverage
```
