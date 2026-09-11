// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_royalty_pool_plugin::composition_royalty_pool_plugin_tests;

use composition_royalty_pool::composition_royalty_pool as action;
use composition_royalty_pool_plugin::composition_royalty_pool_plugin as plugin;
use hikida::hikida;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;
use vault::vault::{Self, Vault, VaultAdminCap};

const ENoValueToRedeem: u64 = 1;
const EPoolNotDerivedFromParent: u64 = 0;
const EPluginAlreadyAuthorized: u64 = 1;
const EPluginNotAuthorized: u64 = 2;
const ENotVaultAdmin: u64 = 0;

const STRANGER: address = @0x51;

public struct SHARE() has drop;
public struct FOREIGN_SHARE() has drop;
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
    Composition<SHARE>,
    Vault<CompositionAdminCap<SHARE>>,
    VaultAdminCap<CompositionAdminCap<SHARE>>,
) {
    let (composition, cap) = composition::new_for_testing<SHARE>("Composition", 1_000, ctx);
    let (vault, vault_admin_cap) = new_vault(cap, ctx);
    (composition, vault, vault_admin_cap)
}

fun new_pool(
    composition: &mut Composition<SHARE>,
    vault: &mut Vault<CompositionAdminCap<SHARE>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<SHARE>>,
): RoyaltyPool<SHARE, CURRENCY> {
    let (cap, receipt) = vault.borrow_as_admin(vault_admin_cap);
    let pool = action::new_pool<SHARE, CURRENCY>(composition, &cap);
    vault.put_back(cap, receipt);
    pool
}

fun cleanup(
    composition: Composition<SHARE>,
    mut vault: Vault<CompositionAdminCap<SHARE>>,
    vault_admin_cap: VaultAdminCap<CompositionAdminCap<SHARE>>,
) {
    let cap = vault.withdraw_cap(&vault_admin_cap);
    destroy(vault_admin_cap);
    destroy(vault);
    destroy(cap);
    destroy(composition)
}

fun assert_plugin_event_silence() {
    assert_eq!(
        event::events_by_type<plugin::CompositionVaultCapabilityBorrowedEvent<SHARE, CURRENCY>>()
            .length(),
        0,
    );
    assert_eq!(
        event::events_by_type<plugin::CompositionCoinsDepositedEvent<SHARE, CURRENCY>>()
            .length(),
        0,
    );
    assert_eq!(
        event::events_by_type<plugin::CompositionFundsDepositedEvent<SHARE, CURRENCY>>()
            .length(),
        0,
    );
}

fun assert_installed_event(
    vault: &Vault<CompositionAdminCap<SHARE>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<SHARE>>,
    cap_id: sui::object::ID,
) {
    let events =
        event::events_by_type<plugin::CompositionRoyaltyPoolPluginInstalledEvent<SHARE>>();
    assert_eq!(events.length(), 1);
    let (vault_id, installed_cap_id, admin_cap_id, plugins_id, count, installed) =
        plugin::installed_event_fields(&events[0]);
    assert_eq!(vault_id, object::id(vault).to_address());
    assert_eq!(installed_cap_id, cap_id.to_address());
    assert_eq!(admin_cap_id, object::id(vault_admin_cap).to_address());
    assert_eq!(plugins_id, object::id(vault.authorized_plugins()).to_address());
    assert_eq!(count, 1);
    assert!(installed);
}

fun assert_uninstalled_event(
    vault: &Vault<CompositionAdminCap<SHARE>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<SHARE>>,
    cap_id: sui::object::ID,
) {
    let events =
        event::events_by_type<plugin::CompositionRoyaltyPoolPluginUninstalledEvent<SHARE>>();
    assert_eq!(events.length(), 1);
    let (vault_id, uninstalled_cap_id, admin_cap_id, plugins_id, count, installed) =
        plugin::uninstalled_event_fields(&events[0]);
    assert_eq!(vault_id, object::id(vault).to_address());
    assert_eq!(uninstalled_cap_id, cap_id.to_address());
    assert_eq!(admin_cap_id, object::id(vault_admin_cap).to_address());
    assert_eq!(plugins_id, object::id(vault.authorized_plugins()).to_address());
    assert_eq!(count, 0);
    assert!(!installed);
}

