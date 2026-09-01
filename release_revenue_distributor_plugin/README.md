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

Operational entries return `()` and accept no Vault admin cap, address,
recipient, destination, sender, or transaction context. Test-only public
wrappers exist solely for external Move tests.

The Action dependency is pinned to its `protocol-actions` Git subdirectory and
exact immutable revision.
