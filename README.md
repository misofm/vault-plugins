# Vault Plugins

> First-party business-logic plugins for Miso protocol objects, authorized by
> [`misofm/vault`](https://github.com/misofm/vault).

Extensions add data to a `Composition`, `Recording`, or `Release`. Plugins add
bounded business logic by installing on a vault that custodies the object's
admin capability. Each directory in this repository is an independent Move
package.

The repository also defines an offchain acceptance and scoring model. The
vault enforces installed witness identity; clients decide whether the code and
upgrade authority behind that identity are safe. See [SCORING.md](./SCORING.md).

No existing protocol extension is treated as a plugin merely by moving it into
this repository. Packages will be added here as they are converted to the vault
authority model.

## Packages

| Package | Target | Authority |
|---|---|---|
| [`composition_royalty_pool`](./composition_royalty_pool) | Composition | Creates canonical Composition-derived pools and folds Composition-addressed funds into them. |
| [`recording_royalty_pool`](./recording_royalty_pool) | Recording | Creates canonical Recording-derived pools and folds Recording-addressed funds into them. |

Royalty pools are authorized as Vault plugins, but remain derived from their
Composition or Recording. That stable parent keeps the pool address independent
of vault replacement or capability migration. The empty derivation key remains
phantom-typed by both `Share` and `Currency`, preventing a wrong-share pool from
claiming or blocking the canonical address.

## Required witness module

Every plugin package has exactly one canonical installation identity at
`0xpkg::witness::Witness`:

```move
module example_plugin::witness;

public struct Witness() has drop;

public(package) fun new(): Witness {
    Witness()
}
```

`Witness` must have only `drop`. Its constructor is package-only so every
module in the plugin package can prove authority, while downstream packages
cannot fabricate that authority.

## Installation shape

The plugin owns its installation endpoint and constructs the witness
internally:

```move
module example_plugin::example_plugin;

use example_plugin::witness;
use miso::composition::CompositionAdminCap;
use vault::vault::{Vault, VaultAdminCap};

entry fun install<CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new())
}
```

Authority-bearing plugin operations should usually be `entry fun` so another
Move package cannot call them as an authority trampoline. Read-only and
deliberately composable APIs may remain public.

## License

[Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) © Miso Labs, Inc.
