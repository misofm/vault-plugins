// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault-authorized withdrawals from a Party's object inbox and funds accumulator.
///
/// Anyone may address objects or funds to a Party ID. This plugin is the bounded
/// withdrawal door: it temporarily leases the matching `PartyAdminCap`, uses it
/// only to reach that Party's UID, and returns it to the Vault. Object withdrawals
/// transfer to the recipient selected by the Vault administrator; monetary
/// withdrawals return a composable `Balance` for the caller's PTB to consume.
///
/// Installation alone never makes withdrawals permissionless. Every production
/// withdrawal is a `public fun` requiring the matching `VaultAdminCap`, and no
/// endpoint returns the leased capability, its borrow receipt, or a privileged
/// reference. The Party itself stores no plugin data.
module party_wallet::party_wallet;

use hikida::hikida;
use miso_party::party::{Party, PartyAdminCap};
use party_wallet::witness::{Self, Witness};
use sui::balance::Balance;
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;
use vault::vault::{Vault, VaultAdminCap};

// === Errors ===

/// A batch receive was called without any objects.
const ENothingToReceive: u64 = 0;

/// The supplied VaultAdminCap belongs to another Vault.
const ENotVaultAdmin: u64 = 1;

// === Events ===

/// Emitted once per object taken out of a Party's transfer-to-object inbox.
public struct ObjectReceivedEvent has copy, drop {
    party_id: ID,
    object_id: ID,
}

/// Emitted when coin objects are received and merged for one withdrawal.
public struct CoinsReceivedEvent<phantom Currency> has copy, drop {
    party_id: ID,
    amount: u64,
    coins: u64,
}

/// Emitted when funds are redeemed from a Party's accumulator balance.
public struct FundsRedeemedEvent<phantom Currency> has copy, drop {
    party_id: ID,
    amount: u64,
}

// === Installation ===

/// Authorize this package on a Party capability Vault.
public fun install(
    vault: &mut Vault<PartyAdminCap>,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new())
}

/// Revoke this package from a Party capability Vault.
public fun uninstall(
    vault: &mut Vault<PartyAdminCap>,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
) {
    vault.revoke_plugin<PartyAdminCap, Witness>(vault_admin_cap)
}

// === Transfer-to-object withdrawals ===

/// Receive one `key + store` object addressed to the Party and transfer it to
/// `recipient`.
///
/// Aborts if the Vault administrator is wrong, the plugin is not installed, the
/// Vault contains another Party's cap, or the receiving ticket is invalid for the
/// supplied Party.
public fun receive_object<T: key + store>(
    vault: &mut Vault<PartyAdminCap>,
    party: &mut Party,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
    object_to_receive: Receiving<T>,
    recipient: address,
) {
    assert_admin(vault, vault_admin_cap);
    let party_id = object::id(party);
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let received = take(party.uid_mut(&cap), party_id, object_to_receive);
    vault.put_back(cap, receipt);
    transfer::public_transfer(received, recipient)
}

/// Receive several `key + store` objects of one type and transfer each to
/// `recipient` in input order.
///
/// Aborts with `ENothingToReceive` if `objects_to_receive` is empty. It also
/// aborts under the authorization and receiving conditions documented by
/// `receive_object`.
public fun receive_objects<T: key + store>(
    vault: &mut Vault<PartyAdminCap>,
    party: &mut Party,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
    objects_to_receive: vector<Receiving<T>>,
    recipient: address,
) {
    assert_admin(vault, vault_admin_cap);
    assert!(!objects_to_receive.is_empty(), ENothingToReceive);
    let party_id = object::id(party);
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let uid = party.uid_mut(&cap);
    let received = objects_to_receive.map!(|ticket| take(uid, party_id, ticket));
    vault.put_back(cap, receipt);
    received.destroy!(|object| transfer::public_transfer(object, recipient))
}

/// Receive coin objects of one currency, merge them, and return their combined
/// Balance for the caller's PTB to consume.
///
/// Aborts with `ENothingToReceive` if `coins` is empty. It also aborts if the
/// Vault administrator, plugin installation, Party capability, or a receiving
/// ticket is invalid.
public fun receive_coins<Currency>(
    vault: &mut Vault<PartyAdminCap>,
    party: &mut Party,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
    coins: vector<Receiving<Coin<Currency>>>,
): Balance<Currency> {
    assert_admin(vault, vault_admin_cap);
    assert!(!coins.is_empty(), ENothingToReceive);
    let party_id = object::id(party);
    let count = coins.length();
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let balance = hikida::receive_balance(party.uid_mut(&cap), coins);
    vault.put_back(cap, receipt);
    emit(CoinsReceivedEvent<Currency> { party_id, amount: balance.value(), coins: count });
    balance
}

