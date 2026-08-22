// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_routed_stake::composition_routed_stake_tests;

use composition_routed_stake::composition_routed_stake as plugin;
use hikida::hikida;
use miso::composition::{Self, Composition, CompositionAdminCap};
use miso::recording::{Self, Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use routed_stake::routed_stake::{Self, RoutedStake};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock::Clock;
use sui::test_scenario;
use vault::vault::{Self, Vault, VaultAdminCap};

const EPoolNotForRecording: u64 = 0;
const ENotVaultAdmin: u64 = 1;
const EPluginAlreadyAuthorized: u64 = 1;
const EPluginNotAuthorized: u64 = 2;
const EStakeNotForComposition: u64 = 2;
const ERecordingNotForComposition: u64 = 3;
// routed_stake error codes.
const ENoStake: u64 = 1;
const EStakeExists: u64 = 2;

public struct RECORDING_SHARE() has drop;
/// Placeholder share type for a foreign parent object used to derive a
/// same-typed but wrongly-parented pool.
public struct FOREIGN_RECORDING_SHARE() has drop;
public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

const ADMIN: address = @0xAD;
const PAYER: address = @0xFA;
const STRANGER: address = @0x51;

/// Full production-shaped lifecycle. Composition, Recording, Vault, pools,
/// and RoutedStake are genuinely shared; admin capabilities and holder stake
/// cross transaction boundaries as owned objects; sweeping is performed by a
/// sender holding no capability.
#[test]
fun complete_shared_lifecycle_routes_rewards_and_preserves_principal() {
    let mut scenario = test_scenario::begin(ADMIN);
    scenario.create_system_objects();

    // --- Tx 1 (ADMIN): publish the protocol objects and share both pools. ---
    let clock = scenario.take_shared<Clock>();
    let (mut composition, composition_admin_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Song", 2_000, scenario.ctx());
    let composition_id = composition.id();
    let (mut recording, recording_admin_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(
            composition_id,
            scenario.ctx(),
        );

    let recording_pool =
        pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_admin_cap));
    let mut composition_pool =
        pool::new<COMPOSITION_SHARE, CURRENCY>(composition.uid_mut(&composition_admin_cap));
    let mut composition_holder = stake::new(
        balance::create_for_testing<COMPOSITION_SHARE>(1_000),
        scenario.ctx(),
    );
    composition_pool.register_stake(&mut composition_holder);

    recording_pool.share();
    composition_pool.share();
    composition::publish(composition, &composition_admin_cap, &clock);
    recording::publish(recording, &recording_admin_cap, &clock);
    test_scenario::return_shared(clock);
    transfer::public_transfer(composition_admin_cap, ADMIN);
    transfer::public_transfer(recording_admin_cap, ADMIN);
    transfer::public_transfer(composition_holder, ADMIN);

    // --- Tx 2 (ADMIN): vault the cap, install the plugin, and create/share
    // the Composition-derived RoutedStake from Composition-owned shares. ---
    scenario.next_tx(ADMIN);
    let mut composition = scenario.take_shared<Composition<COMPOSITION_SHARE>>();
    let recording = scenario.take_shared<Recording<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let composition_admin_cap =
        scenario.take_from_sender<CompositionAdminCap<COMPOSITION_SHARE>>();
    let recording_admin_cap =
        scenario.take_from_sender<RecordingAdminCap<RECORDING_SHARE>>();
    let composition_holder = scenario.take_from_sender<Stake<COMPOSITION_SHARE>>();
    let (mut vault, vault_admin_cap) = vault::new(composition_admin_cap, scenario.ctx());
    assert!(!plugin::is_installed(&vault));
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    assert!(plugin::is_installed(&vault));

    balance::create_for_testing<RECORDING_SHARE>(200).send_funds(composition_id.to_address());
    let routed_address =
        plugin::stake_address<RECORDING_SHARE, COMPOSITION_SHARE>(&composition);
    plugin::create_stake_for_testing(
        &mut vault,
        &mut composition,
        &recording,
        &vault_admin_cap,
        200,
        scenario.ctx(),
    );

    vault.share();
    test_scenario::return_shared(composition);
    test_scenario::return_shared(recording);
    transfer::public_transfer(vault_admin_cap, ADMIN);
    scenario.return_to_sender(recording_admin_cap);
    scenario.return_to_sender(composition_holder);

    // --- Tx 3 (ADMIN): register the shared wrapper with the canonical
    // Recording pool. ---
    scenario.next_tx(ADMIN);
    let mut vault = scenario.take_shared<Vault<CompositionAdminCap<COMPOSITION_SHARE>>>();
    let mut composition = scenario.take_shared<Composition<COMPOSITION_SHARE>>();
    let recording = scenario.take_shared<Recording<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let mut routed = scenario.take_shared<RoutedStake<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let mut recording_pool = scenario.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    let vault_admin_cap =
        scenario.take_from_sender<VaultAdminCap<CompositionAdminCap<COMPOSITION_SHARE>>>();
    assert_eq!(routed.id().to_address(), routed_address);
    assert_eq!(routed.value(), 200);
    plugin::register_for_testing(
        &mut vault,
        &mut composition,
        &recording,
        &mut routed,
        &mut recording_pool,
        &vault_admin_cap,
    );
    test_scenario::return_shared(vault);
    test_scenario::return_shared(composition);
    test_scenario::return_shared(recording);
    test_scenario::return_shared(routed);
    test_scenario::return_shared(recording_pool);
    scenario.return_to_sender(vault_admin_cap);

    // --- Tx 4 (PAYER): fund the Recording pool. ---
    scenario.next_tx(PAYER);
    let mut recording_pool = scenario.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    recording_pool.deposit(balance::create_for_testing<CURRENCY>(1_000));
    test_scenario::return_shared(recording_pool);

    // --- Tx 5 (STRANGER): sweep without any capability. The generic
    // RoutedStake fixes the destination to the Composition pool. ---
    scenario.next_tx(STRANGER);
    let mut routed = scenario.take_shared<RoutedStake<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let mut recording_pool = scenario.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    let mut composition_pool = scenario.take_shared<RoyaltyPool<COMPOSITION_SHARE, CURRENCY>>();
    routed.sweep(&mut recording_pool, &mut composition_pool, composition_id);
    assert_eq!(composition_pool.balance().value(), 1_000);
    test_scenario::return_shared(routed);
    test_scenario::return_shared(recording_pool);
    test_scenario::return_shared(composition_pool);

    // --- Tx 6 (ADMIN): claim the routed reward, unregister, and unstake.
    // Principal is returned to the Composition address, never the caller. ---
    scenario.next_tx(ADMIN);
    let mut vault = scenario.take_shared<Vault<CompositionAdminCap<COMPOSITION_SHARE>>>();
    let mut composition = scenario.take_shared<Composition<COMPOSITION_SHARE>>();
    let recording = scenario.take_shared<Recording<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let mut routed = scenario.take_shared<RoutedStake<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let mut recording_pool = scenario.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    let mut composition_pool = scenario.take_shared<RoyaltyPool<COMPOSITION_SHARE, CURRENCY>>();
    let vault_admin_cap =
        scenario.take_from_sender<VaultAdminCap<CompositionAdminCap<COMPOSITION_SHARE>>>();
    let mut composition_holder = scenario.take_from_sender<Stake<COMPOSITION_SHARE>>();
    let reward = composition_pool.claim_rewards(&mut composition_holder);
    assert_eq!(reward.value(), 1_000);
    plugin::unregister_for_testing(
        &mut vault,
        &mut composition,
        &recording,
        &mut routed,
        &mut recording_pool,
        &vault_admin_cap,
    );
    plugin::unstake_for_testing(
        &mut vault,
        &mut composition,
        &mut routed,
        &vault_admin_cap,
    );
    assert!(!routed.has_stake());
    test_scenario::return_shared(vault);
    test_scenario::return_shared(composition);
    test_scenario::return_shared(recording);
    test_scenario::return_shared(routed);
    test_scenario::return_shared(recording_pool);
    test_scenario::return_shared(composition_pool);
    scenario.return_to_sender(vault_admin_cap);
    scenario.return_to_sender(composition_holder);
    balance::destroy_for_testing(reward);

    // --- Tx 7 (ADMIN): redeem the returned principal back into the same
    // wrapper, then revoke the plugin and destroy the empty Vault. ---
    scenario.next_tx(ADMIN);
    let mut vault = scenario.take_shared<Vault<CompositionAdminCap<COMPOSITION_SHARE>>>();
    let mut composition = scenario.take_shared<Composition<COMPOSITION_SHARE>>();
    let mut routed = scenario.take_shared<RoutedStake<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let vault_admin_cap =
        scenario.take_from_sender<VaultAdminCap<CompositionAdminCap<COMPOSITION_SHARE>>>();
    let recording_admin_cap =
        scenario.take_from_sender<RecordingAdminCap<RECORDING_SHARE>>();
    let composition_holder = scenario.take_from_sender<Stake<COMPOSITION_SHARE>>();
    plugin::restake_for_testing(
        &mut vault,
        &mut composition,
        &mut routed,
        &vault_admin_cap,
        200,
        scenario.ctx(),
    );
    assert_eq!(routed.value(), 200);
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    assert!(!plugin::is_installed(&vault));
    let composition_admin_cap = vault.destroy(vault_admin_cap);
    test_scenario::return_shared(composition);
    test_scenario::return_shared(routed);
    destroy(composition_admin_cap);
    destroy(recording_admin_cap);
    destroy(composition_holder);
    scenario.end();
}

fun local_fixture(
    ctx: &mut TxContext,
): (
    Composition<COMPOSITION_SHARE>,
    Recording<RECORDING_SHARE, COMPOSITION_SHARE>,
    RecordingAdminCap<RECORDING_SHARE>,
    Vault<CompositionAdminCap<COMPOSITION_SHARE>>,
    VaultAdminCap<CompositionAdminCap<COMPOSITION_SHARE>>,
    RoutedStake<RECORDING_SHARE, COMPOSITION_SHARE>,
) {
    let (mut composition, composition_admin_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Song", 2_000, ctx);
    let (recording, recording_admin_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(composition.id(), ctx);
    let routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        composition.uid_mut(&composition_admin_cap),
        balance::create_for_testing<RECORDING_SHARE>(200),
        ctx,
    );
    let (vault, vault_admin_cap) = vault::new(composition_admin_cap, ctx);
    (
        composition,
        recording,
        recording_admin_cap,
        vault,
        vault_admin_cap,
        routed,
    )
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun lifecycle_is_disabled_before_installation() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, recording, _recording_admin_cap, mut vault, vault_admin_cap, mut routed) =
        local_fixture(ctx);
    let mut recording_for_pool = recording;
    let pool = pool::new<RECORDING_SHARE, CURRENCY>(
        recording_for_pool.uid_mut(&_recording_admin_cap),
    );
    let mut pool = pool;

    plugin::register_for_testing(
        &mut vault,
        &mut composition,
        &recording_for_pool,
        &mut routed,
        &mut pool,
        &vault_admin_cap,
    );
    abort
}

/// Anyone can derive a same-typed pool from an unrelated object on-chain;
/// registration must reject any pool not derived from the supplied Recording.
#[test, expected_failure(abort_code = EPoolNotForRecording, location = plugin)]
fun registration_rejects_a_wrong_parent_pool() {
    let ctx = &mut tx_context::dummy();
    let (
        mut composition,
        recording,
        _recording_admin_cap,
        mut vault,
        vault_admin_cap,
        mut routed,
    ) = local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    // A same-typed pool derived from a foreign parent object — another
    // recording of the same composition is a production-legal object.
    let (mut foreign_recording, foreign_recording_cap) =
        recording::new_for_testing<FOREIGN_RECORDING_SHARE, COMPOSITION_SHARE>(
            composition.id(),
            ctx,
        );
    let mut wrong_pool = pool::new<RECORDING_SHARE, CURRENCY>(
        foreign_recording.uid_mut(&foreign_recording_cap),
    );

    plugin::register_for_testing(
        &mut vault,
        &mut composition,
        &recording,
        &mut routed,
        &mut wrong_pool,
        &vault_admin_cap,
    );
    abort
}

/// On-chain exactly one CompositionAdminCap exists per share type, so a second
/// same-typed Vault can never exist; this pins `assert_admin` as
/// defense-in-depth using synthetic duplicate objects.
#[test, expected_failure(abort_code = ENotVaultAdmin, location = plugin)]
fun lifecycle_rejects_another_vaults_admin_cap() {
    let ctx = &mut tx_context::dummy();
    let (
        mut composition,
        recording,
        _recording_admin_cap,
        mut vault,
        vault_admin_cap,
        _routed,
    ) = local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);

    let (_other_composition, other_composition_admin_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Other", 2_000, ctx);
    let (_other_vault, other_vault_admin_cap) = vault::new(other_composition_admin_cap, ctx);
    balance::create_for_testing<RECORDING_SHARE>(1).send_funds(composition.id().to_address());

    plugin::create_stake_for_testing(
        &mut vault,
        &mut composition,
        &recording,
        &other_vault_admin_cap,
        1,
        ctx,
    );
    abort
}

/// The Recording must belong to the supplied Composition. On-chain this
/// binding always holds when the types unify (one object per share type), so
/// this pins the plugin-side check as defense-in-depth with a synthetic
/// mismatched pair.
#[test, expected_failure(abort_code = ERecordingNotForComposition, location = plugin)]
fun creation_rejects_a_foreign_compositions_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, _recording, _recording_admin_cap, mut vault, vault_admin_cap, _routed) =
        local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    let (foreign_recording, _foreign_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(
            object::id_from_address(@0xC0),
            ctx,
        );

    plugin::create_stake_for_testing(
        &mut vault,
        &mut composition,
        &foreign_recording,
        &vault_admin_cap,
        1,
        ctx,
    );
    abort
}

