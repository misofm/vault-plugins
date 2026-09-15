# Release Revenue Distributor Plugin

Vault adapter for `release_revenue_distributor` Actions.

An administrator installs the package-local `witness::Witness` on a
`Vault<ReleaseAdminCap>`. After installation, any sender may invoke private
entry endpoints to receive Release coins or redeem its full canonical settled
snapshot and execute the immutable tracklist distribution. The redemption
entry takes `&AccumulatorRoot` and no amount, so a caller cannot fragment
settlement into dust-sized distributions. An empty snapshot is a no-op;
excess and later-settled funds remain for a later crank. The no-op holds only
across consensus commits: the settled snapshot is constant within a commit, so
cranking the same Release twice in one PTB, or from two crankers in the same
commit, fails that whole transaction with `InsufficientFundsForWithdraw` (not a
Move abort). Include each Release at most once per PTB and retry that status
next commit.

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

Operation results come from the underlying Vault and Action events. The
plugin does not duplicate input identity or settled-fund snapshots. The
pinned Action reports monetary splits, recipients, transfers, rounding, and
per-track/aggregate distribution events.

An empty settled snapshot still authorizes the Release through the Action and
returns the capability. A nonempty vector containing a zero-valued coin
succeeds, consumes the coin, and the Action emits its zero-valued track and
summary events. An empty receiving vector retains the Action's
`ENoCoinsToReceive` abort. The Move VM does not establish a positive
consensus accumulator snapshot from ordinary test-scenario fund sends, so
positive settled-input execution requires a network E2E.

Operational entries return `()` and accept no Vault admin cap, address,
recipient, destination, sender, or transaction context. Test-only public
wrappers exist solely for external Move tests.

The Action dependency is pinned to its `musicos-actions` Git subdirectory and
exact immutable revision.
