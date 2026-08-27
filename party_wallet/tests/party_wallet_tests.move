// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module party_wallet::party_wallet_tests;

use miso_party::party::{Self, Party, PartyAdminCap};
use party_wallet::party_wallet as plugin;
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::test_scenario as ts;
use vault::vault::{Self, Vault, VaultAdminCap};

const ADMIN: address = @0xA;
const RECIPIENT: address = @0xB;
const SYSTEM: address = @0x0;
const EUnauthorized: u64 = 0;
const ENoValueToRedeem: u64 = 1;
const ENotVaultAdmin: u64 = 1;
const EPluginAlreadyAuthorized: u64 = 1;
const EPluginNotAuthorized: u64 = 2;

/// A non-Coin object standing in for a transferable stake or capability.
public struct StakeLike has key, store {
    id: UID,
    amount: u64,
}

fun new_vault<Cap: key + store>(
    cap: Cap,
    ctx: &mut TxContext,
): (Vault<Cap>, VaultAdminCap<Cap>) {
    let mut registry = vault::new_registry_for_testing(ctx);
    let (vault, admin_cap) = vault::new(&mut registry, cap, ctx);
    destroy(registry);
    (vault, admin_cap)
}

fun new_party(group: bool, ctx: &mut TxContext): (Party, PartyAdminCap) {
    let clock = sui::clock::create_for_testing(ctx);
    let kind = if (group) party::new_group_kind() else party::new_individual_kind();
    let (party, party_admin_cap) = party::new(kind, "Test Artist", &clock, ctx);
    clock.destroy_for_testing();
    (party, party_admin_cap)
}

fun new_vaulted_party(scenario: &mut ts::Scenario, group: bool, install: bool): ID {
    let (party, party_admin_cap) = new_party(group, scenario.ctx());
    let party_id = object::id(&party);
    party.share(&party_admin_cap);
    let (mut vault, vault_admin_cap) = new_vault(party_admin_cap, scenario.ctx());
    if (install) plugin::install_for_testing(&mut vault, &vault_admin_cap);
    vault.share();
    vault::transfer_admin_cap(vault_admin_cap, ADMIN);
    party_id
}

fun local_fixture(
    ctx: &mut TxContext,
): (Party, Vault<PartyAdminCap>, VaultAdminCap<PartyAdminCap>) {
    let (party, party_admin_cap) = new_party(false, ctx);
    let (vault, vault_admin_cap) = new_vault(party_admin_cap, ctx);
    (party, vault, vault_admin_cap)
}

fun send_coin<T>(scenario: &mut ts::Scenario, party_id: ID, amount: u64): ID {
    let coin = coin::mint_for_testing<T>(amount, scenario.ctx());
    let coin_id = object::id(&coin);
    transfer::public_transfer(coin, party_id.to_address());
    coin_id
}

fun ticket<T: key + store>(id: ID): sui::transfer::Receiving<T> {
    ts::receiving_ticket_by_id<T>(id)
}

fun destroy_stake(stake: StakeLike) {
    let StakeLike { id, amount: _ } = stake;
    id.delete()
}

#[test]
fun installation_is_explicit_and_revocable() {
    let ctx = &mut tx_context::dummy();
    let (party, mut vault, vault_admin_cap) = local_fixture(ctx);

    assert!(!plugin::is_installed(&vault));
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    assert!(plugin::is_installed(&vault));
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    assert!(!plugin::is_installed(&vault));

    let party_admin_cap = vault.withdraw_cap(&vault_admin_cap);
    destroy(vault_admin_cap);
    destroy(vault);
    destroy(party_admin_cap);
    destroy(party);
}

#[test, expected_failure(abort_code = EPluginAlreadyAuthorized, location = vault)]
fun plugin_cannot_be_installed_twice() {
    let ctx = &mut tx_context::dummy();
    let (_party, mut vault, vault_admin_cap) = local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    abort
}

#[test]
fun receives_and_merges_coins_into_a_balance() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_vaulted_party(&mut scenario, false, true);

    scenario.next_tx(ADMIN);
    let first = send_coin<SUI>(&mut scenario, party_id, 400);
    let second = send_coin<SUI>(&mut scenario, party_id, 600);

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let mut vault = scenario.take_shared<Vault<PartyAdminCap>>();
        let vault_admin_cap = scenario.take_from_sender<VaultAdminCap<PartyAdminCap>>();
        let received = plugin::receive_coins_for_testing<SUI>(
            &mut vault,
            &mut party,
            &vault_admin_cap,
            vector[ticket<Coin<SUI>>(first), ticket<Coin<SUI>>(second)],
        );
        assert_eq!(received.value(), 1_000);

        let events = event::events_by_type<plugin::CoinsReceivedEvent<SUI>>();
        assert_eq!(events.length(), 1);
        let (emitted_party, amount, count) = plugin::coins_received_event_fields(&events[0]);
        assert_eq!(emitted_party, party_id);
        assert_eq!(amount, 1_000);
        assert_eq!(count, 2);
        balance::destroy_for_testing(received);

        ts::return_shared(vault);
        ts::return_shared(party);
        scenario.return_to_sender(vault_admin_cap);
    };

    scenario.end();
}

