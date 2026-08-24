# Party Wallet Plugin

Vault-authorized withdrawals from a Party's transfer-to-object inbox and funds
accumulator. Objects and revenue can be addressed to the stable Party identity,
while the `PartyAdminCap` remains custodied in a Vault. The plugin stores no
profile data and installation never creates a permissionless withdrawal path.

## Model

The plugin is installed on a `Vault<PartyAdminCap>`. Every withdrawal requires
the matching `VaultAdminCap<PartyAdminCap>`, constructs the package-only
`party_wallet::witness::Witness`, leases the Party capability, uses it only to
reach the matching Party UID, and returns it before transferring the withdrawn
asset.

The Vault administrator selects the recipient. This is intentionally an
administrator-triggered wallet operation: an installed plugin cannot be cranked
by an arbitrary caller to extract Party-owned value.

## Operations

- `install`: Admin-only. Authorizes the canonical package witness.
- `uninstall`: Admin-only. Immediately revokes the package witness.
- `receive_object`: Admin-only and installation-gated. Receives one `key + store`
  object sent to the Party and transfers it to the selected recipient.
- `receive_objects`: Same for a non-empty batch of one object type.
- `receive_coins`: Admin-only and installation-gated. Receives selected coin
  objects, merges them, and transfers one Coin to the selected recipient.
- `redeem_coin`: Admin-only and installation-gated. Redeems a selected amount
  from the Party's accumulator balance and transfers one Coin to the recipient.
- `is_installed`, `inbox_address`, and `settled_funds`: Read-only views.

All authority-bearing production endpoints are `entry fun`s. None returns the
leased `PartyAdminCap`, Vault receipt, witness, withdrawn asset, or a privileged
reference.

## Events

| Event | When | Payload |
|---|---|---|
| `ObjectReceivedEvent` | Each object is received from the Party inbox | `party_id`, `object_id` |
| `CoinsReceivedEvent<Currency>` | Coin objects are received and merged | `party_id`, merged `amount`, input `coins` count |
| `FundsRedeemedEvent<Currency>` | Accumulator funds are redeemed | `party_id`, `amount` |

## Permission declaration

- Target: `miso_party::party::Party`.
- Host access: receives transferred `key + store` objects and redeems accumulated
  balances through the Party UID.
- Authority: every withdrawal requires the matching
  `VaultAdminCap<PartyAdminCap>` and an installed plugin authorization.
- Funds and objects: the Vault administrator selects both the receiving tickets
  or accumulator amount and the destination address.
- Storage: no dynamic fields or other persistent Party state.
- External packages: `miso_party`, `vault`, and `hikida` at the exact revisions
  pinned in `Move.toml`.

## Integrator notes

- A Party ID is also its inbox address. Sending is permissionless; receiving is
  selective and administrator-gated.
- `settled_funds` is commit-settled and excludes funds credited earlier in the
  same transaction.
- The Move unit-test VM stubs funded accumulator accounting. The wiring and
  authorization paths are unit-tested; funded reads and insufficient-balance
  behavior must also be checked on-chain before production use.
- This package is a new Vault plugin deployment. The previously published direct
  `PartyAdminCap` package from `party-extensions` is not upgrade-compatible with
  this authority model and must not be reused as this plugin's published ID.

## Build and test

```sh
sui move build
sui move test --coverage
```