// === Accumulator withdrawals ===

/// Redeem `value` from the Party's accumulator and return a Balance for the
/// caller's PTB to consume.
///
/// Aborts if the Vault administrator is wrong, the plugin is not installed, the
/// Vault contains another Party's cap, `value` is zero, or the accumulator cannot
/// cover the requested amount.
public fun redeem_balance<Currency>(
    vault: &mut Vault<PartyAdminCap>,
    party: &mut Party,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
    value: u64,
): Balance<Currency> {
    assert_admin(vault, vault_admin_cap);
    let party_id = object::id(party);
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let balance = hikida::redeem_balance<Currency>(party.uid_mut(&cap), value);
    vault.put_back(cap, receipt);
    emit(FundsRedeemedEvent<Currency> { party_id, amount: balance.value() });
    balance
}

// === Views ===

/// Return whether this plugin is installed on `vault`.
public fun is_installed(vault: &Vault<PartyAdminCap>): bool {
    vault.is_plugin_authorized<PartyAdminCap, Witness>()
}

/// Return the Party ID as the address to which objects or funds may be sent.
public fun inbox_address(party: &Party): address {
    object::id(party).to_address()
}

// === Private helpers ===

fun assert_admin(
    vault: &Vault<PartyAdminCap>,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
) {
    assert!(object::id(vault) == vault_admin_cap.vault_id(), ENotVaultAdmin)
}

fun take<T: key + store>(
    uid: &mut UID,
    party_id: ID,
    object_to_receive: Receiving<T>,
): T {
    let received = transfer::public_receive(uid, object_to_receive);
    emit(ObjectReceivedEvent { party_id, object_id: object::id(&received) });
    received
}

// === Test helpers ===

#[test_only]
public fun install_for_testing(
    vault: &mut Vault<PartyAdminCap>,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
) {
    install(vault, vault_admin_cap)
}

#[test_only]
public fun uninstall_for_testing(
    vault: &mut Vault<PartyAdminCap>,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
) {
    uninstall(vault, vault_admin_cap)
}

#[test_only]
public fun receive_object_for_testing<T: key + store>(
    vault: &mut Vault<PartyAdminCap>,
    party: &mut Party,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
    object_to_receive: Receiving<T>,
    recipient: address,
) {
    receive_object(vault, party, vault_admin_cap, object_to_receive, recipient)
}

#[test_only]
public fun receive_objects_for_testing<T: key + store>(
    vault: &mut Vault<PartyAdminCap>,
    party: &mut Party,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
    objects_to_receive: vector<Receiving<T>>,
    recipient: address,
) {
    receive_objects(vault, party, vault_admin_cap, objects_to_receive, recipient)
}

#[test_only]
public fun receive_coins_for_testing<Currency>(
    vault: &mut Vault<PartyAdminCap>,
    party: &mut Party,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
    coins: vector<Receiving<Coin<Currency>>>,
): Balance<Currency> {
    receive_coins(vault, party, vault_admin_cap, coins)
}

#[test_only]
public fun redeem_balance_for_testing<Currency>(
    vault: &mut Vault<PartyAdminCap>,
    party: &mut Party,
    vault_admin_cap: &VaultAdminCap<PartyAdminCap>,
    value: u64,
): Balance<Currency> {
    redeem_balance<Currency>(vault, party, vault_admin_cap, value)
}

#[test_only]
public fun object_received_event_fields(event: &ObjectReceivedEvent): (ID, ID) {
    (event.party_id, event.object_id)
}

#[test_only]
public fun coins_received_event_fields<Currency>(
    event: &CoinsReceivedEvent<Currency>,
): (ID, u64, u64) {
    (event.party_id, event.amount, event.coins)
}

#[test_only]
public fun funds_redeemed_event_fields<Currency>(
    event: &FundsRedeemedEvent<Currency>,
): (ID, u64) {
    (event.party_id, event.amount)
}
