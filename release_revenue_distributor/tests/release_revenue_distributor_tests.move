// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module release_revenue_distributor::release_revenue_distributor_tests;

use hikida::hikida;
use miso::recording::{Self, Recording, RecordingAdminCap};
use miso::release::{Self, Release, ReleaseAdminCap};
use miso::test_helpers;
use miso::track;
use release_revenue_distributor::release_revenue_distributor as plugin;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;
use vault::vault::{Self, Vault, VaultAdminCap};

const EUnauthorized: u64 = 0;
const EPluginAlreadyAuthorized: u64 = 1;
const EPluginNotAuthorized: u64 = 2;

public struct RECORDING_SHARE_A() has drop;
public struct RECORDING_SHARE_B() has drop;
public struct RECORDING_SHARE_C() has drop;
public struct RECORDING_SHARE_D() has drop;
public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

/// The fixture is generic over the recording share types so tests needing two
/// releases never duplicate a share type across recordings — a state that
/// cannot exist on-chain (one object per share type, enforced by the currency
/// issuance gates). All recordings belong to the same composition.
fun fixture<RA, RB>(
    composition_id: ID,
    ctx: &mut TxContext,
): (
    Release,
    Vault<ReleaseAdminCap>,
    VaultAdminCap<ReleaseAdminCap>,
    Recording<RA, COMPOSITION_SHARE>,
    RecordingAdminCap<RA>,
    Recording<RB, COMPOSITION_SHARE>,
    RecordingAdminCap<RB>,
) {
    let (recording_a, recording_admin_cap_a) =
        recording::new_for_testing<RA, COMPOSITION_SHARE>(composition_id, ctx);
    let (recording_b, recording_admin_cap_b) =
        recording::new_for_testing<RB, COMPOSITION_SHARE>(composition_id, ctx);
    let release_id = test_helpers::fake_id(ctx);
    let tracks = vector[
        track::new_for_testing(composition_id, recording_a.id(), release_id, 6000),
        track::new_for_testing(composition_id, recording_b.id(), release_id, 4000),
    ];
    let (release, release_admin_cap) = release::new_for_testing("Album", tracks, ctx);
    let (vault, vault_admin_cap) = vault::new(release_admin_cap, ctx);
    (
        release,
        vault,
        vault_admin_cap,
        recording_a,
        recording_admin_cap_a,
        recording_b,
        recording_admin_cap_b,
    )
}

fun destroy_fixture<RA, RB>(
    release: Release,
    vault: Vault<ReleaseAdminCap>,
    vault_admin_cap: VaultAdminCap<ReleaseAdminCap>,
    recording_a: Recording<RA, COMPOSITION_SHARE>,
    recording_admin_cap_a: RecordingAdminCap<RA>,
    recording_b: Recording<RB, COMPOSITION_SHARE>,
    recording_admin_cap_b: RecordingAdminCap<RB>,
) {
    let release_admin_cap = vault.destroy(vault_admin_cap);
    destroy(release);
    destroy(release_admin_cap);
    destroy(recording_a);
    destroy(recording_admin_cap_a);
    destroy(recording_b);
    destroy(recording_admin_cap_b);
}

