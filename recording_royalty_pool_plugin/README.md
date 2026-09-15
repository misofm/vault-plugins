# Recording Royalty Pool Plugin

Vault adapter for `recording_royalty_pool` Actions.

An administrator installs the package-local `witness::Witness` on a
`Vault<RecordingAdminCap<RecordingShare>>`. After installation, any sender may
invoke private entry endpoints to receive Recording coins or redeem its full
canonical settled snapshot into the matching canonical royalty pool. The
redemption entry `redeem_all_and_deposit` takes `&AccumulatorRoot` and no
amount. A zero snapshot, or a pool with no registered stake, is an idempotent
no-op that redeems nothing: the cap is leased and returned (one
`RecordingVaultCapabilityBorrowedEvent`) and no `RecordingFundsDepositedEvent`
is emitted. When funds are deposited, that event's `amount` is the settled
snapshot the Action redeemed.

Each executor performs only `borrow_as_plugin -> matching Action -> put_back`.
The plugin exposes no pool creation or address derivation; call the public
Action directly for `new_pool` and `pool_address`. All validation, arithmetic,
transfers, and business rules remain in the Action or royalty-pool core. Plugin
events describe installation, custody, and observed financial changes around
those operations.

Operational entries return `()` and accept no Vault admin cap, address,
recipient, destination, sender, or transaction context. Test-only public
wrappers exist solely for external Move tests.

The Action dependency is pinned to its `musicos-actions` Git subdirectory and
exact immutable revision.
