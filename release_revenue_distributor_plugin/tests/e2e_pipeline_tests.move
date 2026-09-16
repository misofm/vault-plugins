// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared-object lifecycle integration. Protocol constructors and balances
/// are fixtures; accumulator settlement remains a network E2E requirement.
#[test_only]
module release_revenue_distributor_plugin::e2e_pipeline_tests;

use composition_royalty_pool::composition_royalty_pool as composition_pool_action;
use composition_routed_stake::composition_routed_stake as routed_action;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::release::{Self, Release, ReleaseAdminCap};
use musicos::test_helpers;
use musicos::track;
use recording_royalty_pool::recording_royalty_pool as recording_pool_action;
use release_revenue_distributor::release_revenue_distributor as release_action;
use release_revenue_distributor_plugin::release_revenue_distributor_plugin as release_plugin;
use release_revenue_distributor_plugin::share::{Self as test_share, Share as SHARE};
use royalty_pool::pool::RoyaltyPool;
use royalty_pool::stake::{Self, Stake};
use routed_stake::routed_stake::{Self, RoutedStake};
use std::unit_test::assert_eq;
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario::{Self, Scenario};
use vault::vault::{Self, Vault, VaultAdminCap, VaultRegistry};

const ADMIN: address = @0xA;
const STRANGER: address = @0x51;
const HOLDER: address = @0xB;

public struct CURRENCY() has drop;

fun assert_no_admin_caps(scenario: &Scenario) {
    assert!(!scenario.has_most_recent_for_sender<CompositionAdminCap<SHARE>>());
    assert!(!scenario.has_most_recent_for_sender<RecordingAdminCap<SHARE>>());
    assert!(!scenario.has_most_recent_for_sender<ReleaseAdminCap>());
    assert!(!scenario.has_most_recent_for_sender<VaultAdminCap<RecordingAdminCap<SHARE>>>());
    assert!(!scenario.has_most_recent_for_sender<VaultAdminCap<ReleaseAdminCap>>());
}

