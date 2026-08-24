# Release Revenue Distributor Plugin

Vault-authorized business logic that routes Release-held revenue to the
Recording addresses fixed by the Release's immutable tracklist.

## Model

The plugin is installed on a `Vault<ReleaseAdminCap>`. Each distribution
endpoint constructs `release_revenue_distributor::witness::Witness`, leases the
complete admin cap, uses it only to receive or redeem funds through the matching
Release UID, and returns it before routing the resulting balance.

For every track, the plugin applies its stored `split_bps` to the original input
and sends that amount to the stored Recording ID. Per-track flooring remainder
returns to the Release address. Callers choose only the amount to redeem or the
receiving tickets; they cannot choose recipients or split values.

This package deliberately stops at the Recording custody boundary. The
`recording_royalty_pool` plugin can permissionlessly fold Recording-addressed
funds into that Recording's canonical royalty pool.

## Operations

- `install`: Admin-only. Authorizes the canonical package witness.
- `uninstall`: Admin-only. Immediately revokes the package witness.
- `redeem_and_distribute`: Permissionless after installation. Redeems a
  selected amount from the Release address and distributes it.
- `receive_and_distribute`: Permissionless after installation. Receives
  selected coins sent to the Release and distributes their combined balance.
- `is_installed`: Read-only, composable installation check.

All authority-bearing production endpoints are composable `public fun`s so
callers can install and configure the plugin on a Vault created earlier in the
same PTB. None returns the leased cap, Vault receipt, witness, balance, or
privileged reference.

## Permission declaration

- Target: `miso::release::Release`.
- Host access: receives transferred coins and redeems accumulated balances
  through the Release UID.
- Funds: can move Release-addressed funds only to Recording IDs and split
  amounts stored in the Release; rounding remainder returns to the Release.
- Distribution: permissionless after installation.
- External packages: `miso`, `vault`, and `hikida` at the exact revisions
  pinned in `Move.toml`.

## Build and test

The package includes a `sui::test_scenario` flow that sends multiple coins to
a Release in one transaction and permissionlessly receives and distributes
them from a different sender in the next transaction.

```sh
sui move build
sui move test --coverage
```
