# Security Review — `party_wallet`

## Scope and verdict

This review covers the Vault-plugin conversion in `sources/party_wallet.move`
and `sources/witness.move`. It is an internal design review, not an independent
audit. No unrestricted or permissionless withdrawal path is present.

## Authority flow

Every withdrawal performs the same sequence:

1. Compare the supplied `VaultAdminCap<PartyAdminCap>` against the input Vault.
2. For a sweep, read and validate the commit-settled accumulator amount.
3. Construct the package-only `party_wallet::witness::Witness`.
4. Borrow `PartyAdminCap` through `Vault::borrow_as_plugin`.
5. Call `Party::uid_mut`, which binds that capability to the exact Party.
6. Receive the selected object or redeem the selected/settled amount. Object
   receipt emits one event per object at this point.
7. Return the exact capability through the Vault's hot-potato receipt.
8. Transfer received objects to the explicit recipient, or emit the monetary
   event and return an unwrapped `Balance` to the caller's PTB.

The plugin never returns `PartyAdminCap`, `sui::borrow::Borrow`, `Witness`, or
`&mut UID`. Production withdrawal functions are composable `public fun`s, but
they require the matching `VaultAdminCap` and return the leased cap internally.
Monetary endpoints return only `Balance<Currency>` after relinquishing all
authority; downstream packages can compose the funds but cannot use them as
authority trampolines.

## Findings

- No critical, high, medium, or low findings identified in this conversion.
- The plugin intentionally grants the matching Vault administrator unrestricted
  selection of receiving tickets, accumulator amounts, object types, currencies,
  and object recipient addresses. Returned balances can likewise be routed by
  that administrator's PTB. This is equivalent to the authority of the custodied
  `PartyAdminCap`; installation does not delegate that choice to other callers.
  **Disposition (2026-08-24):** accepted-by-design — the selection power is
  equivalent to the custodied `PartyAdminCap`'s own authority and reaches no
  other caller.
- Anyone may send junk objects to a Party address. The administrator selects which
  tickets to receive, so unsolicited objects do not force execution or storage in
  the Party object.
- `public_receive` is restricted to `T: key + store`, preserving transfer rules for
  types whose defining modules withheld `store`.
- The Move unit-test VM does not populate funded `AccumulatorRoot` snapshots.
  `sweep_balance` therefore has unit coverage for its empty snapshot and shares
  the tested exact-redemption, event, Balance return, and authorization path
  with `redeem_balance`, while a nonzero settled snapshot requires network
  coverage.
  **Disposition (2026-08-24):** accepted — unit-test VM limitation, not a code
  gap; the on-chain integration check is the required follow-up before
  production reliance.

## Regression tests

The suite covers installation and revocation, pre-install and post-revocation
rejection, foreign Vault administration, a Vault bound to another Party, generic
object receipt, batch receipt, coin-to-balance merging, exact accumulator redemption,
empty settled-balance sweeping, event payloads, empty batches, zero redemption,
group Parties, and permissionless views.
