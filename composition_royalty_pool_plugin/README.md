# Composition Royalty Pool Plugin

Vault adapter for `composition_royalty_pool` Actions.

An administrator installs the package-local `witness::Witness` on a
`Vault<CompositionAdminCap<CompositionShare>>`. After installation, any sender
may invoke the private entry endpoints to receive or redeem Composition funds
into the matching canonical royalty pool. Each executor keeps the same business
sequence:

1. `vault.borrow_as_plugin(witness::new())`
2. the matching `composition_royalty_pool` Action
3. `vault.put_back(cap, receipt)`

The plugin has no pool-creation or pool-address API. Use the public Action
directly for `new_pool` and `pool_address`. Validation, receiving, redemption,
deposit accounting, derivation checks, transfers, and dependency events remain
owned by the Action and royalty-pool core. The plugin also emits typed provenance, custody,
and financial snapshots around that sequence. Installation and uninstallation
events record the Vault authorization entry and Bag cardinality. Each operation
records the borrowed capability, and successful receiving and redemption record
the pool's before-and-after metrics. Receiving events preserve the caller's
ticket order in `coin_ids`; redemption events record the requested `amount`.
Failed operations roll back these observations with the transaction, while
`is_installed` and the witness constructor remain silent.

Operational entries return `()` and accept no Vault admin cap, address,
recipient, destination, sender, or transaction context. Test-only public
wrappers exist solely for external Move tests.

The Action dependency is pinned to its `musicos-actions` Git subdirectory and
exact immutable revision.
