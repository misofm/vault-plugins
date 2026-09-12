// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_revenue_distributor_plugin::release_revenue_distributor_plugin_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use release_revenue_distributor::release_revenue_distributor as action;
use release_revenue_distributor_plugin::release_revenue_distributor_plugin as plugin;
use release_revenue_distributor_plugin::witness::Witness;
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
public struct OTHER_CURRENCY() has drop;
public struct OTHER_WITNESS() has drop;

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

fun assert_installed_event(
    vault: &Vault<ReleaseAdminCap>,
    vault_admin_cap: &VaultAdminCap<ReleaseAdminCap>,
    cap_id: sui::object::ID,
) {
    let events = event::events_by_type<
        plugin::ReleaseRevenueDistributorPluginInstalledEvent<ReleaseAdminCap, Witness>
    >();
    assert_eq!(events.length(), 1);
    let (
        event_vault_id,
        event_vault_admin_cap_id,
        event_release_admin_cap_id,
        vault_active,
        authorized_before,
        authorized_after,
        count_before,
        count_after,
    ) = plugin::installed_event_fields(&events[0]);
    assert_eq!(event_vault_id, object::id(vault).to_address());
    assert_eq!(event_vault_admin_cap_id, object::id(vault_admin_cap).to_address());
    assert_eq!(event_release_admin_cap_id, cap_id.to_address());
    assert!(vault_active);
    assert!(!authorized_before);
    assert!(authorized_after);
    assert_eq!(count_before, 0);
    assert_eq!(count_after, 1);
}

fun assert_uninstalled_event(
    vault: &Vault<ReleaseAdminCap>,
    vault_admin_cap: &VaultAdminCap<ReleaseAdminCap>,
    cap_id: sui::object::ID,
) {
    let events = event::events_by_type<
        plugin::ReleaseRevenueDistributorPluginUninstalledEvent<ReleaseAdminCap, Witness>
    >();
    assert_eq!(events.length(), 1);
    let (
        event_vault_id,
        event_vault_admin_cap_id,
        event_release_admin_cap_id,
        vault_active,
        authorized_before,
        authorized_after,
        count_before,
        count_after,
    ) = plugin::uninstalled_event_fields(&events[0]);
    assert_eq!(event_vault_id, object::id(vault).to_address());
    assert_eq!(event_vault_admin_cap_id, object::id(vault_admin_cap).to_address());
    assert_eq!(event_release_admin_cap_id, cap_id.to_address());
    assert!(vault_active);
    assert!(authorized_before);
    assert!(!authorized_after);
    assert_eq!(count_before, 1);
    assert_eq!(count_after, 0);
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
    let (direct_release, _, direct_input, direct_distributed, direct_remainder) = action::distribution_event_fields(&direct_summaries[0]);
    let direct_tracks =
        event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(direct_tracks.length(), 2);
    let (direct_track_release, direct_index, _, direct_recording, _, _, direct_amount) = action::track_event_fields(&direct_tracks[0]);

    plugin::install(&mut vault, &vault_admin_cap);
    assert!(plugin::is_installed(&vault));
    assert_installed_event(&vault, &vault_admin_cap, cap_id);
    assert_eq!(
        event::events_by_type<vault::PluginAuthorizedEvent<ReleaseAdminCap, Witness>>().length(),
        1,
    );
    let plugin_coin = coin::from_balance(
        balance::create_for_testing<CURRENCY>(6_000),
        scenario.ctx(),
    );
    let plugin_coin_2 = coin::from_balance(
        balance::create_for_testing<CURRENCY>(4_001),
        scenario.ctx(),
    );
    let plugin_coin_id = object::id(&plugin_coin);
    let plugin_coin_2_id = object::id(&plugin_coin_2);
    transfer::public_transfer(plugin_coin, release_id.to_address());
    transfer::public_transfer(plugin_coin_2, release_id.to_address());
    scenario.next_tx(STRANGER);
    let plugin_ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(plugin_coin_id);
    let plugin_ticket_2 =
        test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(plugin_coin_2_id);
    plugin::receive_and_distribute_for_testing(
        &mut vault,
        &mut release,
        vector[plugin_ticket, plugin_ticket_2],
    );
    let coin_events = event::events_by_type<
        plugin::ReleaseRevenueCoinsDistributedEvent<CURRENCY, ReleaseAdminCap, Witness>
    >();
    assert_eq!(coin_events.length(), 1);
    let (
        event_vault_id,
        event_cap_id,
        event_release_id,
        input_coin_count,
        input_coin_ids,
    ) = plugin::coins_distributed_event_fields(&coin_events[0]);
    assert_eq!(event_vault_id, object::id(&vault).to_address());
    assert_eq!(event_cap_id, cap_id.to_address());
    assert_eq!(event_release_id, release_id.to_address());
    assert_eq!(input_coin_count, 2);
    assert_eq!(
        input_coin_ids,
        vector[plugin_coin_id.to_address(), plugin_coin_2_id.to_address()],
    );
    assert_eq!(
        event::events_by_type<
            plugin::ReleaseRevenueCoinsDistributedEvent<OTHER_CURRENCY, ReleaseAdminCap, Witness>
        >()
        .length(),
        0,
    );
    assert_eq!(
        event::events_by_type<
            plugin::ReleaseRevenueCoinsDistributedEvent<CURRENCY, ReleaseAdminCap, OTHER_WITNESS>
        >()
        .length(),
        0,
    );
    let root = scenario.take_shared<AccumulatorRoot>();
    plugin::redeem_all_and_distribute_for_testing<CURRENCY>(&mut vault, &mut release, &root);
    assert_eq!(
        event::events_by_type<
            plugin::ReleaseRevenueFundsDistributedEvent<CURRENCY, ReleaseAdminCap, Witness>
        >()
        .length(),
        0,
    );

    let summaries =
        event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    let (plugin_release, _, plugin_input, plugin_distributed, plugin_remainder) = action::distribution_event_fields(&summaries[0]);
    assert_eq!(direct_release, release_id.to_address());
    assert_eq!(plugin_release, release_id.to_address());
    assert_eq!(direct_input, plugin_input);
    assert_eq!(direct_distributed, plugin_distributed);
    assert_eq!(direct_remainder, plugin_remainder);
    assert_eq!(direct_input, 10_001);
    assert_eq!(direct_distributed, 10_000);
    assert_eq!(direct_remainder, 1);

    let tracks = event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(tracks.length(), 2);
    let (plugin_release, plugin_index, _, plugin_recording, _, _, plugin_amount) = action::track_event_fields(&tracks[0]);
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
    assert_uninstalled_event(&vault, &vault_admin_cap, cap_id);
    assert_eq!(
        event::events_by_type<vault::PluginRevokedEvent<ReleaseAdminCap, Witness>>().length(),
        1,
    );
    cleanup(release, vault, vault_admin_cap);
    scenario.end();
}