/// The RoutedStake must be derived from the supplied Composition; the plugin
/// verifies this itself instead of delegating the check to routed_stake.
#[test, expected_failure(abort_code = EStakeNotForComposition, location = plugin)]
fun registration_rejects_a_foreign_compositions_stake() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, mut recording, recording_admin_cap, mut vault, vault_admin_cap, _routed) =
        local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    // The pool is correctly derived from the Recording, so only the stake
    // check can fire.
    let mut pool = pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_admin_cap));
    let (mut foreign_composition, foreign_composition_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Foreign", 2_000, ctx);
    let mut foreign_routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        foreign_composition.uid_mut(&foreign_composition_cap),
        balance::create_for_testing<RECORDING_SHARE>(200),
        ctx,
    );

    plugin::register_for_testing(
        &mut vault,
        &mut composition,
        &recording,
        &mut foreign_routed,
        &mut pool,
        &vault_admin_cap,
    );
    abort
}

/// Unregistration pins the pool to the Recording just like registration does.
#[test, expected_failure(abort_code = EPoolNotForRecording, location = plugin)]
fun unregistration_rejects_a_wrong_parent_pool() {
    let ctx = &mut tx_context::dummy();
    let (
        mut composition,
        recording,
        _recording_admin_cap,
        mut vault,
        vault_admin_cap,
        mut routed,
    ) = local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    // The routed stake is correctly derived from the Composition, so only the
    // pool check can fire.
    let (mut foreign_recording, foreign_recording_cap) =
        recording::new_for_testing<FOREIGN_RECORDING_SHARE, COMPOSITION_SHARE>(
            composition.id(),
            ctx,
        );
    let mut wrong_pool = pool::new<RECORDING_SHARE, CURRENCY>(
        foreign_recording.uid_mut(&foreign_recording_cap),
    );

    plugin::unregister_for_testing(
        &mut vault,
        &mut composition,
        &recording,
        &mut routed,
        &mut wrong_pool,
        &vault_admin_cap,
    );
    abort
}

