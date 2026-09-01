// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault adapter for Release revenue-distribution Actions.
module release_revenue_distributor_plugin::release_revenue_distributor_plugin;

use miso::release::{Release, ReleaseAdminCap};
use release_revenue_distributor::release_revenue_distributor as action;
use release_revenue_distributor_plugin::witness::{Self, Witness};
use sui::accumulator::AccumulatorRoot;
use sui::coin::Coin;
use sui::transfer::Receiving;
use vault::vault::{Vault, VaultAdminCap};

public fun install(
    vault: &mut Vault<ReleaseAdminCap>,
    vault_admin_cap: &VaultAdminCap<ReleaseAdminCap>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new())
}

public fun uninstall(
    vault: &mut Vault<ReleaseAdminCap>,
    vault_admin_cap: &VaultAdminCap<ReleaseAdminCap>,
) {
    vault.revoke_plugin<ReleaseAdminCap, Witness>(vault_admin_cap)
}

public fun is_installed(vault: &Vault<ReleaseAdminCap>): bool {
    vault.is_plugin_authorized<ReleaseAdminCap, Witness>()
}

entry fun receive_and_distribute<Currency>(
    vault: &mut Vault<ReleaseAdminCap>,
    release: &mut Release,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    execute_receive_and_distribute(vault, release, coins)
}

entry fun redeem_all_and_distribute<Currency>(
    vault: &mut Vault<ReleaseAdminCap>,
    release: &mut Release,
    root: &AccumulatorRoot,
) {
    execute_redeem_all_and_distribute<Currency>(vault, release, root)
}

fun execute_receive_and_distribute<Currency>(
    vault: &mut Vault<ReleaseAdminCap>,
    release: &mut Release,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::receive_and_distribute(release, &cap, coins);
    vault.put_back(cap, receipt)
}

fun execute_redeem_all_and_distribute<Currency>(
    vault: &mut Vault<ReleaseAdminCap>,
    release: &mut Release,
    root: &AccumulatorRoot,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::redeem_all_and_distribute<Currency>(release, &cap, root);
    vault.put_back(cap, receipt)
}

#[test_only]
public fun receive_and_distribute_for_testing<Currency>(
    vault: &mut Vault<ReleaseAdminCap>,
    release: &mut Release,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    receive_and_distribute(vault, release, coins)
}

#[test_only]
public fun redeem_all_and_distribute_for_testing<Currency>(
    vault: &mut Vault<ReleaseAdminCap>,
    release: &mut Release,
    root: &AccumulatorRoot,
) {
    redeem_all_and_distribute<Currency>(vault, release, root)
}