#[test]
fun release_plugin_to_recording_action_to_routed_composition_pool() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    vault::init_for_testing(scenario.ctx());

    let (share_currency, share_supply) = test_share::bootstrap_currency(scenario.ctx());
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared<VaultRegistry>();
    let (mut composition, composition_admin_cap) =
        composition::new_for_testing<SHARE>("Composition", 2_000, scenario.ctx());
    let composition_id = object::id(&composition);
    let (mut recording, recording_admin_cap) =
        recording::new_for_testing<SHARE, SHARE>(composition_id, scenario.ctx());
    let recording_id = object::id(&recording);
    let recording_cap_id = object::id(&recording_admin_cap);
    let release_key = test_helpers::fake_id(scenario.ctx());
    let tracks = vector[
        track::new_for_testing(composition_id, recording_id, release_key, 10_000),
    ];
    let (release, release_admin_cap) = release::new_for_testing("Release", tracks, scenario.ctx());
    let release_id = object::id(&release);
    let release_cap_id = object::id(&release_admin_cap);

    let mut composition_pool = composition_pool_action::new_pool<SHARE, CURRENCY>(
        &mut composition, &composition_admin_cap, &share_currency,
    );
    let mut composition_holder =
        stake::new(balance::create_for_testing<SHARE>(100), scenario.ctx());
    composition_pool.register_stake(&mut composition_holder);
    let mut recording_pool = recording_pool_action::new_pool<SHARE, SHARE, CURRENCY>(
        &mut recording, &recording_admin_cap, &share_currency,
    );

    std::unit_test::destroy(share_currency);
    balance::destroy_for_testing(share_supply);

    // The VM permits accumulator redemption without consensus settlement.
    // This setup tests the routed lifecycle, not funding/overdraw enforcement.
    balance::create_for_testing<SHARE>(100).send_funds(composition_id.to_address());
    let mut routed = routed_action::create_stake(
        &mut composition, &composition_admin_cap, &recording, 100, scenario.ctx(),
    );
    routed_action::register(
        &mut composition, &composition_admin_cap, &recording, &mut routed, &mut recording_pool,
    );

    let clock = clock::create_for_testing(scenario.ctx());
    composition.publish(&composition_admin_cap, &clock);
    recording.publish(&recording_admin_cap, &clock);
    release.publish(&release_admin_cap, &clock);
    clock.destroy_for_testing();
    let composition_pool_id = object::id(&composition_pool);
    let recording_pool_id = object::id(&recording_pool);
    composition_pool.share();
    recording_pool.share();
    routed.share();
    transfer::public_transfer(composition_holder, HOLDER);
    transfer::public_transfer(composition_admin_cap, ADMIN);

    // Both vaults use the same production-initialized registry.
    let (recording_vault, recording_vault_admin_cap) =
        vault::new(&mut registry, recording_admin_cap, scenario.ctx());
    let (mut release_vault, release_vault_admin_cap) =
        vault::new(&mut registry, release_admin_cap, scenario.ctx());
    release_plugin::install(&mut release_vault, &release_vault_admin_cap);
    recording_vault.share();
    release_vault.share();
    transfer::public_transfer(recording_vault_admin_cap, ADMIN);
    transfer::public_transfer(release_vault_admin_cap, ADMIN);
    test_scenario::return_shared(registry);

    let revenue = coin::from_balance(balance::create_for_testing<CURRENCY>(10_000), scenario.ctx());
    let revenue_id = object::id(&revenue);
    transfer::public_transfer(revenue, release_id.to_address());

    // A stranger uses only shared inputs and the release's receiving ticket.
    scenario.next_tx(STRANGER);
    assert_no_admin_caps(&scenario);
    let mut release = scenario.take_shared<Release>();
    let mut release_vault = scenario.take_shared<Vault<ReleaseAdminCap>>();
    let ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(revenue_id);
    release_plugin::receive_and_distribute_for_testing(&mut release_vault, &mut release, vector[ticket]);
    let tracks = event::events_by_type<release_action::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(tracks.length(), 1);
    let (event_release, index, event_composition, event_recording, split, input, distributed_amount) =
        release_action::track_event_fields(&tracks[0]);
    assert_eq!(event_release, release_id.to_address());
    assert_eq!(index, 0);
    assert_eq!(event_composition, composition_id.to_address());
    assert_eq!(event_recording, recording_id.to_address());
    assert_eq!(split, 10_000);
    assert_eq!(input, 10_000);
    assert_eq!(distributed_amount, 10_000);
    let root = scenario.take_shared<AccumulatorRoot>();
    release_plugin::redeem_all_and_distribute_for_testing<CURRENCY>(&mut release_vault, &mut release, &root);
    test_scenario::return_shared(root);
    test_scenario::return_shared(release);
    test_scenario::return_shared(release_vault);

    // Raw-cap actions are administrative: retrieve the owned vault cap in a
    // separate ADMIN transaction. The supplied value bridges the VM's missing
    // settlement; it does not prove the preceding transfer settled on chain.
    scenario.next_tx(ADMIN);
    let mut recording = scenario.take_shared<Recording<SHARE, SHARE>>();
    let mut recording_vault = scenario.take_shared<Vault<RecordingAdminCap<SHARE>>>();
    let recording_vault_admin_cap = scenario.take_from_sender<VaultAdminCap<RecordingAdminCap<SHARE>>>();
    let mut recording_pool = scenario.take_shared_by_id<RoyaltyPool<SHARE, CURRENCY>>(recording_pool_id);
    let (recording_admin_cap, receipt) = recording_vault.borrow_as_admin(&recording_vault_admin_cap);
    assert_eq!(object::id(&recording_admin_cap), recording_cap_id);
    recording_pool_action::redeem_settled_value_and_deposit_for_testing(
        &mut recording, &recording_admin_cap, &mut recording_pool, distributed_amount,
    );
    recording_vault.put_back(recording_admin_cap, receipt);
    assert_eq!(recording_pool.cumulative_deposits(), 10_000);
    scenario.return_to_sender(recording_vault_admin_cap);
    test_scenario::return_shared(recording);
    test_scenario::return_shared(recording_vault);
    test_scenario::return_shared(recording_pool);

    scenario.next_tx(STRANGER);
    assert_no_admin_caps(&scenario);
    let mut routed = scenario.take_shared<RoutedStake<SHARE, SHARE>>();
    let mut recording_pool = scenario.take_shared_by_id<RoyaltyPool<SHARE, CURRENCY>>(recording_pool_id);
    let mut composition_pool = scenario.take_shared_by_id<RoyaltyPool<SHARE, CURRENCY>>(composition_pool_id);
    assert_eq!(routed_stake::sweep(&mut routed, &mut recording_pool, &mut composition_pool, composition_id), 10_000);
    assert_eq!(composition_pool.cumulative_deposits(), 10_000);
    assert_eq!(recording_pool.balance().value(), 0);
    test_scenario::return_shared(routed);
    test_scenario::return_shared(recording_pool);
    test_scenario::return_shared(composition_pool);

    // Only the stake owner can claim the holder's reward and principal.
    scenario.next_tx(HOLDER);
    assert_no_admin_caps(&scenario);
    let mut composition_pool = scenario.take_shared_by_id<RoyaltyPool<SHARE, CURRENCY>>(composition_pool_id);
    let mut composition_holder = scenario.take_from_sender<Stake<SHARE>>();
    let composition_reward = composition_pool.claim_rewards(&mut composition_holder);
    assert_eq!(composition_reward.value(), 10_000);
    composition_pool.unregister_stake(&mut composition_holder);
    let holder_principal = stake::destroy(composition_holder);
    assert_eq!(holder_principal.value(), 100);
    transfer::public_transfer(coin::from_balance(composition_reward, scenario.ctx()), HOLDER);
    transfer::public_transfer(coin::from_balance(holder_principal, scenario.ctx()), HOLDER);
    test_scenario::return_shared(composition_pool);

    scenario.next_tx(ADMIN);
    let mut composition = scenario.take_shared<Composition<SHARE>>();
    let composition_admin_cap = scenario.take_from_sender<CompositionAdminCap<SHARE>>();
    let recording = scenario.take_shared<Recording<SHARE, SHARE>>();
    let mut routed = scenario.take_shared<RoutedStake<SHARE, SHARE>>();
    let mut recording_pool = scenario.take_shared_by_id<RoyaltyPool<SHARE, CURRENCY>>(recording_pool_id);
    routed_action::unregister(
        &mut composition, &composition_admin_cap, &recording, &mut routed, &mut recording_pool,
    );
    let recording_principal = routed_action::unstake(&mut composition, &composition_admin_cap, &mut routed);
    assert_eq!(recording_principal.value(), 100);
    assert!(!routed.has_stake());
    transfer::public_transfer(coin::from_balance(recording_principal, scenario.ctx()), ADMIN);
    scenario.return_to_sender(composition_admin_cap);
    test_scenario::return_shared(composition);
    test_scenario::return_shared(recording);
    test_scenario::return_shared(routed);
    test_scenario::return_shared(recording_pool);

    let mut release_vault = scenario.take_shared<Vault<ReleaseAdminCap>>();
    let release_vault_admin_cap = scenario.take_from_sender<VaultAdminCap<ReleaseAdminCap>>();
    let mut recording_vault = scenario.take_shared<Vault<RecordingAdminCap<SHARE>>>();
    let recording_vault_admin_cap = scenario.take_from_sender<VaultAdminCap<RecordingAdminCap<SHARE>>>();
    release_plugin::uninstall(&mut release_vault, &release_vault_admin_cap);
    let recording_admin_cap = recording_vault.withdraw_vaulted_cap(&recording_vault_admin_cap);
    let release_admin_cap = release_vault.withdraw_vaulted_cap(&release_vault_admin_cap);
    assert_eq!(object::id(&recording_admin_cap), recording_cap_id);
    assert_eq!(object::id(&release_admin_cap), release_cap_id);
    assert!(!recording_vault.is_active());
    assert!(!release_vault.is_active());
    transfer::public_transfer(recording_admin_cap, ADMIN);
    transfer::public_transfer(release_admin_cap, ADMIN);
    scenario.return_to_sender(recording_vault_admin_cap);
    scenario.return_to_sender(release_vault_admin_cap);
    test_scenario::return_shared(recording_vault);
    test_scenario::return_shared(release_vault);

    scenario.next_tx(HOLDER);
    let reward = scenario.take_from_sender<Coin<CURRENCY>>();
    assert_eq!(reward.value(), 10_000);
    scenario.return_to_sender(reward);
    scenario.end();
}