#[test, expected_failure(abort_code = EPluginAlreadyAuthorized, location = vault)]
fun installation_is_not_idempotent() {
    let ctx = &mut tx_context::dummy();
    let (_composition, _recording, _recording_admin_cap, mut vault, vault_admin_cap, _routed) =
        local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    abort
}

#[test, expected_failure(abort_code = EStakeExists, location = routed_stake)]
fun restake_rejects_a_filled_stake() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, _recording, _recording_admin_cap, mut vault, vault_admin_cap, mut routed) =
        local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    balance::create_for_testing<RECORDING_SHARE>(1).send_funds(composition.id().to_address());

    plugin::restake_for_testing(&mut vault, &mut composition, &mut routed, &vault_admin_cap, 1, ctx);
    abort
}

#[test, expected_failure(abort_code = ENoStake, location = routed_stake)]
fun unstake_rejects_an_empty_stake() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, _recording, _recording_admin_cap, mut vault, vault_admin_cap, mut routed) =
        local_fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);

    // The fresh stake has no registrations, so the first unstake succeeds and
    // leaves the wrapper empty; the second aborts.
    plugin::unstake_for_testing(&mut vault, &mut composition, &mut routed, &vault_admin_cap);
    plugin::unstake_for_testing(&mut vault, &mut composition, &mut routed, &vault_admin_cap);
    abort
}
