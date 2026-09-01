// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault adapter for Recording royalty-pool Actions.
module recording_royalty_pool_plugin::recording_royalty_pool_plugin;

use miso::recording::{Recording, RecordingAdminCap};
use recording_royalty_pool::recording_royalty_pool as action;
use recording_royalty_pool_plugin::witness::{Self, Witness};
use royalty_pool::pool::RoyaltyPool;
use sui::coin::Coin;
use sui::transfer::Receiving;
use vault::vault::{Vault, VaultAdminCap};

public fun install<RecordingShare>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new())
}

public fun uninstall<RecordingShare>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    vault.revoke_plugin<RecordingAdminCap<RecordingShare>, Witness>(vault_admin_cap)
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
    action::receive_and_deposit(recording, &cap, pool, coins);
    vault.put_back(cap, receipt)
}

fun execute_redeem_and_deposit<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    value: u64,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::redeem_and_deposit(recording, &cap, pool, value);
    vault.put_back(cap, receipt)
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
