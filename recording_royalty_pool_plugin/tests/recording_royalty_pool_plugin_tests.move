// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_royalty_pool_plugin::recording_royalty_pool_plugin_tests;

use miso::recording::{Self, Recording, RecordingAdminCap};
use miso::test_helpers;
use recording_royalty_pool::recording_royalty_pool as action;
use recording_royalty_pool_plugin::recording_royalty_pool_plugin as plugin;
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;
use vault::vault::{Self, Vault, VaultAdminCap};

const EPoolNotDerivedFromParent: u64 = 0;
const EPluginAlreadyAuthorized: u64 = 1;
const EPluginNotAuthorized: u64 = 2;
const ENotVaultAdmin: u64 = 0;

const STRANGER: address = @0x51;

public struct SHARE() has drop;
public struct FOREIGN_SHARE() has drop;
public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

fun new_vault<Cap: key + store>(
    cap: Cap,
    ctx: &mut TxContext,
): (Vault<Cap>, VaultAdminCap<Cap>) {
    let mut registry = vault::new_registry_for_testing(ctx);
    let (vault, vault_admin_cap) = vault::new(&mut registry, cap, ctx);
    destroy(registry);
    (vault, vault_admin_cap)
}

fun fixture(
    ctx: &mut TxContext,
): (
    Recording<SHARE, COMPOSITION_SHARE>,
    Vault<RecordingAdminCap<SHARE>>,
    VaultAdminCap<RecordingAdminCap<SHARE>>,
) {
    let (recording, cap) = recording::new_for_testing<SHARE, COMPOSITION_SHARE>(
        test_helpers::fake_id(ctx),
        ctx,
    );
    let (vault, vault_admin_cap) = new_vault(cap, ctx);
    (recording, vault, vault_admin_cap)
}

fun new_pool(
    recording: &mut Recording<SHARE, COMPOSITION_SHARE>,
    vault: &mut Vault<RecordingAdminCap<SHARE>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<SHARE>>,
): RoyaltyPool<SHARE, CURRENCY> {
    let (cap, receipt) = vault.borrow_as_admin(vault_admin_cap);
    let pool = action::new_pool<SHARE, COMPOSITION_SHARE, CURRENCY>(recording, &cap);
    vault.put_back(cap, receipt);
    pool
}

fun cleanup(
    recording: Recording<SHARE, COMPOSITION_SHARE>,
    mut vault: Vault<RecordingAdminCap<SHARE>>,
    vault_admin_cap: VaultAdminCap<RecordingAdminCap<SHARE>>,
) {
    let cap = vault.withdraw_cap(&vault_admin_cap);
    destroy(vault_admin_cap);
    destroy(vault);
    destroy(cap);
    destroy(recording)
}

