# Release Revenue Distributor Plugin

Vault adapter for `release_revenue_distributor` Actions.

An administrator installs the package-local `witness::Witness` on a
`Vault<ReleaseAdminCap>`. After installation, any sender may invoke private
entry endpoints to receive Release coins or redeem its full canonical settled
snapshot and execute the immutable tracklist distribution. The redemption
entry takes `&AccumulatorRoot` and no amount, so a caller cannot fragment
settlement into dust-sized distributions. An empty snapshot is an idempotent
no-op; excess and later-settled funds remain for a later crank.

Each executor performs only `borrow_as_plugin -> matching Action -> put_back`.
The Action, not this plugin, owns split arithmetic, recipient derivation,
transfers, remainder handling, validation, and distribution events.

## Events

Installation emits one `ReleaseRevenueDistributorPluginInstalledEvent<ReleaseAdminCap, Witness>` after the vault authorization succeeds. Uninstallation emits one `ReleaseRevenueDistributorPluginUninstalledEvent<ReleaseAdminCap, Witness>` after revocation succeeds. Both have this primitive schema, in order:

```text
vault_id: address
vault_admin_cap_id: address
release_admin_cap_id: address
vault_active: bool
authorized_before: bool
authorized_after: bool
authorized_plugin_count_before: u64
authorized_plugin_count_after: u64
```

The operation events are emitted after the Action returns and the borrowed
capability has been put back:

```text
ReleaseRevenueCoinsDistributedEvent<Currency, ReleaseAdminCap, Witness> {
    vault_id: address,
    release_admin_cap_id: address,
    release_id: address,
    input_coin_count: u64,
    input_coin_ids: vector<address>,
}

ReleaseRevenueFundsDistributedEvent<Currency, ReleaseAdminCap, Witness> {
    vault_id: address,
    release_admin_cap_id: address,
    release_id: address,
    accumulator_root_id: address,
    settled_input: u64,
}
```

All object identities use `object::id(...).to_address()`. Coin IDs preserve
the caller's `Receiving` vector order. The plugin reports custody and input
identity; the pinned Action reports monetary splits, recipients, transfers,
rounding, and per-track/aggregate distribution events. The plugin does not
recreate those calculations.

An empty settled snapshot still authorizes the Release through the Action and
returns the capability, but emits no plugin distribution event. A nonempty
vector containing a zero-valued coin succeeds, consumes the coin, and emits a
coin input event; the Action also emits its zero-valued track and summary
events. An empty receiving vector retains Hikida's `ENoCoinsToReceive` abort.
The Move VM does not establish a positive consensus accumulator snapshot from
ordinary test-scenario fund sends, so positive settled-input event execution
requires a network E2E.

Operational entries return `()` and accept no Vault admin cap, address,
recipient, destination, sender, or transaction context. Test-only public
wrappers exist solely for external Move tests.

The Action dependency is pinned to its `musicos-actions` Git subdirectory and
exact immutable revision.
