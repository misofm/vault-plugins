# Security Audit — `recording_royalty_pool`

**Revision:** `77d6bdb` (vault-plugins HEAD) · **Date:** 2026-08-22 ·
**Toolchain:** sui 1.77.2 · **Framework:** pinned rev
`06734f6ff0af45d8632a14a4dc4b100197f6b1a2`

Pinned deps (`Move.toml`/`Move.lock`): `miso` (protocol) `7c13e40a`,
`vault` `2c799916`, `royalty_pool` `8470e492`, `hikida` `e88c6fa8`;
transitive: `miso_share` `047d74d5`, `bps` `26fa571e` (full revs in
`Move.lock`).

Audit of the vault plugin that creates and funds canonical royalty pools for
Miso Recordings. Verdict: **safe to install as-is — no Critical/High/Medium
issues.** One dependency advisory under Load-bearing assumptions.

## What it is

Recordings bind to compositions (`Recording<RecordingShare,
CompositionShare>`); each recording earns revenue at its own object address.
Installed on a `Vault<RecordingAdminCap<RecordingShare>>`, this plugin leases
the custodied cap just long enough to (a) claim the recording's canonical
`RoyaltyPool<RecordingShare, Currency>` as a derived object, and (b) fold
coins/balances delivered to the recording's address into that pool. The pool
is derived from the **Recording, not the Vault** — its identity survives
vault replacement. Same shape and trust surface as `composition_royalty_pool`.

## Why it's safe

- **Capability gating.** Every authority-bearing call constructs the
  package-only `Witness` (`witness.move:7,10`) and goes through
  `vault.borrow_as_plugin`, which aborts unless the witness was authorized
  (`vault.move:184-193`). `install`/`uninstall` require the matching
  `VaultAdminCap` (`recording_royalty_pool.move:28-41`); `initialize_pool`
  additionally self-asserts cap↔vault identity
  (`recording_royalty_pool.move:55,110-115`) — defense in depth, since
  exactly one `RecordingAdminCap<RecordingShare>` can exist on-chain (below).
- **Hot-potato lease.** The borrowed cap pairs with an ability-less `Borrow`
  receipt; the transaction cannot finish without `put_back` returning the
  exact cap to the exact vault (`vault.move:208-214`). The plugin returns it
  *before* calling external pool logic
  (`recording_royalty_pool.move:56-59,72-75,87-90`), so no external code ever
  sees the cap. No endpoint returns cap, receipt, witness, or a privileged
  reference.
- **Funds cannot be redirected.** Both permissionless cranks open with
  `pool.assert_derived_from(recording.id())`
  (`recording_royalty_pool.move:71,86`), recomputing the derived address from
  `(recording_id, RecordingShare, Currency)` (`pool.move:381-389`). The
  caller chooses *when* to fold and *which tickets/amount*, never the
  destination; a wrong-parent pool of the same type aborts
  `EPoolNotDerivedFromParent` (tested). The hikida pulls
  (`hikida.move:14-19,29-31`) draw only from the UID the plugin lends — the
  recording's — via framework `public_receive`/`withdraw_funds_from_object`.
- **Object binding.** `pool::new` claims the pool ID from the recording UID
  with a key encoding both phantom types (`pool.move:152-168`): at most one
  pool per `(recording, RecordingShare, Currency)` triple, necessarily the
  correctly typed, shared pool. `recording.uid_mut(&cap)`
  (`recording.move:313-318`) is **type-scoped** — sound because
  share-type↔recording uniqueness holds: `recording::new` consumes the only
  `TreasuryCap<RecordingShare>` via `miso_share::initialize`
  (`recording.move:221`), and one currency per type is enforced by
  `coin_registry`'s singleton + private generics (see the `miso_share`
  AUDIT). One share type ⟹ one recording ⟹ one cap ⟹ one vault.
- **Arithmetic.** The plugin does no math itself. Pool math is
  accumulator-based in u128/u256 (`pool.move:191,310,393-397`;
  `PRECISION = 10¹⁸` at `pool.move:84`); floor rounding never overpays, and
  truncation-to-zero lockup is impossible because `staked_shares ≤ 10¹³`
  (fixed share supply), so any nonzero deposit advances the index by ≥ 10⁵
  (`pool.move:49-58`). Deposits abort on zero staked shares
  (`pool.move:186`) or zero value (`pool.move:189`) — funds wait at the
  recording's address, never lost, never unattributable.