#[test]
fun installation_is_explicit_and_revocable() {
    let ctx = &mut tx_context::dummy();
    let (release, mut vault, vault_admin_cap, recording_a, cap_a, recording_b, cap_b) =
        fixture<RECORDING_SHARE_A, RECORDING_SHARE_B>(test_helpers::fake_id(ctx), ctx);

    assert!(!plugin::is_installed(&vault));
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    assert!(plugin::is_installed(&vault));
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    assert!(!plugin::is_installed(&vault));

    destroy_fixture(
        release,
        vault,
        vault_admin_cap,
        recording_a,
        cap_a,
        recording_b,
        cap_b,
    );
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun revenue_cannot_be_redeemed_before_installation() {
    let ctx = &mut tx_context::dummy();
    let (mut release, mut vault, _vault_admin_cap, _recording_a, _cap_a, _recording_b, _cap_b) =
        fixture<RECORDING_SHARE_A, RECORDING_SHARE_B>(test_helpers::fake_id(ctx), ctx);

    plugin::redeem_and_distribute_for_testing<CURRENCY>(&mut vault, &mut release, 1);
    abort
}

#[test]
fun redeemed_revenue_is_forced_to_track_recordings() {
    let ctx = &mut tx_context::dummy();
    let (
        mut release,
        mut vault,
        vault_admin_cap,
        mut recording_a,
        cap_a,
        mut recording_b,
        cap_b,
    ) = fixture<RECORDING_SHARE_A, RECORDING_SHARE_B>(test_helpers::fake_id(ctx), ctx);
    let release_id = release.id();
    let recording_a_id = recording_a.id();
    let recording_b_id = recording_b.id();

    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    balance::create_for_testing<CURRENCY>(10_001).send_funds(release_id.to_address());
    plugin::redeem_and_distribute_for_testing<CURRENCY>(&mut vault, &mut release, 10_001);

    let recording_a_revenue =
        hikida::redeem_balance<CURRENCY>(recording_a.uid_mut(&cap_a), 6_000);
    let recording_b_revenue =
        hikida::redeem_balance<CURRENCY>(recording_b.uid_mut(&cap_b), 4_000);
    assert_eq!(recording_a_revenue.value(), 6_000);
    assert_eq!(recording_b_revenue.value(), 4_000);

    let (release_admin_cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    let remainder = hikida::redeem_balance<CURRENCY>(release.uid_mut(&release_admin_cap), 1);
    vault.put_back(release_admin_cap, receipt);
    assert_eq!(remainder.value(), 1);

    let track_events =
        event::events_by_type<plugin::ReleaseTrackRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(track_events.length(), 2);
    let (event_release_id, index_a, event_recording_a, amount_a) =
        plugin::track_event_fields(&track_events[0]);
    let (_, index_b, event_recording_b, amount_b) =
        plugin::track_event_fields(&track_events[1]);
    assert_eq!(event_release_id, release_id);
    assert_eq!(index_a, 0);
    assert_eq!(event_recording_a, recording_a_id);
    assert_eq!(amount_a, 6_000);
    assert_eq!(index_b, 1);
    assert_eq!(event_recording_b, recording_b_id);
    assert_eq!(amount_b, 4_000);

    let distribution_events =
        event::events_by_type<plugin::ReleaseRevenueDistributedEvent<CURRENCY>>();
    assert_eq!(distribution_events.length(), 1);
    let (summary_release_id, total_input, total_distributed, summary_remainder) =
        plugin::distribution_event_fields(&distribution_events[0]);
    assert_eq!(summary_release_id, release_id);
    assert_eq!(total_input, 10_001);
    assert_eq!(total_distributed, 10_000);
    assert_eq!(summary_remainder, 1);

    balance::destroy_for_testing(recording_a_revenue);
    balance::destroy_for_testing(recording_b_revenue);
    balance::destroy_for_testing(remainder);
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    destroy_fixture(release, vault, vault_admin_cap, recording_a, cap_a, recording_b, cap_b);
}

#[test]
fun received_coins_are_combined_and_distributed() {
    let mut scenario = test_scenario::begin(@0xA);
    let (
        mut release,
        mut vault,
        vault_admin_cap,
        mut recording_a,
        cap_a,
        mut recording_b,
        cap_b,
    ) = fixture<RECORDING_SHARE_A, RECORDING_SHARE_B>(
        test_helpers::fake_id(scenario.ctx()),
        scenario.ctx(),
    );
    plugin::install_for_testing(&mut vault, &vault_admin_cap);

    let coin_a = coin::from_balance(balance::create_for_testing<CURRENCY>(6_000), scenario.ctx());
    let coin_b = coin::from_balance(balance::create_for_testing<CURRENCY>(4_000), scenario.ctx());
    let coin_a_id = object::id(&coin_a);
    let coin_b_id = object::id(&coin_b);
    transfer::public_transfer(coin_a, release.id().to_address());
    transfer::public_transfer(coin_b, release.id().to_address());

    scenario.next_tx(@0xB);
    let receiving_a = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(coin_a_id);
    let receiving_b = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(coin_b_id);
    plugin::receive_and_distribute_for_testing(
        &mut vault,
        &mut release,
        vector[receiving_a, receiving_b],
    );

    let recording_a_revenue =
        hikida::redeem_balance<CURRENCY>(recording_a.uid_mut(&cap_a), 6_000);
    let recording_b_revenue =
        hikida::redeem_balance<CURRENCY>(recording_b.uid_mut(&cap_b), 4_000);
    assert_eq!(recording_a_revenue.value(), 6_000);
    assert_eq!(recording_b_revenue.value(), 4_000);

    balance::destroy_for_testing(recording_a_revenue);
    balance::destroy_for_testing(recording_b_revenue);
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    destroy_fixture(release, vault, vault_admin_cap, recording_a, cap_a, recording_b, cap_b);
    scenario.end();
}

#[test, expected_failure(abort_code = EUnauthorized, location = release)]
fun release_cannot_use_another_releases_vault() {
    let ctx = &mut tx_context::dummy();
    // One composition, four distinct recordings — a production-legal state.
    let composition_id = test_helpers::fake_id(ctx);
    let (
        _release_a,
        mut vault_a,
        vault_admin_cap_a,
        _recording_a,
        _cap_a,
        _recording_b,
        _cap_b,
    ) = fixture<RECORDING_SHARE_A, RECORDING_SHARE_B>(composition_id, ctx);
    let (
        mut release_b,
        _vault_b,
        _vault_admin_cap_b,
        _recording_c,
        _cap_c,
        _recording_d,
        _cap_d,
    ) = fixture<RECORDING_SHARE_C, RECORDING_SHARE_D>(composition_id, ctx);
    plugin::install_for_testing(&mut vault_a, &vault_admin_cap_a);
    balance::create_for_testing<CURRENCY>(1).send_funds(release_b.id().to_address());

    plugin::redeem_and_distribute_for_testing<CURRENCY>(&mut vault_a, &mut release_b, 1);
    abort
}

#[test, expected_failure(abort_code = EPluginAlreadyAuthorized, location = vault)]
fun installation_is_not_idempotent() {
    let ctx = &mut tx_context::dummy();
    let (_release, mut vault, vault_admin_cap, _recording_a, _cap_a, _recording_b, _cap_b) =
        fixture<RECORDING_SHARE_A, RECORDING_SHARE_B>(test_helpers::fake_id(ctx), ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    abort
}