#[test]
fun install_uninstall_reinstall_events_capture_each_transition() {
    let ctx = &mut tx_context::dummy();
    let (release, mut vault, vault_admin_cap) = fixture(ctx);
    let cap_id = vault.cap_id();

    plugin::install(&mut vault, &vault_admin_cap);
    assert_installed_event(&vault, &vault_admin_cap, cap_id);
    let events_before_view = event::num_events();
    assert!(plugin::is_installed(&vault));
    assert_eq!(event::num_events(), events_before_view);

    plugin::uninstall(&mut vault, &vault_admin_cap);
    assert_uninstalled_event(&vault, &vault_admin_cap, cap_id);
    plugin::install(&mut vault, &vault_admin_cap);
    let installed_events = event::events_by_type<
        plugin::ReleaseRevenueDistributorPluginInstalledEvent<ReleaseAdminCap, Witness>
    >();
    assert_eq!(installed_events.length(), 2);
    let (_, _, event_cap_id, active, authorized_before, authorized_after, count_before, count_after) =
        plugin::installed_event_fields(&installed_events[1]);
    assert_eq!(event_cap_id, cap_id.to_address());
    assert!(active);
    assert!(!authorized_before);
    assert!(authorized_after);
    assert_eq!(count_before, 0);
    assert_eq!(count_after, 1);
    assert_eq!(
        event::events_by_type<vault::PluginAuthorizedEvent<ReleaseAdminCap, Witness>>().length(),
        2,
    );
    assert_eq!(
        event::events_by_type<vault::PluginRevokedEvent<ReleaseAdminCap, Witness>>().length(),
        1,
    );

    plugin::uninstall(&mut vault, &vault_admin_cap);
    cleanup(release, vault, vault_admin_cap);
}

#[test]
fun nonempty_zero_coin_keeps_plugin_and_action_events() {
    let mut scenario = test_scenario::begin(@0x0);
    let (mut release, mut vault, vault_admin_cap) = fixture(scenario.ctx());
    let release_id = object::id(&release);
    let cap_id = vault.cap_id();
    plugin::install(&mut vault, &vault_admin_cap);
    let zero_coin = coin::zero<CURRENCY>(scenario.ctx());
    let zero_coin_id = object::id(&zero_coin);
    transfer::public_transfer(zero_coin, release_id.to_address());

    scenario.next_tx(STRANGER);
    let ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(zero_coin_id);
    plugin::receive_and_distribute_for_testing(
        &mut vault,
        &mut release,
        vector[ticket],
    );
    let coin_events = event::events_by_type<
        plugin::ReleaseRevenueCoinsDistributedEvent<CURRENCY, ReleaseAdminCap, Witness>
    >();
    assert_eq!(coin_events.length(), 1);
    let (_, event_cap_id, event_release_id, count, ids) =
        plugin::coins_distributed_event_fields(&coin_events[0]);
    assert_eq!(event_cap_id, cap_id.to_address());
    assert_eq!(event_release_id, release_id.to_address());
    assert_eq!(count, 1);
    assert_eq!(ids, vector[zero_coin_id.to_address()]);
    let tracks = event::events_by_type<action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(tracks.length(), 2);
    let (_, _, _, _, _, _, amount_a) = action::track_event_fields(&tracks[0]);
    let (_, _, _, _, _, _, amount_b) = action::track_event_fields(&tracks[1]);
    assert_eq!(amount_a, 0);
    assert_eq!(amount_b, 0);
    let summaries = event::events_by_type<action::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(summaries.length(), 1);
    let (_, _, input, distributed, remainder) = action::distribution_event_fields(&summaries[0]);
    assert_eq!(input, 0);
    assert_eq!(distributed, 0);
    assert_eq!(remainder, 0);
    assert_eq!(
        event::events_by_type<
            plugin::ReleaseRevenueFundsDistributedEvent<CURRENCY, ReleaseAdminCap, Witness>
        >()
        .length(),
        0,
    );
    plugin::uninstall(&mut vault, &vault_admin_cap);
    cleanup(release, vault, vault_admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = 0)]
fun empty_coin_vector_preserves_hikida_abort() {
    let mut scenario = test_scenario::begin(@0x0);
    let (mut release, mut vault, vault_admin_cap) = fixture(scenario.ctx());
    plugin::install(&mut vault, &vault_admin_cap);
    scenario.next_tx(STRANGER);
    plugin::receive_and_distribute_for_testing<CURRENCY>(&mut vault, &mut release, vector[]);
    plugin::uninstall(&mut vault, &vault_admin_cap);
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
