// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_royalty_pool::composition_royalty_pool_tests;

use composition_royalty_pool::composition_royalty_pool as plugin;
use miso::composition::{Self, Composition, CompositionAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::coin::{Self, Coin};
use sui::test_scenario;
use vault::vault::{Self, Vault, VaultAdminCap};

const EPluginNotAuthorized: u64 = 2;
const EPoolNotDerivedFromParent: u64 = 0;

public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

fun fixture(
    ctx: &mut TxContext,
): (
    Composition<COMPOSITION_SHARE>,
    Vault<CompositionAdminCap<COMPOSITION_SHARE>>,
    VaultAdminCap<CompositionAdminCap<COMPOSITION_SHARE>>,
) {
    let (composition, cap) = composition::new_for_testing<COMPOSITION_SHARE>(
        "Composition",
        1_000,
        ctx,
    );
    let (vault, vault_admin_cap) = vault::new(cap, ctx);
    (composition, vault, vault_admin_cap)
}

fun destroy_fixture(
    composition: Composition<COMPOSITION_SHARE>,
    vault: Vault<CompositionAdminCap<COMPOSITION_SHARE>>,
    vault_admin_cap: VaultAdminCap<CompositionAdminCap<COMPOSITION_SHARE>>,
) {
    let cap = vault.destroy(vault_admin_cap);
    destroy(composition);
    destroy(cap);
}

#[test]
fun installation_is_explicit_and_revocable() {
    let ctx = &mut tx_context::dummy();
    let (composition, mut vault, vault_admin_cap) = fixture(ctx);

    assert!(!plugin::is_installed(&vault));
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    assert!(plugin::is_installed(&vault));
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    assert!(!plugin::is_installed(&vault));

    destroy_fixture(composition, vault, vault_admin_cap);
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun pool_cannot_be_initialized_before_installation() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, mut vault, vault_admin_cap) = fixture(ctx);
    plugin::initialize_pool_for_testing<COMPOSITION_SHARE, CURRENCY>(
        &mut vault,
        &mut composition,
        &vault_admin_cap,
    );
    destroy_fixture(composition, vault, vault_admin_cap);
}

#[test]
fun pool_parent_is_composition_and_survives_vault_replacement() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut composition, mut vault, vault_admin_cap) = fixture(scenario.ctx());
    let composition_id = composition.id();
    let pool_address = plugin::pool_address<COMPOSITION_SHARE, CURRENCY>(&composition);

    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::initialize_pool_for_testing<COMPOSITION_SHARE, CURRENCY>(
        &mut vault,
        &mut composition,
        &vault_admin_cap,
    );

    scenario.next_tx(@0xA);
    let pool_id = object::id_from_address(pool_address);
    let pool: RoyaltyPool<COMPOSITION_SHARE, CURRENCY> = scenario.take_shared_by_id(pool_id);
    pool.assert_derived_from(composition_id);
    test_scenario::return_shared(pool);

    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    let cap = vault.destroy(vault_admin_cap);
    let (replacement_vault, replacement_admin_cap) = vault::new(cap, scenario.ctx());
    assert_eq!(
        plugin::pool_address<COMPOSITION_SHARE, CURRENCY>(&composition),
        pool_address,
    );
    destroy_fixture(composition, replacement_vault, replacement_admin_cap);
    scenario.end();
}

#[test]
fun composition_revenue_paths_are_forced_into_canonical_pool() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut composition, mut vault, vault_admin_cap) = fixture(scenario.ctx());
    let composition_id = composition.id();
    let pool_id = object::id_from_address(
        plugin::pool_address<COMPOSITION_SHARE, CURRENCY>(&composition),
    );

    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::initialize_pool_for_testing<COMPOSITION_SHARE, CURRENCY>(
        &mut vault,
        &mut composition,
        &vault_admin_cap,
    );

    scenario.next_tx(@0xA);
    let mut pool: RoyaltyPool<COMPOSITION_SHARE, CURRENCY> =
        scenario.take_shared_by_id(pool_id);
    let mut holder = stake::new(
        balance::create_for_testing<COMPOSITION_SHARE>(100),
        scenario.ctx(),
    );
    pool.register_stake(&mut holder);
    balance::create_for_testing<CURRENCY>(1_000).send_funds(composition_id.to_address());

    plugin::redeem_and_deposit_for_testing(
        &mut vault,
        &mut composition,
        &mut pool,
        1_000,
    );
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 1_000);

    let paid_coin = coin::from_balance(
        balance::create_for_testing<CURRENCY>(500),
        scenario.ctx(),
    );
    let paid_coin_id = object::id(&paid_coin);
    transfer::public_transfer(paid_coin, composition_id.to_address());

    scenario.next_tx(@0xA);
    let receiving = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(paid_coin_id);
    plugin::receive_and_deposit_for_testing(
        &mut vault,
        &mut composition,
        &mut pool,
        vector[receiving],
    );
    let received_reward = pool.claim_rewards(&mut holder);
    assert_eq!(received_reward.value(), 500);

    pool.unregister_stake(&mut holder);
    test_scenario::return_shared(pool);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    balance::destroy_for_testing(received_reward);
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    destroy_fixture(composition, vault, vault_admin_cap);
    scenario.end();
}

#[test, expected_failure]
fun foreign_vault_admin_cannot_initialize_pool() {
    let ctx = &mut tx_context::dummy();
    let (mut composition_a, mut vault_a, vault_admin_cap_a) = fixture(ctx);
    let (composition_b, vault_b, vault_admin_cap_b) = fixture(ctx);
    plugin::install_for_testing(&mut vault_a, &vault_admin_cap_a);

    plugin::initialize_pool_for_testing<COMPOSITION_SHARE, CURRENCY>(
        &mut vault_a,
        &mut composition_a,
        &vault_admin_cap_b,
    );

    plugin::uninstall_for_testing(&mut vault_a, &vault_admin_cap_a);
    destroy_fixture(composition_a, vault_a, vault_admin_cap_a);
    destroy_fixture(composition_b, vault_b, vault_admin_cap_b);
}

#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = pool)]
fun composition_revenue_cannot_enter_another_compositions_pool() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut composition_a, mut vault, vault_admin_cap) = fixture(scenario.ctx());
    let (mut composition_b, cap_b) = composition::new_for_testing<COMPOSITION_SHARE>(
        "Other Composition",
        1_000,
        scenario.ctx(),
    );
    let pool_id = object::id_from_address(
        plugin::pool_address<COMPOSITION_SHARE, CURRENCY>(&composition_a),
    );

    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::initialize_pool_for_testing<COMPOSITION_SHARE, CURRENCY>(
        &mut vault,
        &mut composition_a,
        &vault_admin_cap,
    );

    scenario.next_tx(@0xA);
    let mut pool: RoyaltyPool<COMPOSITION_SHARE, CURRENCY> =
        scenario.take_shared_by_id(pool_id);
    plugin::redeem_and_deposit_for_testing(
        &mut vault,
        &mut composition_b,
        &mut pool,
        1,
    );

    test_scenario::return_shared(pool);
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    destroy_fixture(composition_a, vault, vault_admin_cap);
    destroy(composition_b);
    destroy(cap_b);
    scenario.end();
}
