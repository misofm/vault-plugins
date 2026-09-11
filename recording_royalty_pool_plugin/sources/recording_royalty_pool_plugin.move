// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault adapter for Recording royalty-pool Actions.
module recording_royalty_pool_plugin::recording_royalty_pool_plugin;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_royalty_pool::recording_royalty_pool as action;
use recording_royalty_pool_plugin::witness::{Self, Witness};
use royalty_pool::pool::{Self, RoyaltyPool};
use sui::bag;
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;
use vault::vault::{Vault, VaultAdminCap};

// === Events ===

/// Snapshot of this plugin's authorization record after installation.
public struct RecordingRoyaltyPoolPluginInstalledEvent<phantom RecordingShare>
    has copy, drop {
    vault_id: address,
    cap_id: address,
    vault_admin_cap_id: address,
    authorized_plugins_id: address,
    authorized_plugin_count: u64,
    installed: bool,
}

/// Snapshot of this plugin's authorization record after uninstallation.
public struct RecordingRoyaltyPoolPluginUninstalledEvent<phantom RecordingShare>
    has copy, drop {
    vault_id: address,
    cap_id: address,
    vault_admin_cap_id: address,
    authorized_plugins_id: address,
    authorized_plugin_count: u64,
    installed: bool,
}

/// Custody snapshot immediately after this plugin leases the Recording cap.
public struct RecordingVaultCapabilityBorrowedEvent<phantom RecordingShare, phantom CompositionShare, phantom Currency>
    has copy, drop {
    vault_id: address,
    cap_id: address,
    recording_id: address,
    composition_id: address,
    pool_id: address,
    active: bool,
    capability_available: bool,
}

/// Financial and restored-custody snapshot after a successful coin deposit.
public struct RecordingCoinsDepositedEvent<phantom RecordingShare, phantom CompositionShare, phantom Currency>
    has copy, drop {
    vault_id: address,
    cap_id: address,
    recording_id: address,
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
    active: bool,
    capability_available: bool,
    coin_ids: vector<address>,
}

/// Financial and restored-custody snapshot after a successful accumulator
/// redemption. `amount` is the exact requested Action value.
public struct RecordingFundsDepositedEvent<phantom RecordingShare, phantom CompositionShare, phantom Currency>
    has copy, drop {
    vault_id: address,
    cap_id: address,
    recording_id: address,
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
    active: bool,
    capability_available: bool,
    amount: u64,
}

public fun install<RecordingShare>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new());
    emit(RecordingRoyaltyPoolPluginInstalledEvent<RecordingShare> {
        vault_id: object::id(vault).to_address(),
        cap_id: vault.cap_id().to_address(),
        vault_admin_cap_id: object::id(vault_admin_cap).to_address(),
        authorized_plugins_id: object::id(vault.authorized_plugins()).to_address(),
        authorized_plugin_count: bag::length(vault.authorized_plugins()),
        installed: vault.is_plugin_authorized<RecordingAdminCap<RecordingShare>, Witness>(),
    });
}

public fun uninstall<RecordingShare>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    vault.revoke_plugin<RecordingAdminCap<RecordingShare>, Witness>(vault_admin_cap);
    emit(RecordingRoyaltyPoolPluginUninstalledEvent<RecordingShare> {
        vault_id: object::id(vault).to_address(),
        cap_id: vault.cap_id().to_address(),
        vault_admin_cap_id: object::id(vault_admin_cap).to_address(),
        authorized_plugins_id: object::id(vault.authorized_plugins()).to_address(),
        authorized_plugin_count: bag::length(vault.authorized_plugins()),
        installed: vault.is_plugin_authorized<RecordingAdminCap<RecordingShare>, Witness>(),
    });
}

public fun is_installed<RecordingShare>(
    vault: &Vault<RecordingAdminCap<RecordingShare>>,
): bool {
    vault.is_plugin_authorized<RecordingAdminCap<RecordingShare>, Witness>()
}

entry fun receive_and_deposit<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    execute_receive_and_deposit(vault, recording, pool, coins)
}

entry fun redeem_and_deposit<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    value: u64,
) {
    execute_redeem_and_deposit(vault, recording, pool, value)
}

fun execute_receive_and_deposit<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let vault_id = object::id(vault).to_address();
    let cap_id = object::id(&cap).to_address();
    let recording_id = object::id(recording).to_address();
    let composition_id = recording::composition_id(recording).to_address();
    let pool_id = object::id(pool).to_address();
    let pool_balance_before = pool.balance().value();
    let staked_shares = pool.staked_shares();
    let reward_per_share_before = pool.cumulative_reward_per_share();
    let carry_before = pool.carry();
    let cumulative_deposits_before = pool.cumulative_deposits();
    let coin_ids = coins.map_ref!(|coin| sui::transfer::receiving_object_id(coin).to_address());
    emit(RecordingVaultCapabilityBorrowedEvent<RecordingShare, CompositionShare, Currency> {
        vault_id,
        cap_id,
        recording_id,
        composition_id,
        pool_id,
        active: vault.is_active(),
        capability_available: false,
    });
    action::receive_and_deposit(recording, &cap, pool, coins);
    vault.put_back(cap, receipt);
    emit(RecordingCoinsDepositedEvent<RecordingShare, CompositionShare, Currency> {
        vault_id,
        cap_id,
        recording_id,
        composition_id,
        pool_id,
        pool_balance_before,
        pool_balance_after: pool.balance().value(),
        staked_shares,
        reward_per_share_before,
        reward_per_share_after: pool.cumulative_reward_per_share(),
        carry_before,
        carry_after: pool.carry(),
        cumulative_deposits_before,
        cumulative_deposits_after: pool.cumulative_deposits(),
        active: vault.is_active(),
        capability_available: true,
        coin_ids,
    });
}

