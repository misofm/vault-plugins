// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault adapter for Composition royalty-pool Actions.
module composition_royalty_pool_plugin::composition_royalty_pool_plugin;

use composition_royalty_pool::composition_royalty_pool as action;
use composition_royalty_pool_plugin::witness::{Self, Witness};
use miso::composition::{Composition, CompositionAdminCap};
use royalty_pool::pool::RoyaltyPool;
use sui::coin::Coin;
use sui::transfer::Receiving;
use vault::vault::{Vault, VaultAdminCap};

public fun install<CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new())
}

public fun uninstall<CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    vault.revoke_plugin<CompositionAdminCap<CompositionShare>, Witness>(vault_admin_cap)
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

entry fun redeem_and_deposit<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    value: u64,
) {
    execute_redeem_and_deposit(vault, composition, pool, value)
}

fun execute_receive_and_deposit<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::receive_and_deposit(composition, &cap, pool, coins);
    vault.put_back(cap, receipt)
}

fun execute_redeem_and_deposit<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    value: u64,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::redeem_and_deposit(composition, &cap, pool, value);
    vault.put_back(cap, receipt)
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
public fun redeem_and_deposit_for_testing<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    value: u64,
) {
    redeem_and_deposit(vault, composition, pool, value)
}