#[test]
fun receives_a_non_coin_object_for_a_group_party() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_vaulted_party(&mut scenario, true, true);

    scenario.next_tx(ADMIN);
    let stake = StakeLike { id: object::new(scenario.ctx()), amount: 5_000 };
    let stake_id = object::id(&stake);
    transfer::public_transfer(stake, party_id.to_address());

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let mut vault = scenario.take_shared<Vault<PartyAdminCap>>();
        let vault_admin_cap = scenario.take_from_sender<VaultAdminCap<PartyAdminCap>>();
        plugin::receive_object_for_testing(
            &mut vault,
            &mut party,
            &vault_admin_cap,
            ticket<StakeLike>(stake_id),
            RECIPIENT,
        );

        let events = event::events_by_type<plugin::ObjectReceivedEvent>();
        assert_eq!(events.length(), 1);
        let (emitted_party, emitted_object) = plugin::object_received_event_fields(&events[0]);
        assert_eq!(emitted_party, party_id);
        assert_eq!(emitted_object, stake_id);

        ts::return_shared(vault);
        ts::return_shared(party);
        scenario.return_to_sender(vault_admin_cap);
    };

    scenario.next_tx(RECIPIENT);
    let stake = scenario.take_from_sender<StakeLike>();
    assert_eq!(object::id(&stake), stake_id);
    assert_eq!(stake.amount, 5_000);
    destroy_stake(stake);
    scenario.end();
}

#[test]
fun receives_multiple_objects() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_vaulted_party(&mut scenario, false, true);

    scenario.next_tx(ADMIN);
    let first = StakeLike { id: object::new(scenario.ctx()), amount: 11 };
    let first_id = object::id(&first);
    let second = StakeLike { id: object::new(scenario.ctx()), amount: 22 };
    let second_id = object::id(&second);
    transfer::public_transfer(first, party_id.to_address());
    transfer::public_transfer(second, party_id.to_address());

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let mut vault = scenario.take_shared<Vault<PartyAdminCap>>();
        let vault_admin_cap = scenario.take_from_sender<VaultAdminCap<PartyAdminCap>>();
        plugin::receive_objects_for_testing(
            &mut vault,
            &mut party,
            &vault_admin_cap,
            vector[ticket<StakeLike>(first_id), ticket<StakeLike>(second_id)],
            RECIPIENT,
        );
        assert_eq!(event::events_by_type<plugin::ObjectReceivedEvent>().length(), 2);
        ts::return_shared(vault);
        ts::return_shared(party);
        scenario.return_to_sender(vault_admin_cap);
    };

    scenario.next_tx(RECIPIENT);
    destroy_stake(scenario.take_from_sender<StakeLike>());
    destroy_stake(scenario.take_from_sender<StakeLike>());
    scenario.end();
}

#[test]
fun redeems_accumulator_funds_to_a_balance() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_vaulted_party(&mut scenario, false, true);

    scenario.next_tx(ADMIN);
    balance::create_for_testing<SUI>(750).send_funds(party_id.to_address());

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let mut vault = scenario.take_shared<Vault<PartyAdminCap>>();
        let vault_admin_cap = scenario.take_from_sender<VaultAdminCap<PartyAdminCap>>();
        let redeemed = plugin::redeem_balance_for_testing<SUI>(
            &mut vault,
            &mut party,
            &vault_admin_cap,
            750,
        );
        assert_eq!(redeemed.value(), 750);

        let events = event::events_by_type<plugin::FundsRedeemedEvent<SUI>>();
        assert_eq!(events.length(), 1);
        let (emitted_party, amount) = plugin::funds_redeemed_event_fields(&events[0]);
        assert_eq!(emitted_party, party_id);
        assert_eq!(amount, 750);
        balance::destroy_for_testing(redeemed);

        ts::return_shared(vault);
        ts::return_shared(party);
        scenario.return_to_sender(vault_admin_cap);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun withdrawal_is_disabled_before_installation() {
    let ctx = &mut tx_context::dummy();
    let (mut party, mut vault, vault_admin_cap) = local_fixture(ctx);
    balance::destroy_for_testing(plugin::redeem_balance_for_testing<SUI>(
        &mut vault,
        &mut party,
        &vault_admin_cap,
        1,
    ));
    abort
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun withdrawal_is_disabled_after_revocation() {
    let ctx = &mut tx_context::dummy();
    let (mut party, mut vault, vault_admin_cap) = local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    balance::destroy_for_testing(plugin::redeem_balance_for_testing<SUI>(
        &mut vault,
        &mut party,
        &vault_admin_cap,
        1,
    ));
    abort
}

#[test, expected_failure(abort_code = ENotVaultAdmin, location = plugin)]
fun withdrawal_rejects_another_vaults_admin_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut party, mut vault, vault_admin_cap) = local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    let (_other_party, _other_vault, other_vault_admin_cap) = local_fixture(ctx);
    balance::destroy_for_testing(plugin::redeem_balance_for_testing<SUI>(
        &mut vault,
        &mut party,
        &other_vault_admin_cap,
        1,
    ));
    abort
}

