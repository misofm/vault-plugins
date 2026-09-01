// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_revenue_distributor_plugin::release_revenue_distributor_plugin_tests;

use miso::release::{Self, Release, ReleaseAdminCap};
use miso::test_helpers;
use miso::track;
use release_revenue_distributor::release_revenue_distributor as action;
use release_revenue_distributor_plugin::release_revenue_distributor_plugin as plugin;
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;
use vault::vault::{Self, Vault, VaultAdminCap};

const EUnauthorized: u64 = 0;
const EPluginAlreadyAuthorized: u64 = 1;
const EPluginNotAuthorized: u64 = 2;
const ENotVaultAdmin: u64 = 0;

const STRANGER: address = @0x51;

public struct CURRENCY() has drop;

fun new_vault(
    cap: ReleaseAdminCap,
    ctx: &mut TxContext,
): (Vault<ReleaseAdminCap>, VaultAdminCap<ReleaseAdminCap>) {
    let mut registry = vault::new_registry_for_testing(ctx);
    let (vault, vault_admin_cap) = vault::new(&mut registry, cap, ctx);
    destroy(registry);
    (vault, vault_admin_cap)
}

fun fixture(
    ctx: &mut TxContext,
): (
    Release,
    Vault<ReleaseAdminCap>,
    VaultAdminCap<ReleaseAdminCap>,
) {
    let composition_id = test_helpers::fake_id(ctx);
    let release_id = test_helpers::fake_id(ctx);
    let recording_a = test_helpers::fake_id(ctx);
    let recording_b = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(composition_id, recording_a, release_id, 6000),
        track::new_for_testing(composition_id, recording_b, release_id, 4000),
    ];
    let (release, cap) = release::new_for_testing("Album", tracks, ctx);
    let (vault, vault_admin_cap) = new_vault(cap, ctx);
    (release, vault, vault_admin_cap)
}

fun cleanup(
    release: Release,
    mut vault: Vault<ReleaseAdminCap>,
    vault_admin_cap: VaultAdminCap<ReleaseAdminCap>,
) {
    let cap = vault.withdraw_cap(&vault_admin_cap);
    destroy(vault_admin_cap);
    destroy(vault);
    destroy(cap);
    destroy(release)
}