fun execute_redeem_and_deposit<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    value: u64,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let vault_id = object::id(vault).to_address();
    let cap_id = object::id(&cap).to_address();
    let recording_id = object::id(recording).to_address();
    let composition_id = recording::composition_id(recording).to_address();
    let pool_id = object::id(pool).to_address();
    let pool_balance_before = pool.balance().value();
    let staked_shares = pool.staked_shares();
    let reward_per_share_before = pool.cumulative_reward_per_share();
    let carry_before = pool.carry();
    let cumulative_deposits_before = pool.cumulative_deposits();
    emit(RecordingVaultCapabilityBorrowedEvent<RecordingShare, CompositionShare, Currency> {
        vault_id,
        cap_id,
        recording_id,
        composition_id,
        pool_id,
        active: vault.is_active(),
        capability_available: false,
    });
    action::redeem_and_deposit(recording, &cap, pool, value);
    vault.put_back(cap, receipt);
    emit(RecordingFundsDepositedEvent<RecordingShare, CompositionShare, Currency> {
        vault_id,
        cap_id,
        recording_id,
        composition_id,
        pool_id,
        pool_balance_before,
        pool_balance_after: pool.balance().value(),
        staked_shares,
        reward_per_share_before,
        reward_per_share_after: pool.cumulative_reward_per_share(),
        carry_before,
        carry_after: pool.carry(),
        cumulative_deposits_before,
        cumulative_deposits_after: pool.cumulative_deposits(),
        active: vault.is_active(),
        capability_available: true,
        amount: value,
    });
}

#[test_only]
public fun receive_and_deposit_for_testing<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    receive_and_deposit(vault, recording, pool, coins)
}

#[test_only]
public fun redeem_and_deposit_for_testing<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    value: u64,
) {
    redeem_and_deposit(vault, recording, pool, value)
}

// === Test Functions ===

#[test_only]
public fun installed_event_fields<RecordingShare>(
    event: &RecordingRoyaltyPoolPluginInstalledEvent<RecordingShare>,
): (address, address, address, address, u64, bool) {
    (
        event.vault_id,
        event.cap_id,
        event.vault_admin_cap_id,
        event.authorized_plugins_id,
        event.authorized_plugin_count,
        event.installed,
    )
}

#[test_only]
public fun uninstalled_event_fields<RecordingShare>(
    event: &RecordingRoyaltyPoolPluginUninstalledEvent<RecordingShare>,
): (address, address, address, address, u64, bool) {
    (
        event.vault_id,
        event.cap_id,
        event.vault_admin_cap_id,
        event.authorized_plugins_id,
        event.authorized_plugin_count,
        event.installed,
    )
}

#[test_only]
public fun borrowed_event_fields<RecordingShare, CompositionShare, Currency>(
    event: &RecordingVaultCapabilityBorrowedEvent<RecordingShare, CompositionShare, Currency>,
): (address, address, address, address, address, bool, bool) {
    (
        event.vault_id,
        event.cap_id,
        event.recording_id,
        event.composition_id,
        event.pool_id,
        event.active,
        event.capability_available,
    )
}

#[test_only]
public fun coins_deposited_event_fields<RecordingShare, CompositionShare, Currency>(
    event: &RecordingCoinsDepositedEvent<RecordingShare, CompositionShare, Currency>,
): (address, address, address, address, address, u64, u64, u64, u256, u256, u128, u128, u128, u128, bool, bool, vector<address>) {
    (
        event.vault_id,
        event.cap_id,
        event.recording_id,
        event.composition_id,
        event.pool_id,
        event.pool_balance_before,
        event.pool_balance_after,
        event.staked_shares,
        event.reward_per_share_before,
        event.reward_per_share_after,
        event.carry_before,
        event.carry_after,
        event.cumulative_deposits_before,
        event.cumulative_deposits_after,
        event.active,
        event.capability_available,
        event.coin_ids,
    )
}

#[test_only]
public fun funds_deposited_event_fields<RecordingShare, CompositionShare, Currency>(
    event: &RecordingFundsDepositedEvent<RecordingShare, CompositionShare, Currency>,
): (address, address, address, address, address, u64, u64, u64, u256, u256, u128, u128, u128, u128, bool, bool, u64) {
    (
        event.vault_id,
        event.cap_id,
        event.recording_id,
        event.composition_id,
        event.pool_id,
        event.pool_balance_before,
        event.pool_balance_after,
        event.staked_shares,
        event.reward_per_share_before,
        event.reward_per_share_after,
        event.carry_before,
        event.carry_after,
        event.cumulative_deposits_before,
        event.cumulative_deposits_after,
        event.active,
        event.capability_available,
        event.amount,
    )
}
