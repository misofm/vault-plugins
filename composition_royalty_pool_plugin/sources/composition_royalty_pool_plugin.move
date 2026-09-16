// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault adapter for Composition royalty-pool Actions.
module composition_royalty_pool_plugin::composition_royalty_pool_plugin;

use composition_royalty_pool::composition_royalty_pool as action;
use composition_royalty_pool_plugin::witness::{Self, Witness};
use musicos::composition::{Composition, CompositionAdminCap};
use royalty_pool::pool::RoyaltyPool;
use sui::accumulator::AccumulatorRoot;
use sui::coin::Coin;
use sui::transfer::Receiving;
use vault::vault::{Vault, VaultAdminCap};

public fun install<CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    vault.authorize_plugin(cap, witness::new());
}

public fun uninstall<CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    vault.revoke_plugin<CompositionAdminCap<CompositionShare>, Witness>(cap);
}

public fun is_installed<CompositionShare>(
    vault: &Vault<CompositionAdminCap<CompositionShare>>,
): bool {
    vault.is_plugin_authorized<CompositionAdminCap<CompositionShare>, Witness>()
}

entry fun receive_and_deposit<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    execute_receive_and_deposit(vault, composition, pool, coins)
}

/// Permissionless crank: redeem the Composition's full settled accumulator
/// snapshot into its canonical pool. Takes the framework `AccumulatorRoot`
/// and no amount, so a caller cannot fragment settlement. A zero snapshot or
/// a pool with no registered stake is a no-op that redeems nothing and emits
/// no deposit event, so an item cranked in an earlier consensus commit, or an
/// unstaked one, passes through a batched crank untouched.
///
/// The snapshot is constant within a commit (only settlement writes it), so
/// cranking the same Composition twice in one PTB, or from two transactions in
/// the same commit, withdraws it twice and the network fails that whole
/// transaction with `InsufficientFundsForWithdraw` (not a Move abort).
/// Include each object at most once per PTB and retry that status next
/// commit.
entry fun redeem_all_and_deposit<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    root: &AccumulatorRoot,
) {
    execute_redeem_all_and_deposit(vault, composition, pool, root)
}

fun execute_receive_and_deposit<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    let (vaulted_cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::receive_and_deposit(composition, &vaulted_cap, pool, coins);
    vault.put_back(vaulted_cap, receipt);
}

fun execute_redeem_all_and_deposit<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    root: &AccumulatorRoot,
) {
    let (vaulted_cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::redeem_all_and_deposit(composition, &vaulted_cap, pool, root);
    vault.put_back(vaulted_cap, receipt);
}

#[test_only]
public fun receive_and_deposit_for_testing<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    receive_and_deposit(vault, composition, pool, coins)
}

#[test_only]
public fun redeem_all_and_deposit_for_testing<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    root: &AccumulatorRoot,
) {
    redeem_all_and_deposit(vault, composition, pool, root)
}

/// Run the production borrow -> Action -> put_back sequence against the
/// Action's private settled-value helper, since the unit VM cannot settle a
/// positive `AccumulatorRoot` snapshot.
#[test_only]
public fun redeem_settled_value_and_deposit_for_testing<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    value: u64,
) {
    let (vaulted_cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::redeem_settled_value_and_deposit_for_testing(composition, &vaulted_cap, pool, value);
    vault.put_back(vaulted_cap, receipt);
}
