# Recording Royalty Pool Plugin

Vault adapter for `recording_royalty_pool` Actions.

An administrator installs the package-local `witness::Witness` on a
`Vault<RecordingAdminCap<RecordingShare>>`. After installation, any sender may
invoke private entry endpoints to receive Recording coins or redeem its full
canonical settled snapshot into the matching canonical royalty pool. The
redemption entry `redeem_all_and_deposit` takes `&AccumulatorRoot` and no
amount. A zero snapshot, or a pool with no registered stake, is a no-op that
redeems nothing while the cap is still leased and returned.

The no-op holds only across consensus commits: the settled snapshot is
constant within a commit, so cranking the same Recording twice in one PTB, or
from two crankers in the same commit, fails that whole transaction with
`InsufficientFundsForWithdraw` (not a Move abort). Include each Recording at
most once per PTB and retry that status next commit.

Each executor performs only `borrow_as_plugin -> matching Action -> put_back`.
The plugin exposes no pool creation or address derivation; call the public
Action directly for `new_pool(recording, admin_cap, share_currency)` and
`pool_address`; the final argument binds creation to the verified
`Currency<RecordingShare>`. All validation, arithmetic,
transfers, and business rules remain in the Action or royalty-pool core.
Installation and uninstallation are represented by the Vault's typed
`PluginAuthorizedEvent` and `PluginRevokedEvent`; operation results come from
the underlying Vault, Action, and royalty-pool events.

Operational entries return `()` and accept no Vault admin cap, address,
recipient, destination, sender, or transaction context. Test-only public
wrappers exist solely for external Move tests.

The Action dependency is pinned to its `musicos-actions` Git subdirectory and
exact immutable revision.
