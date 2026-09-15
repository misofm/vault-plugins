// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault adapter for Release revenue-distribution Actions.
module release_revenue_distributor_plugin::release_revenue_distributor_plugin;

use musicos::release::{Release, ReleaseAdminCap};
use release_revenue_distributor::release_revenue_distributor as action;
use release_revenue_distributor_plugin::witness::{Self, Witness};
use sui::accumulator::AccumulatorRoot;
use sui::bag;
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;
use vault::vault::{Vault, VaultAdminCap};

/// Snapshot of this plugin's authorization transition after installation.
public struct ReleaseRevenueDistributorPluginInstalledEvent<phantom Cap, phantom Plugin>
    has copy, drop {
    vault_id: address,
    vault_admin_cap_id: address,
    release_admin_cap_id: address,
    vault_active: bool,
    authorized_before: bool,
    authorized_after: bool,
    authorized_plugin_count_before: u64,
    authorized_plugin_count_after: u64,
}

/// Snapshot of this plugin's authorization transition after uninstallation.
public struct ReleaseRevenueDistributorPluginUninstalledEvent<phantom Cap, phantom Plugin>
    has copy, drop {
    vault_id: address,
    vault_admin_cap_id: address,
    release_admin_cap_id: address,
    vault_active: bool,
    authorized_before: bool,
    authorized_after: bool,
    authorized_plugin_count_before: u64,
    authorized_plugin_count_after: u64,
}

public fun install(
    vault: &mut Vault<ReleaseAdminCap>,
    vault_admin_cap: &VaultAdminCap<ReleaseAdminCap>,
) {
    let vault_id = object::id(vault).to_address();
    let vault_admin_cap_id = object::id(vault_admin_cap).to_address();
    let release_admin_cap_id = vault.cap_id().to_address();
    let authorized_before = vault.is_plugin_authorized<ReleaseAdminCap, Witness>();
    let authorized_plugin_count_before = bag::length(vault.authorized_plugins());
    vault.authorize_plugin(vault_admin_cap, witness::new());
    emit(ReleaseRevenueDistributorPluginInstalledEvent<ReleaseAdminCap, Witness> {
        vault_id,
        vault_admin_cap_id,
        release_admin_cap_id,
        vault_active: vault.is_active(),
        authorized_before,
        authorized_after: vault.is_plugin_authorized<ReleaseAdminCap, Witness>(),
        authorized_plugin_count_before,
        authorized_plugin_count_after: bag::length(vault.authorized_plugins()),
    })
}

public fun uninstall(
    vault: &mut Vault<ReleaseAdminCap>,
    vault_admin_cap: &VaultAdminCap<ReleaseAdminCap>,
) {
    let vault_id = object::id(vault).to_address();
    let vault_admin_cap_id = object::id(vault_admin_cap).to_address();
    let release_admin_cap_id = vault.cap_id().to_address();
    let authorized_before = vault.is_plugin_authorized<ReleaseAdminCap, Witness>();
    let authorized_plugin_count_before = bag::length(vault.authorized_plugins());
    vault.revoke_plugin<ReleaseAdminCap, Witness>(vault_admin_cap);
    emit(ReleaseRevenueDistributorPluginUninstalledEvent<ReleaseAdminCap, Witness> {
        vault_id,
        vault_admin_cap_id,
        release_admin_cap_id,
        vault_active: vault.is_active(),
        authorized_before,
        authorized_after: vault.is_plugin_authorized<ReleaseAdminCap, Witness>(),
        authorized_plugin_count_before,
        authorized_plugin_count_after: bag::length(vault.authorized_plugins()),
    })
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
    vault.put_back(cap, receipt);
}

fun execute_redeem_all_and_distribute<Currency>(
    vault: &mut Vault<ReleaseAdminCap>,
    release: &mut Release,
    root: &AccumulatorRoot,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    action::redeem_all_and_distribute<Currency>(release, &cap, root);
    vault.put_back(cap, receipt);
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

#[test_only]
public fun installed_event_fields<Cap, Plugin>(
    event: &ReleaseRevenueDistributorPluginInstalledEvent<Cap, Plugin>,
): (address, address, address, bool, bool, bool, u64, u64) {
    (
        event.vault_id,
        event.vault_admin_cap_id,
        event.release_admin_cap_id,
        event.vault_active,
        event.authorized_before,
        event.authorized_after,
        event.authorized_plugin_count_before,
        event.authorized_plugin_count_after,
    )
}

#[test_only]
public fun uninstalled_event_fields<Cap, Plugin>(
    event: &ReleaseRevenueDistributorPluginUninstalledEvent<Cap, Plugin>,
): (address, address, address, bool, bool, bool, u64, u64) {
    (
        event.vault_id,
        event.vault_admin_cap_id,
        event.release_admin_cap_id,
        event.vault_active,
        event.authorized_before,
        event.authorized_after,
        event.authorized_plugin_count_before,
        event.authorized_plugin_count_after,
    )
}
