# Security Audit — `release_revenue_distributor`

**Revision:** `77d6bdb8e680479b8d1d4ae250d07115d9323070` (repo HEAD) ·
**Date:** 2026-08-22 · **Toolchain:** sui 1.77.2 ·
**Framework:** pinned rev `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`

Pinned dependencies (`Move.lock`): `miso` (protocol)
`c23fe7fc4323f5ed8321be209a5efc08b6a1691a` (re-pinned from `7c13e40a`
2026-08-23), `vault`
`2c799916e45befaa471ccef1918e5b8c42aeddc4`, `hikida`
`e88c6fa88348bc2764823cf3666d7ca5e08b2f4f`; transitive: `bps`
`26fa571e3d8fc79125e6a50f5b735c939a5251f6`, `miso_share`
`d67ff8cd377db2809fc97455e82e87ff1794073e` (the audited hardening rev).

Verdict: **safe to publish as-is — no Critical/High/Medium findings.**

## What it is

A vault plugin that routes Release-addressed revenue to the Recording
addresses fixed by the Release's immutable tracklist. Installed on a
`Vault<ReleaseAdminCap>`, it leases the whole admin cap per call, uses it
only to receive or redeem funds through the Release UID via `hikida`,
returns the cap in the same transaction, then applies each track's
`split_bps` (floor) to the input and sends that amount to the track's
Recording address. Per-track rounding remainder returns to the Release
address. Distribution is permissionless after installation; callers choose
only the amount or the receiving tickets — never recipients or splits.

## Why it's safe

- **Capability gating.** `install`/`uninstall` require the
  `VaultAdminCap<ReleaseAdminCap>` (`release_revenue_distributor.move:43`,
  `:51`). The distribution endpoints (`:62`, `:76`) borrow the cap through
  `vault.borrow_as_plugin(witness::new())`, which aborts
  `EPluginNotAuthorized` unless this package's canonical witness was
  authorized (`vault.move:184`); `Witness` is constructible only inside
  this package (`witness.move:9`, `public(package)`), and the vault pins
  the `0xpkg::witness::Witness` non-generic shape at authorization
  (`vault.move:245`). The `Borrow` receipt has no abilities, so the exact
  cap must be returned via `put_back` before the transaction ends —
  `:69`/`:83` return it before any distribution happens.
- **Funds flow is one-way and fixed.** Both endpoints return nothing and
  take no recipient argument. The borrowed cap is used for exactly one
  thing — `release.uid_mut(&cap)` — which is object-bound:
  `release::authorize` asserts `release.id == cap.release_id`
  (`release.move:303`, `:342`), so a vault for Release A cannot move funds
  from Release B (pinned by test). Every `send_funds` in `distribute`
  targets either a stored `track.recording_id()` (`:108`) or the Release's
  own address (`:121`). No path delivers value to the caller.
- **Recipients and splits are immutable Release data.** `distribute` reads
  only `release.tracks()`; `release::new` asserts the track splits sum to
  exactly 10,000 BPS (`release.move:233`, `EInvalidTrackSplitsSum`), tracks
  embed the recording ID at creation with the recording admin's consent
  (`track.move:121`), and embedded Release fields are frozen at publish.
  The plugin therefore cannot be steered to arbitrary addresses.
- **Arithmetic is conservative.** Each track amount is
  `track.split_bps().apply(total_input)` (`:105`) — floor division via
  stdlib widening `mul_div` with `bps ≤ 10_000` (`bps.move:119`), so no
  overflow and no overpayment. Because the splits sum to the denominator,
  `Σ amounts ≤ total_input`, so `revenue.split(amount)` never underflows
  and `total_distributed` never exceeds the input. The dust remainder
  (`< #tracks`) is returned to the Release address, not burned or kept.
- **`hikida` wrappers are UID-gated.** `redeem_balance` requires
  `&mut UID` and `value > 0` (`hikida.move:29`, `:55`);
  `receive_balance` requires `&mut UID` and a non-empty ticket vector
  (`hikida.move:14`, `:43`). Nobody without the Release's admin cap can
  pull its object-address funds, and the plugin is the only cap lease
  available to the public.

## Edge cases & caller obligations

- **Dust rounds to zero per track.** A track whose
  `split_bps * total_input < 10_000` receives nothing; the event is still
  emitted with `amount = 0` (`:107` skips the zero-value `send_funds`).
  Small distributions can leave nearly everything as remainder.
- **Remainder needs a re-crank.** Rounding dust returns to the Release
  address and is only distributed by a later `redeem_and_distribute` call.
  This is permissionless; anyone can settle it.
- **`value > 0` and non-empty tickets are enforced by `hikida`**
  (`ENoValueToRedeem`, `ENoCoinsToReceive`) — aborts, not silent no-ops.
- **`uninstall` is immediate revocation.** In-flight borrows cannot exist
  across transactions (the `Borrow` hot potato forces same-tx return), so
  revocation cannot strand the cap.
- **Recording custody boundary.** This plugin stops at sending funds to
  Recording object addresses; folding them into a Recording's royalty pool
  is the `recording_royalty_pool` plugin's job. Integrators must not treat
  "distributed" as "claimable by share holders".
- **`uid_mut` is root over Release dynamic fields** (`release.move:336`):
  the leased cap could mutate extension data in principle. This plugin's
  bytecode uses it only for `hikida` receive/redeem, but the trust
  assumption on the cap holder is permanent — model accordingly.

## Verification

- **6/6 tests passing** (`sui move test`), covering:
  - installation lifecycle: `installation_is_explicit_and_revocable`,
    `installation_is_not_idempotent` (`EPluginAlreadyAuthorized`);
  - authorization negatives: `revenue_cannot_be_redeemed_before_installation`
    (`EPluginNotAuthorized`), `release_cannot_use_another_releases_vault`
    (`EUnauthorized` from `release::authorize` — the object-binding proof);
  - distribution correctness: `redeemed_revenue_is_forced_to_track_recordings`
    (10,001 in → 6,000 + 4,000 to the two Recordings, remainder 1 to the
    Release, full event-payload assertions),
    `received_coins_are_combined_and_distributed` (multi-coin
    `test_scenario` flow cranked by a different sender).
- Fixtures are production-shaped (`f23f557`): the fixture is generic over
  recording share types so no share type repeats across recordings — a
  state on-chain issuance gates make impossible.
- `sui move build --lint` warning-clean.
- This session's hardening commits relevant here: `f23f557` (fixtures),
  `e783155` (u64 error conventions), `77d6bdb` (double-install and
  wrong-vault negatives).

## Load-bearing assumptions

- **`release` split-sum invariant and tracklist immutability** — the
  conservation argument collapses if splits can exceed 10,000 in total or
  mutate after publish (verified at the pinned `miso` rev).
- **`vault` witness gating + hot-potato return** — plugin authorization is
  the only thing standing between the public and the leased admin cap.
- **`bps` floor semantics** — the pinned rev `26fa571e` predates the
  audited hardening rev `26e5ee2` cited in the `bps` AUDIT.md; the only
  source delta between them is the u256 totality rewrite. This package uses
  only u64 `apply`, which is byte-identical in both revs (verified by
  diff), so the finding does not apply here.
- **`miso_share` uniqueness/supply bounds are not load-bearing for this
  package** — it never touches share types; funds route by stored object ID
  alone. (They matter downstream, in the royalty-pool plugins.)
- **`hikida` audited clean** at exactly the pinned rev (`e88c6fa`).
