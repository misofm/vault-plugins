# Miso Vault Plugins

First-party business-logic packages for Miso objects, authorized by
[`misofm/vault`](https://github.com/misofm/vault).

Extensions attach declarative data to a host object. Vault plugins temporarily
exercise a custodied admin capability to perform a bounded workflow on a
`Party`, `Composition`, `Recording`, or `Release`. Each directory in this
repository is an independently versioned and published Move package.

## Packages

| Package | Target | Purpose |
|---------|--------|---------|
| [`composition_royalty_pool`](./composition_royalty_pool) | Composition | Creates the canonical Composition-derived royalty pool and folds Composition-addressed funds into it. |
| [`recording_royalty_pool`](./recording_royalty_pool) | Recording | Creates the canonical Recording-derived royalty pool and folds Recording-addressed funds into it. |
| [`release_revenue_distributor`](./release_revenue_distributor) | Release | Receives or redeems Release-addressed revenue and distributes it to the Recording addresses and splits fixed by the tracklist. |
| [`composition_routed_stake`](./composition_routed_stake) | Composition | Manages Composition-owned Recording shares in a derived `RoutedStake`, with principal and rewards constrained to Composition-controlled destinations. |
| [`party_wallet`](./party_wallet) | Party | Admin-gated receipt of Party-addressed objects plus composable Balance returns from coin and accumulator withdrawals. |

See each package README for its complete authority and funds-flow declaration.

## Trust model

Every plugin contains the canonical type `0xpkg::witness::Witness`:

```move
module example_plugin::witness;

public struct Witness() has drop;

public(package) fun new(): Witness {
    Witness()
}
```

The package-only constructor allows plugin modules to borrow through Vault
without allowing downstream packages to fabricate the witness. A Vault
authorization identifies the witness's defining package lineage; it does not
pin one bytecode version. Clients must evaluate the package's source, published
bytecode, upgrade authority, dependencies, and witness shape before installation.
See [SCORING.md](./SCORING.md) for the offchain acceptance model.

Authority-bearing production operations are composable `public fun`s, allowing
installation and setup against Vaults created earlier in the same PTB. Authority
still comes from the matching `VaultAdminCap` and package witness, and every
capability lease is returned before the operation completes.

## Installation

Installation is implemented by the plugin package so it can construct its own
witness:

```move
public fun install<CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new())
}
```

The matching Vault administrator can revoke the plugin at any time.

## Development

Run commands from the package directory:

```sh
cd composition_royalty_pool
sui move build
sui move test --coverage
sui move coverage summary
```

Every plugin includes a multi-transaction `sui::test_scenario` flow plus
focused authorization and destination-integrity tests. Dependency revisions and
resolved package identities are committed in `Move.toml` and `Move.lock`.

`test_scenario` does not advance consensus settlement into a funded
`AccumulatorRoot`. The suites type-check a framework-derived zero `u64` through
the exact redemption APIs and exercise positive exact redemptions directly.
After fresh publication, the positive
`settled_funds_value -> redeem` command-result chain remains a required network
integration check.

## License

[Apache-2.0](./LICENSE)