#[test, expected_failure(abort_code = EUnauthorized, location = miso_party::party)]
fun withdrawal_rejects_a_vault_for_another_party() {
    let ctx = &mut tx_context::dummy();
    let (mut party, _party_admin_cap) = new_party(false, ctx);
    let (_other_party, mut vault, vault_admin_cap) = local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    balance::destroy_for_testing(plugin::redeem_balance_for_testing<SUI>(
        &mut vault,
        &mut party,
        &vault_admin_cap,
        1,
    ));
    abort
}

#[test, expected_failure(abort_code = plugin::ENothingToReceive)]
fun receive_objects_rejects_an_empty_batch() {
    let ctx = &mut tx_context::dummy();
    let (mut party, mut vault, vault_admin_cap) = local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::receive_objects_for_testing<StakeLike>(
        &mut vault,
        &mut party,
        &vault_admin_cap,
        vector[],
        RECIPIENT,
    );
    abort
}

#[test, expected_failure(abort_code = plugin::ENothingToReceive)]
fun receive_coins_rejects_an_empty_batch() {
    let ctx = &mut tx_context::dummy();
    let (mut party, mut vault, vault_admin_cap) = local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    balance::destroy_for_testing(plugin::receive_coins_for_testing<SUI>(
        &mut vault,
        &mut party,
        &vault_admin_cap,
        vector[],
    ));
    abort
}

#[test, expected_failure(abort_code = ENoValueToRedeem, location = hikida::hikida)]
fun framework_settled_value_can_feed_exact_redemption() {
    let mut scenario = ts::begin(SYSTEM);
    sui::accumulator::create_for_testing(scenario.ctx());
    new_vaulted_party(&mut scenario, false, true);

    scenario.next_tx(ADMIN);
    let mut party = scenario.take_shared<Party>();
    let mut vault = scenario.take_shared<Vault<PartyAdminCap>>();
    let root = scenario.take_shared<AccumulatorRoot>();
    let vault_admin_cap = scenario.take_from_sender<VaultAdminCap<PartyAdminCap>>();
    let value = balance::settled_funds_value<SUI>(&root, plugin::inbox_address(&party));
    assert_eq!(value, 0);
    balance::destroy_for_testing(plugin::redeem_balance_for_testing<SUI>(
        &mut vault,
        &mut party,
        &vault_admin_cap,
        value,
    ));
    abort
}

#[test]
fun partial_redemptions_preserve_accumulator_remainder() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_vaulted_party(&mut scenario, false, true);

    scenario.next_tx(ADMIN);
    balance::create_for_testing<SUI>(1_000).send_funds(party_id.to_address());

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let mut vault = scenario.take_shared<Vault<PartyAdminCap>>();
        let vault_admin_cap = scenario.take_from_sender<VaultAdminCap<PartyAdminCap>>();
        let first = plugin::redeem_balance_for_testing<SUI>(
            &mut vault,
            &mut party,
            &vault_admin_cap,
            400,
        );
        assert_eq!(first.value(), 400);
        balance::destroy_for_testing(first);
        ts::return_shared(vault);
        ts::return_shared(party);
        scenario.return_to_sender(vault_admin_cap);
    };

    scenario.next_tx(ADMIN);
    {
        let mut party = scenario.take_shared<Party>();
        let mut vault = scenario.take_shared<Vault<PartyAdminCap>>();
        let vault_admin_cap = scenario.take_from_sender<VaultAdminCap<PartyAdminCap>>();
        let second = plugin::redeem_balance_for_testing<SUI>(
            &mut vault,
            &mut party,
            &vault_admin_cap,
            600,
        );
        assert_eq!(second.value(), 600);
        balance::destroy_for_testing(second);
        ts::return_shared(vault);
        ts::return_shared(party);
        scenario.return_to_sender(vault_admin_cap);
    };

    scenario.end();
}

/// Accumulator overdraw is a native failure rather than a stable Move abort
/// code, so this test intentionally accepts the native failure category.
#[test, expected_failure]
fun redeem_more_than_available_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let party_id = new_vaulted_party(&mut scenario, false, true);

    scenario.next_tx(ADMIN);
    balance::create_for_testing<SUI>(500).send_funds(party_id.to_address());

    scenario.next_tx(ADMIN);
    let mut party = scenario.take_shared<Party>();
    let mut vault = scenario.take_shared<Vault<PartyAdminCap>>();
    let vault_admin_cap = scenario.take_from_sender<VaultAdminCap<PartyAdminCap>>();
    balance::destroy_for_testing(plugin::redeem_balance_for_testing<SUI>(
        &mut vault,
        &mut party,
        &vault_admin_cap,
        501,
    ));
    abort
}

#[test]
fun inbox_address_is_the_party_id_as_an_address() {
    let ctx = &mut tx_context::dummy();
    let (party, party_admin_cap) = new_party(false, ctx);
    assert_eq!(plugin::inbox_address(&party), object::id(&party).to_address());
    destroy(party_admin_cap);
    destroy(party);
}
