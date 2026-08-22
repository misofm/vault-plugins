// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_royalty_pool::recording_royalty_pool_tests;

use miso::composition::{Self, Composition};
use miso::recording::{Self, Recording, RecordingAdminCap};
use recording_royalty_pool::recording_royalty_pool as plugin;
use recording_royalty_pool::share::{Self, Share};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::coin::{Self, Coin};
use sui::coin_registry::Currency;
use sui::test_scenario;
use vault::vault::{Self, Vault, VaultAdminCap};

const ENotVaultAdmin: u64 = 0;
const EPoolNotDerivedFromParent: u64 = 0;
const EPluginAlreadyAuthorized: u64 = 1;
const EPluginNotAuthorized: u64 = 2;

const STRANGER: address = @0x51;

public struct COMPOSITION_SHARE() has drop;
/// Placeholder share type for a foreign parent object used to derive a
/// same-typed but wrongly-parented pool.
public struct FOREIGN_RECORDING_SHARE() has drop;
public struct CURRENCY() has drop;

/// Production-shaped fixture: the recording is issued through the real
/// `recording::new` flow with a genuine fixed-supply share currency, which
/// also routes the composition cut to the composition address. The
/// composition's own share currency is irrelevant to this plugin, so the
/// composition is synthetic.
fun fixture(
    ctx: &mut TxContext,
): (
    Composition<COMPOSITION_SHARE>,
    Recording<Share, COMPOSITION_SHARE>,
    Currency<Share>,
    Vault<RecordingAdminCap<Share>>,
    VaultAdminCap<RecordingAdminCap<Share>>,
    balance::Balance<Share>,
) {
    let (composition, composition_admin_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Composition", 2_000, ctx);
    let (mut currency, treasury_cap) = share::bootstrap_currency(ctx);
    let (recording, cap, shares) =
        recording::new(&composition, &mut currency, treasury_cap, ctx);
    let (vault, vault_admin_cap) = vault::new(cap, ctx);
    destroy(composition_admin_cap);
    (composition, recording, currency, vault, vault_admin_cap, shares)
}

fun destroy_fixture(
    composition: Composition<COMPOSITION_SHARE>,
    recording: Recording<Share, COMPOSITION_SHARE>,
    currency: Currency<Share>,
    vault: Vault<RecordingAdminCap<Share>>,
    vault_admin_cap: VaultAdminCap<RecordingAdminCap<Share>>,
    shares: balance::Balance<Share>,
) {
    let cap = vault.destroy(vault_admin_cap);
    destroy(composition);
    destroy(recording);
    destroy(currency);
    destroy(cap);
    destroy(shares);
}

#[test]
fun installation_is_explicit_and_revocable() {
    let ctx = &mut tx_context::dummy();
    let (composition, recording, currency, mut vault, vault_admin_cap, shares) = fixture(ctx);

    assert!(!plugin::is_installed(&vault));
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    assert!(plugin::is_installed(&vault));
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    assert!(!plugin::is_installed(&vault));

    destroy_fixture(composition, recording, currency, vault, vault_admin_cap, shares);
}

#[test, expected_failure(abort_code = EPluginNotAuthorized, location = vault)]
fun pool_cannot_be_initialized_before_installation() {
    let ctx = &mut tx_context::dummy();
    let (_composition, mut recording, _currency, mut vault, vault_admin_cap, _shares) =
        fixture(ctx);
    plugin::initialize_pool_for_testing<Share, COMPOSITION_SHARE, CURRENCY>(
        &mut vault,
        &mut recording,
        &vault_admin_cap,
    );
    abort
}

#[test]
fun pool_parent_is_recording_and_survives_vault_replacement() {
    // Currency bootstrap requires the system sender.
    let mut scenario = test_scenario::begin(@0x0);
    let (composition, mut recording, currency, mut vault, vault_admin_cap, shares) =
        fixture(scenario.ctx());
    let recording_id = recording.id();
    let pool_address =
        plugin::pool_address<Share, COMPOSITION_SHARE, CURRENCY>(&recording);

    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::initialize_pool_for_testing<Share, COMPOSITION_SHARE, CURRENCY>(
        &mut vault,
        &mut recording,
        &vault_admin_cap,
    );

    scenario.next_tx(@0xA);
    let pool_id = object::id_from_address(pool_address);
    let pool: RoyaltyPool<Share, CURRENCY> = scenario.take_shared_by_id(pool_id);
    pool.assert_derived_from(recording_id);
    test_scenario::return_shared(pool);

    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    let cap = vault.destroy(vault_admin_cap);
    let (replacement_vault, replacement_admin_cap) = vault::new(cap, scenario.ctx());
    assert_eq!(
        plugin::pool_address<Share, COMPOSITION_SHARE, CURRENCY>(&recording),
        pool_address,
    );
    destroy_fixture(composition, recording, currency, replacement_vault, replacement_admin_cap, shares);
    scenario.end();
}

#[test]
fun recording_revenue_paths_are_forced_into_canonical_pool() {
    let mut scenario = test_scenario::begin(@0x0);
    let (composition, mut recording, currency, mut vault, vault_admin_cap, mut shares) =
        fixture(scenario.ctx());
    let recording_id = recording.id();
    let pool_id = object::id_from_address(
        plugin::pool_address<Share, COMPOSITION_SHARE, CURRENCY>(&recording),
    );

    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::initialize_pool_for_testing<Share, COMPOSITION_SHARE, CURRENCY>(
        &mut vault,
        &mut recording,
        &vault_admin_cap,
    );

    scenario.next_tx(@0xA);
    let mut pool: RoyaltyPool<Share, CURRENCY> =
        scenario.take_shared_by_id(pool_id);
    // The holder's stake is carved out of the real fixed share supply.
    let mut holder = stake::new(shares.split(100), scenario.ctx());
    pool.register_stake(&mut holder);

    let paid_coin = coin::from_balance(
        balance::create_for_testing<CURRENCY>(1_000),
        scenario.ctx(),
    );
    let paid_coin_id = object::id(&paid_coin);
    transfer::public_transfer(paid_coin, recording_id.to_address());

    scenario.next_tx(@0xA);
    let receiving = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(paid_coin_id);
    plugin::receive_and_deposit_for_testing(
        &mut vault,
        &mut recording,
        &mut pool,
        vector[receiving],
    );
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 1_000);

    balance::create_for_testing<CURRENCY>(500).send_funds(recording_id.to_address());
    scenario.next_tx(@0xA);
    plugin::redeem_and_deposit_for_testing(
        &mut vault,
        &mut recording,
        &mut pool,
        500,
    );
    let redeemed_reward = pool.claim_rewards(&mut holder);
    assert_eq!(redeemed_reward.value(), 500);

    pool.unregister_stake(&mut holder);
    test_scenario::return_shared(pool);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    balance::destroy_for_testing(redeemed_reward);
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    destroy_fixture(composition, recording, currency, vault, vault_admin_cap, shares);
    scenario.end();
}