fun assert_borrowed_event(
    event: &plugin::CompositionVaultCapabilityBorrowedEvent<SHARE, CURRENCY>,
    vault_id: address,
    cap_id: address,
    composition_id: address,
    pool_id: address,
) {
    let (event_vault_id, event_cap_id, event_composition_id, event_pool_id, active, available) =
        plugin::borrowed_event_fields(event);
    assert_eq!(event_vault_id, vault_id);
    assert_eq!(event_cap_id, cap_id);
    assert_eq!(event_composition_id, composition_id);
    assert_eq!(event_pool_id, pool_id);
    assert!(active);
    assert!(!available);
}

fun assert_coins_event(
    event: &plugin::CompositionCoinsDepositedEvent<SHARE, CURRENCY>,
    vault_id: address,
    cap_id: address,
    composition_id: address,
    pool_id: address,
    pool_balance_before: u64,
    pool_balance_after: u64,
    staked_shares: u64,
    reward_per_share_before: u256,
    reward_per_share_after: u256,
    carry_before: u128,
    carry_after: u128,
    cumulative_deposits_before: u128,
    cumulative_deposits_after: u128,
    coin_ids: vector<address>,
) {
    let (
        event_vault_id,
        event_cap_id,
        event_composition_id,
        event_pool_id,
        event_pool_balance_before,
        event_pool_balance_after,
        event_staked_shares,
        event_reward_per_share_before,
        event_reward_per_share_after,
        event_carry_before,
        event_carry_after,
        event_cumulative_deposits_before,
        event_cumulative_deposits_after,
        active,
        available,
        event_coin_ids,
    ) = plugin::coins_deposited_event_fields(event);
    assert_eq!(event_vault_id, vault_id);
    assert_eq!(event_cap_id, cap_id);
    assert_eq!(event_composition_id, composition_id);
    assert_eq!(event_pool_id, pool_id);
    assert_eq!(event_pool_balance_before, pool_balance_before);
    assert_eq!(event_pool_balance_after, pool_balance_after);
    assert_eq!(event_staked_shares, staked_shares);
    assert_eq!(event_reward_per_share_before, reward_per_share_before);
    assert_eq!(event_reward_per_share_after, reward_per_share_after);
    assert_eq!(event_carry_before, carry_before);
    assert_eq!(event_carry_after, carry_after);
    assert_eq!(event_cumulative_deposits_before, cumulative_deposits_before);
    assert_eq!(event_cumulative_deposits_after, cumulative_deposits_after);
    assert!(active);
    assert!(available);
    assert_eq!(event_coin_ids, coin_ids);
}

fun assert_funds_event(
    event: &plugin::CompositionFundsDepositedEvent<SHARE, CURRENCY>,
    vault_id: address,
    cap_id: address,
    composition_id: address,
    pool_id: address,
    pool_balance_before: u64,
    pool_balance_after: u64,
    staked_shares: u64,
    reward_per_share_before: u256,
    reward_per_share_after: u256,
    carry_before: u128,
    carry_after: u128,
    cumulative_deposits_before: u128,
    cumulative_deposits_after: u128,
    amount: u64,
) {
    let (
        event_vault_id,
        event_cap_id,
        event_composition_id,
        event_pool_id,
        event_pool_balance_before,
        event_pool_balance_after,
        event_staked_shares,
        event_reward_per_share_before,
        event_reward_per_share_after,
        event_carry_before,
        event_carry_after,
        event_cumulative_deposits_before,
        event_cumulative_deposits_after,
        active,
        available,
        event_amount,
    ) = plugin::funds_deposited_event_fields(event);
    assert_eq!(event_vault_id, vault_id);
    assert_eq!(event_cap_id, cap_id);
    assert_eq!(event_composition_id, composition_id);
    assert_eq!(event_pool_id, pool_id);
    assert_eq!(event_pool_balance_before, pool_balance_before);
    assert_eq!(event_pool_balance_after, pool_balance_after);
    assert_eq!(event_staked_shares, staked_shares);
    assert_eq!(event_reward_per_share_before, reward_per_share_before);
    assert_eq!(event_reward_per_share_after, reward_per_share_after);
    assert_eq!(event_carry_before, carry_before);
    assert_eq!(event_carry_after, carry_after);
    assert_eq!(event_cumulative_deposits_before, cumulative_deposits_before);
    assert_eq!(event_cumulative_deposits_after, cumulative_deposits_after);
    assert!(active);
    assert!(available);
    assert_eq!(event_amount, amount);
}