## Edge cases & caller obligations

1. **Crank liveness.** Cranks abort until the pool exists *and* a stake is
   registered (`ENoStakedShares`); delivered funds wait at the recording
   address meanwhile. Funds sent to the pool's derived address before it
   exists are also safe — a later `pool::new` claims exactly that ID and the
   pool's own `receive_and_deposit` recovers them (`pool.move:205-222`).
2. **Cap scope is permanent root.** `recording.uid_mut` is root over *all*
   dynamic fields on the recording — including other extensions' fields — in
   any lifecycle state (`recording.move:307-318`). Authorizing any plugin on
   this vault means trusting it with that whole surface; this plugin uses it
   only to claim the pool ID and receive/redeem funds.
3. **Uninstall is immediate**, needs no plugin cooperation
   (`vault.move:167-176`); cross-transaction in-flight borrows are impossible
   (hot potato).
4. **Bare `Stake` objects.** Rewards exit via `claim_rewards`, which returns
   a caller-owned `Balance` (`pool.move:288-320`) — a *shared* `Stake` is
   drainable by anyone. Keep stakes address-owned or wrapped (e.g.
   `routed_stake`); this is a pool-level obligation, not plugin logic.
5. **Foreign-parent pools.** Anyone can derive a same-typed pool from an
   unrelated object (`pool::new` is public; cap-gating is the parent's). It
   claims a different, unpaid address and this plugin never deposits into it
   — clients should derive pool addresses via `pool_address`
   (`recording_royalty_pool.move:102-106`), not by search. Claim dust is
   compensated by consumed-index advance (`pool.move:306-311`);
   sub-base-unit exit residue is forfeited by design (`pool.move:250-255`).

## Verification

- **8/8 tests passing** (`sui move test`, sui 1.77.2). Coverage: install /
  uninstall lifecycle and double-install abort (`EPluginAlreadyAuthorized`);
  pre-installation pool-init abort (`EPluginNotAuthorized`); pool parented to
  the recording with address stable across vault destruction/replacement;
  receive- and redeem-path deposits claimable pro-rata from a real
  fixed-supply share stake; foreign `VaultAdminCap` rejected
  (`ENotVaultAdmin`); wrong-parent pool rejected
  (`EPoolNotDerivedFromParent`); and a capability-less `STRANGER`
  successfully cranking revenue — the intended permissionless path.
- Fixtures are production-shaped (commit `f23f557`): recordings issued
  through the real `recording::new` flow with a genuine registry currency
  (`tests/share.move`), so the composition cut and supply gates execute for
  real.
- `sui move build --lint` warning-clean. All privileged endpoints are
  `entry fun`; test-only wrappers stay out of published bytecode.
- This session's relevant hardening commits: `f23f557` (production-shaped
  fixtures), `e783155` (u64 error conventions), `77d6bdb` (double-install,
  stranger-crank, wrong-parent pool tests).

## Load-bearing assumptions

- **Share supply ≤ 10¹³**, inherited from `miso_share` fixed issuance; the
  pool's precision argument (`pool.move:49-58`) depends on it. Note: the
  pinned `miso_share` (`047d74d5`) **predates** the audited hardening
  (`d67ff8c`, the `ETreasuryCapMismatch` cap binding — see the `miso_share`
  AUDIT). At the pinned rev the supply bound still holds via treasury-cap
  uniqueness, but the migrated-currency `RegulatedState::Unknown` fail-open
  is un-asserted: a legacy-migrated share currency concealing a `DenyCapV2`
  would pass `initialize` (freeze risk, not a supply/pool-math risk).
  Advisory: re-pin once `miso` depends on `miso_share ≥ d67ff8c`.
- **`bps` pinned rev `26fa571e` is an ancestor of its audited rev
  `26e5ee2b`**; the delta is the u256 totality rewrite — immaterial here, all
  royalty arithmetic being u64-width. `bps` and `hikida` were independently
  audited clean this week (their AUDIT.md files).
- `vault`'s hot-potato `Borrow` semantics and witness-shape validation
  (`vault.move:245-258`); `derived_object` claim uniqueness; the framework
  `coin_registry` private-generics gate. All verified at the pinned revs —
  re-verify on dependency change.
