// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_revenue_distributor_plugin::e2e_pipeline_tests;

use composition_royalty_pool::composition_royalty_pool as composition_pool_action;
use composition_routed_stake::composition_routed_stake as routed_action;
use miso::composition;
use miso::recording;
use miso::release;
use miso::test_helpers;
use miso::track;
use recording_royalty_pool::recording_royalty_pool as recording_pool_action;
use release_revenue_distributor_plugin::release_revenue_distributor_plugin as release_plugin;
use royalty_pool::pool;
use royalty_pool::stake;
use routed_stake::routed_stake;
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::test_scenario;
use vault::vault::{Self, Vault, VaultAdminCap};

const STRANGER: address = @0x51;

public struct COMPOSITION_SHARE() has drop;
public struct RECORDING_SHARE() has drop;
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

#[test]
fun release_plugin_to_recording_action_to_routed_composition_pool() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut composition, composition_admin_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Composition", 2_000, scenario.ctx());
    let composition_id = object::id(&composition);
    let (mut recording, recording_admin_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(
            composition_id,
            scenario.ctx(),
        );
    let recording_id = object::id(&recording);

    let release_key = test_helpers::fake_id(scenario.ctx());
    let tracks = vector[
        track::new_for_testing(composition_id, recording_id, release_key, 10_000),
    ];
    let (mut release, release_admin_cap) =
        release::new_for_testing("Release", tracks, scenario.ctx());
    let release_id = object::id(&release);

    let (mut recording_vault, recording_vault_admin_cap) =
        new_vault(recording_admin_cap, scenario.ctx());
    let (mut release_vault, release_vault_admin_cap) =
        new_vault(release_admin_cap, scenario.ctx());

    let mut composition_pool =
        composition_pool_action::new_pool<COMPOSITION_SHARE, CURRENCY>(
            &mut composition,
            &composition_admin_cap,
        );
    let mut composition_holder =
        stake::new(balance::create_for_testing<COMPOSITION_SHARE>(100), scenario.ctx());
    composition_pool.register_stake(&mut composition_holder);

    let (recording_admin_cap, receipt) =
        recording_vault.borrow_as_admin(&recording_vault_admin_cap);
    let mut recording_pool =
        recording_pool_action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
            &mut recording,
            &recording_admin_cap,
        );
    recording_vault.put_back(recording_admin_cap, receipt);

    balance::create_for_testing<RECORDING_SHARE>(100)
        .send_funds(composition_id.to_address());
    let mut routed = routed_action::create_stake(
        &mut composition,
        &composition_admin_cap,
        &recording,
        100,
        scenario.ctx(),
    );
    routed_action::register(
        &mut composition,
        &composition_admin_cap,
        &recording,
        &mut routed,
        &mut recording_pool,
    );

    release_plugin::install(&mut release_vault, &release_vault_admin_cap);
    let revenue = coin::from_balance(
        balance::create_for_testing<CURRENCY>(10_000),
        scenario.ctx(),
    );
    let revenue_id = object::id(&revenue);
    transfer::public_transfer(revenue, release_id.to_address());

    scenario.next_tx(STRANGER);
    let ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(revenue_id);
    release_plugin::receive_and_distribute_for_testing(
        &mut release_vault,
        &mut release,
        vector[ticket],
    );
    let root = scenario.take_shared<AccumulatorRoot>();
    release_plugin::redeem_all_and_distribute_for_testing<CURRENCY>(
        &mut release_vault,
        &mut release,
        &root,
    );
    test_scenario::return_shared(root);
    let (recording_admin_cap, receipt) =
        recording_vault.borrow_as_admin(&recording_vault_admin_cap);
    recording_pool_action::redeem_and_deposit(
        &mut recording,
        &recording_admin_cap,
        &mut recording_pool,
        10_000,
    );
    recording_vault.put_back(recording_admin_cap, receipt);
    assert_eq!(recording_pool.cumulative_deposits(), 10_000);

    // Permissionless core sweep fixes the destination to Composition's pool.
    routed_stake::sweep(
        &mut routed,
        &mut recording_pool,
        &mut composition_pool,
        composition_id,
    );
    assert_eq!(composition_pool.cumulative_deposits(), 10_000);
    let composition_reward = composition_pool.claim_rewards(&mut composition_holder);
    assert_eq!(composition_reward.value(), 10_000);

    routed_action::unregister(
        &mut composition,
        &composition_admin_cap,
        &recording,
        &mut routed,
        &mut recording_pool,
    );
    let recording_principal = routed_action::unstake(
        &mut composition,
        &composition_admin_cap,
        &mut routed,
    );
    composition_pool.unregister_stake(&mut composition_holder);

    release_plugin::uninstall(&mut release_vault, &release_vault_admin_cap);
    let recording_admin_cap = recording_vault.withdraw_cap(&recording_vault_admin_cap);
    let release_admin_cap = release_vault.withdraw_cap(&release_vault_admin_cap);

    balance::destroy_for_testing(recording_principal);
    balance::destroy_for_testing(stake::destroy(composition_holder));
    balance::destroy_for_testing(composition_reward);
    destroy(routed);
    destroy(recording_pool);
    destroy(composition_pool);
    destroy(recording_vault_admin_cap);
    destroy(recording_vault);
    destroy(recording_admin_cap);
    destroy(release_vault_admin_cap);
    destroy(release_vault);
    destroy(release_admin_cap);
    destroy(release);
    destroy(recording);
    destroy(composition_admin_cap);
    destroy(composition);
    scenario.end();
}