#[test]
fun direct_action_and_capless_plugin_have_identical_effects() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut recording, mut vault, vault_admin_cap) = fixture(scenario.ctx());
    let recording_id = object::id(&recording);
    let cap_id = vault.cap_id();
    let mut pool = new_pool(&mut recording, &mut vault, &vault_admin_cap);
    let pool_id = object::id(&pool);
    let mut stake = stake::new(balance::create_for_testing<SHARE>(100), scenario.ctx());
    pool.register_stake(&mut stake);

    let direct_coin = coin::from_balance(
        balance::create_for_testing<CURRENCY>(111),
        scenario.ctx(),
    );
    let direct_coin_id = object::id(&direct_coin);
    transfer::public_transfer(direct_coin, recording_id.to_address());
    scenario.next_tx(@0xA);
    let direct_ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(direct_coin_id);
    let (cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    action::receive_and_deposit(
        &mut recording,
        &cap,
        &mut pool,
        vector[direct_ticket],
    );
    vault.put_back(cap, receipt);
    let direct_deposits =
        event::events_by_type<pool::RoyaltyDepositedEvent<SHARE, CURRENCY>>();
    assert_eq!(direct_deposits.length(), 1);
    let (direct_pool, direct_value) = pool::deposited_event_fields(&direct_deposits[0]);

    plugin::install(&mut vault, &vault_admin_cap);
    assert!(plugin::is_installed(&vault));
    let plugin_coin = coin::from_balance(
        balance::create_for_testing<CURRENCY>(222),
        scenario.ctx(),
    );
    let plugin_coin_id = object::id(&plugin_coin);
    transfer::public_transfer(plugin_coin, recording_id.to_address());
    scenario.next_tx(STRANGER);
    let plugin_ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(plugin_coin_id);
    plugin::receive_and_deposit_for_testing(
        &mut vault,
        &mut recording,
        &mut pool,
        vector[plugin_ticket],
    );
    balance::create_for_testing<CURRENCY>(333).send_funds(recording_id.to_address());
    plugin::redeem_and_deposit_for_testing(&mut vault, &mut recording, &mut pool, 333);

    assert_eq!(pool.cumulative_deposits(), 666);
    let deposits = event::events_by_type<pool::RoyaltyDepositedEvent<SHARE, CURRENCY>>();
    assert_eq!(deposits.length(), 2);
    let (plugin_pool, plugin_value) = pool::deposited_event_fields(&deposits[0]);
    assert_eq!(direct_pool, pool_id);
    assert_eq!(plugin_pool, pool_id);
    assert_eq!(direct_value, 111);
    assert_eq!(plugin_value, 222);

    let (cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    assert_eq!(object::id(&cap), cap_id);
    vault.put_back(cap, receipt);
    let reward = pool.claim_rewards(&mut stake);
    assert_eq!(reward.value(), 666);
    pool.unregister_stake(&mut stake);
    balance::destroy_for_testing(stake::destroy(stake));
    balance::destroy_for_testing(reward);
    plugin::uninstall(&mut vault, &vault_admin_cap);
    assert!(!plugin::is_installed(&vault));
    destroy(pool);
    cleanup(recording, vault, vault_admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun operation_before_install_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, mut vault, vault_admin_cap) = fixture(ctx);
    let mut pool = new_pool(&mut recording, &mut vault, &vault_admin_cap);
    plugin::redeem_and_deposit_for_testing(&mut vault, &mut recording, &mut pool, 1);
    abort
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun operation_after_uninstall_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, mut vault, vault_admin_cap) = fixture(ctx);
    let mut pool = new_pool(&mut recording, &mut vault, &vault_admin_cap);
    plugin::install(&mut vault, &vault_admin_cap);
    plugin::uninstall(&mut vault, &vault_admin_cap);
    plugin::redeem_and_deposit_for_testing(&mut vault, &mut recording, &mut pool, 1);
    abort
}

#[test, expected_failure(abort_code = EPluginAlreadyAuthorized, location = vault)]
fun double_install_aborts_with_stable_code() {
    let ctx = &mut tx_context::dummy();
    let (_recording, mut vault, vault_admin_cap) = fixture(ctx);
    plugin::install(&mut vault, &vault_admin_cap);
    plugin::install(&mut vault, &vault_admin_cap);
    abort
}

#[test, expected_failure(abort_code = ENotVaultAdmin, location = vault)]
fun foreign_admin_cannot_install() {
    let ctx = &mut tx_context::dummy();
    let (_recording_a, mut vault_a, _admin_a) = fixture(ctx);
    let (_recording_b, _vault_b, admin_b) = fixture(ctx);
    plugin::install(&mut vault_a, &admin_b);
    abort
}

#[test, expected_failure(abort_code = ENotVaultAdmin, location = vault)]
fun foreign_admin_cannot_uninstall() {
    let ctx = &mut tx_context::dummy();
    let (_recording_a, mut vault_a, admin_a) = fixture(ctx);
    let (_recording_b, _vault_b, admin_b) = fixture(ctx);
    plugin::install(&mut vault_a, &admin_a);
    plugin::uninstall(&mut vault_a, &admin_b);
    abort
}

#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = pool)]
fun wrong_derived_pool_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, mut vault, vault_admin_cap) = fixture(ctx);
    let (mut foreign, foreign_cap) =
        recording::new_for_testing<FOREIGN_SHARE, COMPOSITION_SHARE>(
            test_helpers::fake_id(ctx),
            ctx,
        );
    let mut wrong_pool = pool::new<SHARE, CURRENCY>(foreign.uid_mut(&foreign_cap));
    plugin::install(&mut vault, &vault_admin_cap);
    plugin::redeem_and_deposit_for_testing(
        &mut vault,
        &mut recording,
        &mut wrong_pool,
        1,
    );
    abort
}
