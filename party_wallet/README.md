# Party Wallet Plugin

Vault-authorized withdrawals from a Party's transfer-to-object inbox and funds
accumulator. Objects and revenue can be addressed to the stable Party identity,
while the `PartyAdminCap` remains custodied in a Vault. The plugin stores no
profile data and installation never creates a permissionless withdrawal path.

## Model

The plugin is installed on a `Vault<PartyAdminCap>`. Every withdrawal requires
the matching `VaultAdminCap<PartyAdminCap>`, constructs the package-only
`party_wallet::witness::Witness`, leases the Party capability, uses it only to
reach the matching Party UID, and returns it before transferring received
objects or returning a monetary `Balance`.

This is intentionally an administrator-triggered wallet operation: an installed
plugin cannot be cranked by an arbitrary caller to extract Party-owned value.
Object withdrawals transfer to the administrator-selected recipient. Monetary
withdrawals return a `Balance<Currency>` that the same PTB must consume, so the
caller can deposit it directly or construct a Coin only when needed.

## Operations

- `install`: Admin-only. Authorizes the canonical package witness.
- `uninstall`: Admin-only. Immediately revokes the package witness.
- `receive_object`: Admin-only and installation-gated. Receives one `key + store`
  object sent to the Party and transfers it to the selected recipient.
- `receive_objects`: Same for a non-empty batch of one object type.
- `receive_coins`: Admin-only and installation-gated. Receives selected coin
  objects, merges them, and returns their combined `Balance`.
- `redeem_balance`: Admin-only and installation-gated. Redeems a selected amount
  from the Party's accumulator and returns it as a `Balance`.
- `sweep_balance`: Admin-only and installation-gated. Reads the Party's funds
  settled at the start of the current consensus commit, redeems that reported
  amount, and returns it as a `Balance`. It aborts with `ENoSettledFunds` when
  the snapshot is empty. The framework reports at most `u64::MAX` per call, so
  any excess requires a later sweep.
- `is_installed`, `inbox_address`, and `settled_funds`: Read-only views.

All authority-bearing production endpoints are composable `public fun`s so
callers can install and use the plugin on a Vault created earlier in the same
PTB. None returns the leased `PartyAdminCap`, Vault receipt, witness, or a
privileged reference. Monetary endpoints deliberately return only an unwrapped
`Balance<Currency>`.

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
- Funds and objects: the Vault administrator selects receiving tickets, an
  exact accumulator amount or a settled-balance sweep. Object recipients remain
  explicit; returned balances can be routed only by the PTB that supplied the
  matching Vault authority.
- Storage: no dynamic fields or other persistent Party state.
- External packages: `miso_party`, `vault`, and `hikida` at the exact revisions
  pinned in `Move.toml`.

## Integrator notes

- A Party ID is also its inbox address. Sending is permissionless; receiving is
  selective and administrator-gated.
- `settled_funds` is commit-settled and excludes funds credited earlier in the
  same transaction.
- `sweep_balance` uses that same commit snapshot. Funds credited later in the
  commit remain for another sweep, and competing sweeps can race on the same
  snapshot; accumulator redemption prevents an overdraw.
- Returned balances have no `drop` ability and must be consumed in the same PTB.
  Call `coin::from_balance(balance, ctx)` only when an owned Coin is actually
  needed; otherwise pass the Balance directly to the next Move call.
- The Move unit-test VM does not populate funded `AccumulatorRoot` snapshots.
  Exact redemption, authorization, and empty-sweep behavior are unit-tested; a
  funded settled-balance sweep must also be checked on-chain before production
  use.
- This package is a new Vault plugin deployment. The previously published direct
  `PartyAdminCap` package from `party-extensions` is not upgrade-compatible with
  this authority model and must not be reused as this plugin's published ID.

## Build and test

```sh
sui move build
sui move test --coverage
```