#[test]
fun direct_action_and_capless_plugin_emit_identical_distributions() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut release, mut vault, vault_admin_cap) = fixture(scenario.ctx());
    let release_id = object::id(&release);
    let cap_id = vault.cap_id();

    let direct_coin = coin::from_balance(
        balance::create_for_testing<CURRENCY>(10_001),
        scenario.ctx(),
    );
    let direct_coin_id = object::id(&direct_coin);
    transfer::public_transfer(direct_coin, release_id.to_address());
    scenario.next_tx(@0xA);
    let direct_ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(direct_coin_id);
    let (cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    action::receive_and_distribute(&mut release, &cap, vector[direct_ticket]);
    vault.put_back(cap, receipt);
    let direct_summaries =
        event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(direct_summaries.length(), 1);
    let (direct_release, direct_input, direct_distributed, direct_remainder) =
        action::distribution_event_fields(&direct_summaries[0]);
    let direct_tracks =
        event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(direct_tracks.length(), 2);
    let (direct_track_release, direct_index, direct_recording, direct_amount) =
        action::track_event_fields(&direct_tracks[0]);

    plugin::install(&mut vault, &vault_admin_cap);
    assert!(plugin::is_installed(&vault));
    let plugin_coin = coin::from_balance(
        balance::create_for_testing<CURRENCY>(10_001),
        scenario.ctx(),
    );
    let plugin_coin_id = object::id(&plugin_coin);
    transfer::public_transfer(plugin_coin, release_id.to_address());
    scenario.next_tx(STRANGER);
    let plugin_ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(plugin_coin_id);
    plugin::receive_and_distribute_for_testing(
        &mut vault,
        &mut release,
        vector[plugin_ticket],
    );
    let root = scenario.take_shared<AccumulatorRoot>();
    plugin::redeem_all_and_distribute_for_testing<CURRENCY>(&mut vault, &mut release, &root);

    let summaries =
        event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    let (plugin_release, plugin_input, plugin_distributed, plugin_remainder) =
        action::distribution_event_fields(&summaries[0]);
    assert_eq!(direct_release, release_id);
    assert_eq!(plugin_release, release_id);
    assert_eq!(direct_input, plugin_input);
    assert_eq!(direct_distributed, plugin_distributed);
    assert_eq!(direct_remainder, plugin_remainder);
    assert_eq!(direct_input, 10_001);
    assert_eq!(direct_distributed, 10_000);
    assert_eq!(direct_remainder, 1);

    let tracks = event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(tracks.length(), 2);
    let (plugin_release, plugin_index, plugin_recording, plugin_amount) =
        action::track_event_fields(&tracks[0]);
    assert_eq!(direct_track_release, plugin_release);
    assert_eq!(direct_index, plugin_index);
    assert_eq!(direct_recording, plugin_recording);
    assert_eq!(direct_amount, plugin_amount);
    test_scenario::return_shared(root);

    let (cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    assert_eq!(object::id(&cap), cap_id);
    vault.put_back(cap, receipt);
    plugin::uninstall(&mut vault, &vault_admin_cap);
    assert!(!plugin::is_installed(&vault));
    cleanup(release, vault, vault_admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun operation_before_install_aborts() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut release, mut vault, _vault_admin_cap) = fixture(scenario.ctx());
    scenario.next_tx(STRANGER);
    let root = scenario.take_shared<AccumulatorRoot>();
    plugin::redeem_all_and_distribute_for_testing<CURRENCY>(&mut vault, &mut release, &root);
    abort
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun operation_after_uninstall_aborts() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut release, mut vault, vault_admin_cap) = fixture(scenario.ctx());
    plugin::install(&mut vault, &vault_admin_cap);
    plugin::uninstall(&mut vault, &vault_admin_cap);
    scenario.next_tx(STRANGER);
    let root = scenario.take_shared<AccumulatorRoot>();
    plugin::redeem_all_and_distribute_for_testing<CURRENCY>(&mut vault, &mut release, &root);
    abort
}

#[test, expected_failure(abort_code = EPluginAlreadyAuthorized, location = vault)]
fun double_install_aborts_with_stable_code() {
    let ctx = &mut tx_context::dummy();
    let (_release, mut vault, vault_admin_cap) = fixture(ctx);
    plugin::install(&mut vault, &vault_admin_cap);
    plugin::install(&mut vault, &vault_admin_cap);
    abort
}

#[test, expected_failure(abort_code = ENotVaultAdmin, location = vault)]
fun foreign_admin_cannot_install() {
    let ctx = &mut tx_context::dummy();
    let (_release_a, mut vault_a, _admin_a) = fixture(ctx);
    let (_release_b, _vault_b, admin_b) = fixture(ctx);
    plugin::install(&mut vault_a, &admin_b);
    abort
}

#[test, expected_failure(abort_code = ENotVaultAdmin, location = vault)]
fun foreign_admin_cannot_uninstall() {
    let ctx = &mut tx_context::dummy();
    let (_release_a, mut vault_a, admin_a) = fixture(ctx);
    let (_release_b, _vault_b, admin_b) = fixture(ctx);
    plugin::install(&mut vault_a, &admin_a);
    plugin::uninstall(&mut vault_a, &admin_b);
    abort
}

#[test, expected_failure(abort_code = EUnauthorized, location = release)]
fun wrong_release_target_aborts() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (_release_a, mut vault_a, admin_a) = fixture(scenario.ctx());
    let (mut release_b, _vault_b, _admin_b) = fixture(scenario.ctx());
    plugin::install(&mut vault_a, &admin_a);
    scenario.next_tx(STRANGER);
    let root = scenario.take_shared<AccumulatorRoot>();
    plugin::redeem_all_and_distribute_for_testing<CURRENCY>(
        &mut vault_a,
        &mut release_b,
        &root,
    );
    abort
}
