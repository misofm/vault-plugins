# Security Review — `party_wallet`

## Scope and verdict

This review covers the Vault-plugin conversion in `sources/party_wallet.move`
and `sources/witness.move`. It is an internal design review, not an independent
audit. No unrestricted or permissionless withdrawal path is present.

## Authority flow

Every withdrawal performs the same sequence:

1. Compare the supplied `VaultAdminCap<PartyAdminCap>` against the input Vault.
2. Construct the package-only `party_wallet::witness::Witness`.
3. Borrow `PartyAdminCap` through `Vault::borrow_as_plugin`.
4. Call `Party::uid_mut`, which binds that capability to the exact Party.
5. Receive or redeem the selected value.
6. Return the exact capability through the Vault's hot-potato receipt.
7. Emit the withdrawal event and transfer the asset to the administrator-selected
   recipient.

The plugin never returns `PartyAdminCap`, `sui::borrow::Borrow`, `Witness`, or
`&mut UID`. Production withdrawal functions are composable `public fun`s, but
they require the matching `VaultAdminCap`, return the leased cap internally,
and transfer rather than return the withdrawn asset, so downstream packages
cannot use them as authority trampolines.

## Findings

- No critical, high, medium, or low findings identified in this conversion.
- The plugin intentionally grants the matching Vault administrator unrestricted
  selection of receiving tickets, accumulator amounts, object types, currencies,
  and recipient addresses. This is equivalent to the authority of the custodied
  `PartyAdminCap`; installation does not delegate that choice to other callers.
  **Disposition (2026-08-24):** accepted-by-design — the selection power is
  equivalent to the custodied `PartyAdminCap`'s own authority and reaches no
  other caller.
- Anyone may send junk objects to a Party address. The administrator selects which
  tickets to receive, so unsolicited objects do not force execution or storage in
  the Party object.
- `public_receive` is restricted to `T: key + store`, preserving transfer rules for
  types whose defining modules withheld `store`.
- Funded accumulator reads and insufficient-balance enforcement depend on framework
  natives stubbed by the Move unit-test VM and require an on-chain integration check.
  **Disposition (2026-08-24):** accepted — unit-test VM limitation, not a code
  gap; the on-chain integration check is the required follow-up before
  production reliance.

## Regression tests

The suite covers installation and revocation, pre-install and post-revocation
rejection, foreign Vault administration, a Vault bound to another Party, generic
object receipt, batch receipt, coin merging, accumulator redemption, event payloads,
empty batches, zero redemption, group Parties, and permissionless views.
