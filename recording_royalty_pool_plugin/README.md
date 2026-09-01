# Recording Royalty Pool Plugin

Vault adapter for `recording_royalty_pool` Actions.

An administrator installs the package-local `witness::Witness` on a
`Vault<RecordingAdminCap<RecordingShare>>`. After installation, any sender may
invoke private entry endpoints to receive or redeem Recording funds into the
matching canonical royalty pool.

Each executor performs only `borrow_as_plugin -> matching Action -> put_back`.
The plugin exposes no pool creation or address derivation; call the public
Action directly for `new_pool` and `pool_address`. All validation, arithmetic,
transfers, events, and business rules remain in the Action or royalty-pool
core.

Operational entries return `()` and accept no Vault admin cap, address,
recipient, destination, sender, or transaction context. Test-only public
wrappers exist solely for external Move tests.

The Action dependency is pinned to its `protocol-actions` Git subdirectory and
exact immutable revision.
