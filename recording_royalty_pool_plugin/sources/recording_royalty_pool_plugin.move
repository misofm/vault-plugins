// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault adapter for Recording royalty-pool Actions.
module recording_royalty_pool_plugin::recording_royalty_pool_plugin;

use musicos::recording::{Recording, RecordingAdminCap};
use recording_royalty_pool::recording_royalty_pool as action;
use recording_royalty_pool_plugin::witness::{Self, Witness};
use royalty_pool::pool::RoyaltyPool;
use sui::accumulator::AccumulatorRoot;
use sui::coin::Coin;
use sui::transfer::Receiving;
use vault::vault::{Vault, VaultAdminCap};

public fun install<RecordingShare>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new());
}

public fun uninstall<RecordingShare>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    vault.revoke_plugin<RecordingAdminCap<RecordingShare>, Witness>(vault_admin_cap);
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

/// Permissionless crank: redeem the Recording's full settled accumulator
/// snapshot into its canonical pool. Takes the framework `AccumulatorRoot`
/// and no amount, so a caller cannot fragment settlement. A zero snapshot or
/// a pool with no registered stake is a no-op that redeems nothing and emits
/// no deposit event, so an item cranked in an earlier consensus commit, or an
/// unstaked one, passes through a batched crank untouched.
///
/// The snapshot is constant within a commit (only settlement writes it), so
/// cranking the same Recording twice in one PTB, or from two transactions in
/// the same commit, withdraws it twice and the network fails that whole
/// transaction with `InsufficientFundsForWithdraw` (not a Move abort).
/// Include each object at most once per PTB and retry that status next
/// commit.
entry fun redeem_all_and_deposit<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    root: &AccumulatorRoot,
) {
    execute_redeem_all_and_deposit(vault, recording, pool, root)
}

fun execute_receive_and_deposit<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::receive_and_deposit(recording, &cap, pool, coins);
    vault.put_back(cap, receipt);
}

fun execute_redeem_all_and_deposit<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    root: &AccumulatorRoot,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::redeem_all_and_deposit(recording, &cap, pool, root);
    vault.put_back(cap, receipt);
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
public fun redeem_all_and_deposit_for_testing<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    root: &AccumulatorRoot,
) {
    redeem_all_and_deposit(vault, recording, pool, root)
}

/// Run the production borrow -> Action -> put_back sequence against the
/// Action's private settled-value helper, since the unit VM cannot settle a
/// positive `AccumulatorRoot` snapshot.
#[test_only]
public fun redeem_settled_value_and_deposit_for_testing<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    value: u64,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::redeem_settled_value_and_deposit_for_testing(recording, &cap, pool, value);
    vault.put_back(cap, receipt);
}
