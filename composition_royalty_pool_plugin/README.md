# Composition Royalty Pool Plugin

Vault adapter for `composition_royalty_pool` Actions.

An administrator installs the package-local `witness::Witness` on a
`Vault<CompositionAdminCap<CompositionShare>>`. After installation, any sender
may invoke the private entry endpoints to receive Composition coins or redeem
its full canonical settled snapshot into the matching canonical royalty pool.
The redemption entry `redeem_all_and_deposit` takes `&AccumulatorRoot` and no
amount. A zero snapshot, or a pool with no registered stake, is a no-op that
redeems nothing while the cap is still leased and returned. The no-op holds
only across consensus commits: the settled snapshot is constant within a commit, so
cranking the same Composition twice in one PTB, or from two crankers in the
same commit, fails that whole transaction with `InsufficientFundsForWithdraw`
(not a Move abort). Include each Composition at most once per PTB and retry
that status next commit. Each executor keeps the same business sequence:

1. `vault.borrow_as_plugin(witness::new())`
2. the matching `composition_royalty_pool` Action
3. `vault.put_back(cap, receipt)`

The plugin has no pool-creation or pool-address API. Use the public Action
directly for `new_pool(composition, admin_cap, share_currency)` and
`pool_address`; the final argument binds creation to the verified
`Currency<CompositionShare>`. Validation, receiving, redemption,
deposit accounting, derivation checks, transfers, and dependency events remain
owned by the Action and royalty-pool core. Installation and uninstallation are
represented by the Vault's typed `PluginAuthorizedEvent` and
`PluginRevokedEvent`; operation results come from the underlying Vault, Action,
and royalty-pool events. `is_installed` and the witness constructor remain
silent.

Operational entries return `()` and accept no Vault admin cap, address,
recipient, destination, sender, or transaction context. Test-only public
wrappers exist solely for external Move tests.

The Action dependency is pinned to its `musicos-actions` Git subdirectory and
exact immutable revision.
