# Security Audit — `composition_routed_stake`

**Revision:** `77d6bdb8e680479b8d1d4ae250d07115d9323070` (repo HEAD) ·
**Date:** 2026-08-22 · **Toolchain:** sui 1.77.2 ·
**Framework:** pinned rev `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`

**Pinned dependencies** (`Move.toml`): `miso` `c23fe7fc` (re-pinned from
`7c13e40a` 2026-08-23 for the `miso_share` `d67ff8c` hardening, transitive)
· `vault` `2c799916` · `hikida` `e88c6fa8` · `royalty_pool` `8470e492` ·
`routed_stake` `acd5741e` (full revs in `Move.toml`).

Audit of the routed-stake vault plugin. Verdict: **safe to publish — no
Critical/High/Medium findings.**

## What it is

A `Vault<CompositionAdminCap<CompositionShare>>` plugin that redeems Recording
shares held at a Composition address and places them in the generic
`routed_stake::RoutedStake` primitive — an independently shared, derived
wrapper around a `Stake`. It exists to close a real drain: a bare shared
`Stake` is claimable by anyone (`claim_rewards` returns a caller-owned
`Balance`), so Composition-owned Recording shares must never sit in a raw
shared stake. The wrapper fixes the reward route to the Composition's own
royalty pool; the plugin adds the vault-cap-gated lifecycle around it.

## Why it's safe

**Capability gating.** Every state-changing endpoint is `entry fun` and takes
the matching `VaultAdminCap`, verified against the vault by object ID
(`assert_admin`, `composition_routed_stake.move:164-169`). The vault's
`borrow_as_plugin(witness::new())` enforces installation (the `Witness` is
`public(package)`, `witness.move:9` — only this package can mint it), and the
cap is returned via `put_back` in the same call; nothing authority-bearing
ever leaves a function.

**Funds flow.** Principal enters only from balances previously sent to the
Composition address (`hikida::redeem_balance` under `composition.uid_mut`,
lines 70, 142) and leaves only back to that same address — `unstake` does
`shares.send_funds(composition_id.to_address())` (line 125) and returns
nothing. Rewards never surface as a claimable balance: the only claim path is
the permissionless `routed_stake::sweep`, which asserts both the wrapper and
the destination pool derive from the same parent ID and deposits directly
into the pool (`routed_stake.move:199-222`). A crank caller can neither
redirect nor keep value; the lifecycle test sweeps as a capability-less
`STRANGER` and the funds land in the Composition pool intact.

**Object binding.** The plugin self-enforces every derivation rather than
trusting supplied objects:

- `create_stake` asserts `recording.composition_id() == composition.id()`
  (line 65) — a same-typed foreign Recording is rejected.
- `register`/`unregister`/`unstake`/`restake` assert the wrapper's address
  equals `routed_stake::derived_address(composition.id())`
  (`assert_stake_for_composition`, lines 181-189) — a wrapper derived from
  another Composition cannot be mixed in.
- `register`/`unregister` pin the pool to the supplied Recording
  (`assert_pool_for_recording`, lines 171-179) — same-typed pools derived
  from foreign parents (production-legal objects, e.g. a sibling Recording)
  are rejected on both paths.

**Arithmetic.** None in this package. Reward math lives in `royalty_pool`
(floor rounding, supply ≤ 10¹³ inherited from `miso_share`'s fixed 6-decimal
supply); principal values pass through untouched.

**Wrapper persistence.** The wrapper is never deleted: `unstake` empties it,
`restake` refills it, so the one derived address per
`(Composition, RecordingShare)` pair stays usable forever. A filled wrapper
rejects `restake` (`EStakeExists`), an empty one rejects `unstake`/`register`
(`ENoStake`).

## Edge cases & caller obligations

1. **Sweep before unregister** — the pool refuses to unregister a stake with
   pending rewards. A guarantee, not friction: accrued rewards provably reach
   the Composition pool before the position can move.
2. **Unstake requires zero registrations** — unregister every currency first,
   or `stake::destroy` aborts.
3. **One wrapper per share type** — the derivation key encodes only
   `RecordingShare`, so `PoolShare` is caller-chosen at `create_stake` and
   burned into the address forever. Always use the Composition's own share
   type; the plugin's views (`stake_address`) assume it.
4. **Rewards can be stranded, not stolen** — a positive `sweep` aborts if the
   Composition pool has no registered stakes; rewards stay claimable in the
   wrapper until a holder registers.
5. **`uninstall` is immediate** — revoking the witness disables all lifecycle
   endpoints while principal remains in the shared wrapper; reinstall to
   recover access.
6. **`create_stake`/`restake` abort on zero value** (inside `stake::new`) —
   check the Composition address balance first.

## Verification

- **10/10 tests passing** (`sui move test`), all in
  `tests/composition_routed_stake_tests.move`:
  - `complete_shared_lifecycle_routes_rewards_and_preserves_principal` —
    production-shaped, multi-transaction, genuinely shared objects; install →
    create → register → deposit → **stranger crank sweep** → claim →
    unregister → unstake → restake → uninstall → vault destroy.
  - Authorization negatives: lifecycle before install
    (`EPluginNotAuthorized`), double-install (`EPluginAlreadyAuthorized`),
    foreign `VaultAdminCap` (`ENotVaultAdmin`).
  - Binding negatives: foreign-Composition recording
    (`ERecordingNotForComposition`), foreign-Composition stake
    (`EStakeNotForComposition`), wrong-parent pool on **both** register and
    unregister (`EPoolNotForRecording`).
  - Wrapper state negatives: `EStakeExists` on filled restake, `ENoStake` on
    double unstake.
- **Lint:** `sui move build --lint` clean.
- **Hardening this session:** `f23f557` (production-shaped fixtures,
  wrong-parent pool negatives), `5d202e7` (plugin self-enforces object
  bindings instead of delegating; `unregister` pool pin; `create_stake`
  recording↔composition assert), `e783155` (u64 error conventions),
  `77d6bdb` (double-install, stranger-crank, `EStakeExists`/`ENoStake`
  coverage).

## Load-bearing assumptions

- **Share-type ↔ object uniqueness** (from `miso_share`/framework): one
  currency, one cap, one Composition/Recording object per share type, so
  type-scoped `uid_mut` authorization is sound and several of the plugin's
  asserts are defense-in-depth that cannot fire on-chain.
- **Supply ≤ 10¹³** for `royalty_pool` reward math (miso_share fixed supply,
  6 decimals).
- **`routed_stake` correctness**: derivation-key pinning, sweep destination
  assertion, burned-address/persistence semantics (verified at the pinned
  rev; the wrapper is the mitigation for the bare-`Stake` drain).
- **`vault` borrow/put_back soundness** and witness-gated plugin
  authorization; **`hikida::redeem_balance` semantics** (only funds sent to
  the object's own address are redeemable under its UID).
- `bps` and `hikida` independently audited clean this week (their AUDIT.md
  files); re-verify all of the above on any dependency rev change.
