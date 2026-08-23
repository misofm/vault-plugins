# Security Audit — `composition_royalty_pool`

**Revision:** `77d6bdb8e680479b8d1d4ae250d07115d9323070` (repo HEAD) ·
**Date:** 2026-08-22 · **Toolchain:** sui 1.77.2 ·
**Framework:** pinned rev `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`

**Pinned dependencies** (by git rev, per `Move.toml`/`Move.lock`): `miso`
(protocol) `c23fe7fc` (re-pinned from `7c13e40a` 2026-08-23), `vault`
`2c799916`, `hikida` `e88c6fa8` (audited clean 2026-08-22), `royalty_pool`
`8470e492`; transitive `miso_share` `d67ff8c` (the audited hardening rev),
`bps` `26fa571e` (audited clean 2026-08-22).

Audit of the vault plugin that creates canonical royalty pools for Miso
Compositions and folds Composition-addressed funds into them. Verdict:
**safe to publish — no Critical/High/Medium issues found.**

## What it is

Installed on a `Vault<CompositionAdminCap<CompositionShare>>`, the plugin
leases the custodied admin cap just long enough to reach the matching
Composition UID, creates the canonical `RoyaltyPool<CompositionShare,
Currency>` as a derived object of the Composition, and deposits
Composition-addressed revenue into it. Two permissionless crank paths let
anyone complete deliveries; pool creation is admin- and installation-gated.
The pool derives from the Composition — not the Vault — so its identity
survives vault replacement.

## Why it's safe

- **Capability gating.** `install`/`uninstall`/`initialize_pool` require the
  matching `VaultAdminCap`; `assert_admin` binds cap to vault by ID
  (`composition_royalty_pool.move:110-115`) on top of the vault's own check
  (`vault.move:265`). The plugin witness is package-only (`witness.move:10`);
  the vault checks authorization on every borrow (`vault.move:184-193`,
  aborts `EPluginNotAuthorized`).
- **The cap cannot escape.** `borrow_as_plugin` returns `(Cap, Borrow)`
  where `Borrow` has no abilities — a hot potato forcing `put_back` in the
  same transaction (`vault.move:208-213`). Every endpoint borrows, uses the
  cap only for `composition.uid_mut(&cap)`, and puts it back **before**
  calling external pool code (`:56-58`, `:72-74`, `:87-89`). No endpoint
  returns the cap, receipt, witness, or a privileged reference.
- **Permissionless cranks cannot redirect value.** Both cranks open with
  `pool.assert_derived_from(composition.id())` (`:71`, `:86`;
  pool.move:381-388) on a pool argument typed `RoyaltyPool<CompositionShare,
  Currency>`; the derived address encodes `(composition_id, Share,
  Currency)` (phantom-typed `RoyaltyPoolKey`, pool.move:152), so a
  foreign-parent or wrongly-typed pool aborts `EPoolNotDerivedFromParent`.
  The funds are equally pinned (hikida.move:14-31): `receive_balance`
  accepts only tickets for objects transferred to the Composition address,
  `redeem_balance` withdraws from that object's own funds accumulator. A
  crank chooses *which* coins and *how much* — never *where they go*.
- **Object binding is sound.** `composition::uid_mut` is type-scoped
  (composition.move:222), but exactly one `CompositionAdminCap` exists per
  share type: `composition::new` derives it via `claim` and consumes the
  only share treasury cap through `share::initialize`
  (composition.move:134-164; one `Currency`/cap per share type via registry
  singleton + OTW gates — see `miso_share` AUDIT.md). Type-scoped
  authorization cannot cross objects in production; `assert_admin` is
  defense-in-depth, pinned by test against synthetic duplicates.
- **Arithmetic.** The plugin does no math itself. Pool-side, `deposit`
  computes `reward_per_share = value · 10¹⁸ / staked_shares` in u128
  (pool.move:182-197); with the fixed share supply `staked_shares ≤ 10¹³`,
  every nonzero deposit advances the accumulator by ≥ 10⁵ — the
  truncation-to-zero case that would lock a deposit is impossible by
  construction. Claims floor per-stake (`calculate_reward`, pool.move:393),
  never overpay, and preserve sub-base-unit residue across claims.