#[test]
fun direct_action_and_capless_plugin_have_identical_effects() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut composition, mut vault, vault_admin_cap) = fixture(scenario.ctx());
    let composition_id = object::id(&composition);
    let cap_id = vault.cap_id();
    let mut pool = new_pool(&mut composition, &mut vault, &vault_admin_cap);
    let pool_id = object::id(&pool);
    let mut stake = stake::new(balance::create_for_testing<SHARE>(100), scenario.ctx());
    pool.register_stake(&mut stake);

    // The raw Action remains available without plugin installation.
    let direct_coin = coin::from_balance(
        balance::create_for_testing<CURRENCY>(111),
        scenario.ctx(),
    );
    let direct_coin_id = object::id(&direct_coin);
    transfer::public_transfer(direct_coin, composition_id.to_address());
    scenario.next_tx(@0xA);
    let direct_ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(direct_coin_id);
    let (cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    action::receive_and_deposit(
        &mut composition,
        &cap,
        &mut pool,
        vector[direct_ticket],
    );
    vault.put_back(cap, receipt);
    let direct_deposits =
        event::events_by_type<pool::RoyaltyDepositedEvent<SHARE, CURRENCY>>();
    assert_eq!(direct_deposits.length(), 1);
    let (direct_pool, direct_value) = pool::deposited_event_fields(&direct_deposits[0]);
    assert_plugin_event_silence();

    plugin::install(&mut vault, &vault_admin_cap);
    let events_before_is_installed = event::num_events();
    assert!(plugin::is_installed(&vault));
    assert_eq!(event::num_events(), events_before_is_installed);
    assert_installed_event(&vault, &vault_admin_cap, cap_id);
    let plugin_coin = coin::from_balance(
        balance::create_for_testing<CURRENCY>(222),
        scenario.ctx(),
    );
    let plugin_zero = coin::from_balance(
        balance::create_for_testing<CURRENCY>(0),
        scenario.ctx(),
    );
    let plugin_coin_id = object::id(&plugin_coin);
    let plugin_zero_id = object::id(&plugin_zero);
    transfer::public_transfer(plugin_zero, composition_id.to_address());
    transfer::public_transfer(plugin_coin, composition_id.to_address());

    // This transaction sender holds neither VaultAdminCap nor raw admin cap.
    scenario.next_tx(STRANGER);
    let plugin_zero_ticket =
        test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(plugin_zero_id);
    let plugin_ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(plugin_coin_id);
    let plugin_pool_balance_before = pool.balance().value();
    let plugin_staked_shares = pool.staked_shares();
    let plugin_reward_per_share_before = pool.cumulative_reward_per_share();
    let plugin_carry_before = pool.carry();
    let plugin_cumulative_deposits_before = pool.cumulative_deposits();
    plugin::receive_and_deposit_for_testing(
        &mut vault,
        &mut composition,
        &mut pool,
        vector[plugin_zero_ticket, plugin_ticket],
    );
    let plugin_pool_balance_after = pool.balance().value();
    let plugin_reward_per_share_after = pool.cumulative_reward_per_share();
    let plugin_carry_after = pool.carry();
    let plugin_cumulative_deposits_after = pool.cumulative_deposits();
    let borrowed_events = event::events_by_type<
        plugin::CompositionVaultCapabilityBorrowedEvent<SHARE, CURRENCY>
    >();
    assert_eq!(borrowed_events.length(), 1);
    assert_borrowed_event(
        &borrowed_events[0],
        object::id(&vault).to_address(),
        cap_id.to_address(),
        composition_id.to_address(),
        pool_id.to_address(),
    );
    let coin_events = event::events_by_type<plugin::CompositionCoinsDepositedEvent<SHARE, CURRENCY>>();
    assert_eq!(coin_events.length(), 1);
    assert_coins_event(
        &coin_events[0],
        object::id(&vault).to_address(),
        cap_id.to_address(),
        composition_id.to_address(),
        pool_id.to_address(),
        plugin_pool_balance_before,
        plugin_pool_balance_after,
        plugin_staked_shares,
        plugin_reward_per_share_before,
        plugin_reward_per_share_after,
        plugin_carry_before,
        plugin_carry_after,
        plugin_cumulative_deposits_before,
        plugin_cumulative_deposits_after,
        vector[plugin_zero_id.to_address(), plugin_coin_id.to_address()],
    );
    balance::create_for_testing<CURRENCY>(333).send_funds(composition_id.to_address());
    let funds_pool_balance_before = pool.balance().value();
    let funds_staked_shares = pool.staked_shares();
    let funds_reward_per_share_before = pool.cumulative_reward_per_share();
    let funds_carry_before = pool.carry();
    let funds_cumulative_deposits_before = pool.cumulative_deposits();
    plugin::redeem_and_deposit_for_testing(&mut vault, &mut composition, &mut pool, 333);
    let funds_pool_balance_after = pool.balance().value();
    let funds_reward_per_share_after = pool.cumulative_reward_per_share();
    let funds_carry_after = pool.carry();
    let funds_cumulative_deposits_after = pool.cumulative_deposits();
    let borrowed_events =
        event::events_by_type<plugin::CompositionVaultCapabilityBorrowedEvent<SHARE, CURRENCY>>();
    assert_eq!(borrowed_events.length(), 2);
    assert_borrowed_event(
        &borrowed_events[1],
        object::id(&vault).to_address(),
        cap_id.to_address(),
        composition_id.to_address(),
        pool_id.to_address(),
    );
    let funds_events = event::events_by_type<plugin::CompositionFundsDepositedEvent<SHARE, CURRENCY>>();
    assert_eq!(funds_events.length(), 1);
    assert_funds_event(
        &funds_events[0],
        object::id(&vault).to_address(),
        cap_id.to_address(),
        composition_id.to_address(),
        pool_id.to_address(),
        funds_pool_balance_before,
        funds_pool_balance_after,
        funds_staked_shares,
        funds_reward_per_share_before,
        funds_reward_per_share_after,
        funds_carry_before,
        funds_carry_after,
        funds_cumulative_deposits_before,
        funds_cumulative_deposits_after,
        333,
    );

    assert_eq!(pool.cumulative_deposits(), 666);
    let deposits = event::events_by_type<pool::RoyaltyDepositedEvent<SHARE, CURRENCY>>();
    assert_eq!(deposits.length(), 2);
    let (plugin_pool, plugin_value) = pool::deposited_event_fields(&deposits[0]);
    assert_eq!(direct_pool, pool_id);
    assert_eq!(plugin_pool, pool_id);
    assert_eq!(direct_value, 111);
    assert_eq!(plugin_value, 222);

    // A successful plugin crank returned the exact capability and receipt.
    let (cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    assert_eq!(object::id(&cap), cap_id);
    vault.put_back(cap, receipt);

    let reward = pool.claim_rewards(&mut stake);
    assert_eq!(reward.value(), 666);
    pool.unregister_stake(&mut stake);
    balance::destroy_for_testing(stake::destroy(stake));
    balance::destroy_for_testing(reward);
    plugin::uninstall(&mut vault, &vault_admin_cap);
    let events_before_is_installed = event::num_events();
    assert!(!plugin::is_installed(&vault));
    assert_eq!(event::num_events(), events_before_is_installed);
    assert_uninstalled_event(&vault, &vault_admin_cap, cap_id);
    destroy(pool);
    cleanup(composition, vault, vault_admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun operation_before_install_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, mut vault, vault_admin_cap) = fixture(ctx);
    let mut pool = new_pool(&mut composition, &mut vault, &vault_admin_cap);
    plugin::redeem_and_deposit_for_testing(&mut vault, &mut composition, &mut pool, 1);
    abort
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun operation_after_uninstall_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, mut vault, vault_admin_cap) = fixture(ctx);
    let mut pool = new_pool(&mut composition, &mut vault, &vault_admin_cap);
    plugin::install(&mut vault, &vault_admin_cap);
    plugin::uninstall(&mut vault, &vault_admin_cap);
    plugin::redeem_and_deposit_for_testing(&mut vault, &mut composition, &mut pool, 1);
    abort
}