/// On-chain exactly one RecordingAdminCap exists per share type, so a second
/// same-typed Vault can never exist; this pins `assert_admin` as
/// defense-in-depth using synthetic duplicate objects.
#[test, expected_failure(abort_code = ENotVaultAdmin, location = plugin)]
fun foreign_vault_admin_cannot_initialize_pool() {
    let ctx = &mut tx_context::dummy();
    let (mut recording_a, cap_a) = recording::new_for_testing<Share, COMPOSITION_SHARE>(
        object::id_from_address(@0xC0),
        ctx,
    );
    let (_recording_b, cap_b) = recording::new_for_testing<Share, COMPOSITION_SHARE>(
        object::id_from_address(@0xC0),
        ctx,
    );
    let (mut vault_a, vault_admin_cap_a) = vault::new(cap_a, ctx);
    let (_vault_b, vault_admin_cap_b) = vault::new(cap_b, ctx);
    plugin::install_for_testing(&mut vault_a, &vault_admin_cap_a);

    plugin::initialize_pool_for_testing<Share, COMPOSITION_SHARE, CURRENCY>(
        &mut vault_a,
        &mut recording_a,
        &vault_admin_cap_b,
    );
    abort
}

/// Anyone can derive a same-typed pool from an unrelated object on-chain, but
/// the plugin only deposits into the pool derived from the recording itself.
#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = pool)]
fun recording_revenue_cannot_enter_a_wrong_parent_pool() {
    let ctx = &mut tx_context::dummy();
    let (composition, mut recording, _currency, mut vault, vault_admin_cap, _shares) =
        fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);

    // A same-typed pool derived from a foreign parent object — another
    // recording of the same composition is a production-legal object.
    let (mut foreign, foreign_cap) =
        recording::new_for_testing<FOREIGN_RECORDING_SHARE, COMPOSITION_SHARE>(
            composition.id(),
            ctx,
        );
    let mut wrong_pool = pool::new<Share, CURRENCY>(foreign.uid_mut(&foreign_cap));

    plugin::redeem_and_deposit_for_testing<Share, COMPOSITION_SHARE, CURRENCY>(
        &mut vault,
        &mut recording,
        &mut wrong_pool,
        1,
    );
    abort
}

#[test, expected_failure(abort_code = EPluginAlreadyAuthorized, location = vault)]
fun installation_is_not_idempotent() {
    let ctx = &mut tx_context::dummy();
    let (_composition, _recording, _currency, mut vault, vault_admin_cap, _shares) = fixture(ctx);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    abort
}

/// The crank needs no capability: a sender holding nothing can fold
/// Recording-addressed funds into the canonical pool.
#[test]
fun strangers_can_crank_revenue_into_the_pool() {
    let mut scenario = test_scenario::begin(@0x0);
    let (composition, mut recording, currency, mut vault, vault_admin_cap, mut shares) =
        fixture(scenario.ctx());
    let recording_id = recording.id();
    let pool_id = object::id_from_address(
        plugin::pool_address<Share, COMPOSITION_SHARE, CURRENCY>(&recording),
    );

    plugin::install_for_testing(&mut vault, &vault_admin_cap);
    plugin::initialize_pool_for_testing<Share, COMPOSITION_SHARE, CURRENCY>(
        &mut vault,
        &mut recording,
        &vault_admin_cap,
    );
    balance::create_for_testing<CURRENCY>(1_000).send_funds(recording_id.to_address());

    // The crank transaction is sent by an address holding no capability.
    scenario.next_tx(STRANGER);
    let mut pool: RoyaltyPool<Share, CURRENCY> = scenario.take_shared_by_id(pool_id);
    let mut holder = stake::new(shares.split(100), scenario.ctx());
    pool.register_stake(&mut holder);
    plugin::redeem_and_deposit_for_testing(&mut vault, &mut recording, &mut pool, 1_000);
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 1_000);

    pool.unregister_stake(&mut holder);
    test_scenario::return_shared(pool);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    plugin::uninstall_for_testing(&mut vault, &vault_admin_cap);
    destroy_fixture(composition, recording, currency, vault, vault_admin_cap, shares);
    scenario.end();
}