- **Funds have no other exit.** The pool's only withdrawal is
  `claim_rewards` to a registered stake (pool.move:288). `deposit` aborts
  while no shares are staked (`ENoStakedShares`), so funds at the
  Composition address wait, undivertible, until a stake registers.

## Edge cases & caller obligations

1. **Register a stake before funding.** Cranks abort `ENoStakedShares`
   until the first `register_stake`; funds at the Composition address are
   safe but idle meanwhile. Zero-value folds also abort (`EInvalidValue` /
   `ENoValueToRedeem`, hikida.move:56).
2. **`uninstall` is immediate** — cranks and pool creation then abort
   `EPluginNotAuthorized`; funds already in the pool are unaffected.
3. **Vault replacement needs re-install.** The pool address is stable
   (`pool_address`, `:102-106`, pinned by test across a destroy/recreate
   cycle), but the replacement Vault starts with no authorized plugins.
4. **The admin chooses `Currency` at pool creation.** One canonical pool per
   `(Composition, Currency)`; a pool for an unintended currency derives to
   its own address and cannot squat the canonical one.
5. **Do not leave a bare shared `Stake`.** Pool-side, `claim_rewards`
   returns a caller-owned `Balance` to whoever passes `&mut Stake`, so a
   bare shared stake is drainable by anyone. Keep stakes address-owned or
   wrapped (e.g. `composition_routed_stake`).
6. **Share supply bound is inherited, not enforced here.** The precision
   argument assumes `staked_shares ≤ 10¹³`; it holds because
   `CompositionShare` is issued through `miso_share::initialize` (fixed 10¹³
   supply, 6 decimals). Do not reuse `RoyaltyPool` with other share types.

## Verification

- **8/8 tests passing** (`sui move test`): installation lifecycle and
  non-idempotence (`EPluginAlreadyAuthorized`), init-before-install
  (`EPluginNotAuthorized`), foreign-vault-admin (`ENotVaultAdmin`),
  wrong-parent-pool (`EPoolNotDerivedFromParent`), pool-identity stability
  across vault replacement, end-to-end receive/redeem folding with reward
  claims, and a stranger-crank test proving the crank needs no capability.
  Fixtures are production-shaped — real `composition::new`, genuine
  fixed-supply currency, stake carved from the real share supply.
- `sui move build --lint` warning-clean; test-only helpers confined to
  `#[test_only]` wrappers.
- Session hardening commits relevant here: `f23f557` (production-shaped
  fixtures), `e783155` (plain u64 error constants), `77d6bdb`
  (double-install, stranger-crank, foreign-admin test gaps).

## Load-bearing assumptions

- **Framework** (pinned rev `06734f6`): derived-object `claim` collision
  freeness/singleton semantics; `public_receive` recipient binding;
  `redeem_funds`/`withdraw_funds_from_object` UID gating; registry
  singleton + OTW/private-generics gates behind share-cap uniqueness.
  Re-verify on framework change.
- **`vault`**: hot-potato `Borrow` semantics and the authorization bag are
  the entire privilege boundary for the custodied cap.
- **`royalty_pool`**: no withdrawal path besides `claim_rewards`;
  `ENoStakedShares` behavior; accumulator math as above.
- **`miso_share`**: fixed supply of exactly 10¹³ and one currency/cap per
  share type. The previously pinned rev (`047d74d`) predated the
  `ETreasuryCapMismatch` hardening in `share@d67ff8c`; per the `miso_share`
  audit that fix is defense-in-depth — cap uniqueness already makes the
  mismatched-cap path unreachable. **Resolved 2026-08-23: re-pinned `miso` to
  `c23fe7fc`, which pins `miso_share` at exactly
  `d67ff8cd377db2809fc97455e82e87ff1794073e`** (verified in `Move.lock`);
  `sui move build && sui move test` green (8/8) at the new pin.
- **`miso`**: one `CompositionAdminCap` per share type (derived claim +
  treasury-cap consumption in `composition::new`), making type-scoped
  `uid_mut` object-unique in practice.