#[test, expected_failure(abort_code = EPluginAlreadyAuthorized, location = vault)]
fun double_install_aborts_with_stable_code() {
    let ctx = &mut tx_context::dummy();
    let (_composition, mut vault, vault_admin_cap) = fixture(ctx);
    plugin::install(&mut vault, &vault_admin_cap);
    plugin::install(&mut vault, &vault_admin_cap);
    abort
}

#[test, expected_failure(abort_code = ENotVaultAdmin, location = vault)]
fun foreign_admin_cannot_install() {
    let ctx = &mut tx_context::dummy();
    let (_composition_a, mut vault_a, _admin_a) = fixture(ctx);
    let (_composition_b, _vault_b, admin_b) = fixture(ctx);
    plugin::install(&mut vault_a, &admin_b);
    abort
}

#[test, expected_failure(abort_code = ENotVaultAdmin, location = vault)]
fun foreign_admin_cannot_uninstall() {
    let ctx = &mut tx_context::dummy();
    let (_composition_a, mut vault_a, admin_a) = fixture(ctx);
    let (_composition_b, _vault_b, admin_b) = fixture(ctx);
    plugin::install(&mut vault_a, &admin_a);
    plugin::uninstall(&mut vault_a, &admin_b);
    abort
}

#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = pool)]
fun wrong_derived_pool_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, mut vault, vault_admin_cap) = fixture(ctx);
    let (mut foreign, foreign_cap) =
        composition::new_for_testing<FOREIGN_SHARE>("Foreign", 1_000, ctx);
    let mut wrong_pool = pool::new<SHARE, CURRENCY>(foreign.uid_mut(&foreign_cap));
    plugin::install(&mut vault, &vault_admin_cap);
    plugin::redeem_and_deposit_for_testing(
        &mut vault,
        &mut composition,
        &mut wrong_pool,
        1,
    );
    abort
}

#[test, expected_failure(abort_code = ENoValueToRedeem, location = hikida)]
fun settled_value_boundary_reaches_action_guard() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    let (mut composition, mut vault, vault_admin_cap) = fixture(scenario.ctx());
    let mut pool = new_pool(&mut composition, &mut vault, &vault_admin_cap);
    plugin::install(&mut vault, &vault_admin_cap);
    scenario.next_tx(STRANGER);
    let root = scenario.take_shared<AccumulatorRoot>();
    let value = balance::settled_funds_value<CURRENCY>(
        &root,
        object::id(&composition).to_address(),
    );
    assert_eq!(value, 0);
    plugin::redeem_and_deposit_for_testing(&mut vault, &mut composition, &mut pool, value);
    abort
}
