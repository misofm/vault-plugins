// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault-authorized royalty-pool business logic for Miso Compositions.
///
/// The plugin temporarily leases the CompositionAdminCap from its Vault,
/// uses it only to reach the matching Composition UID, and returns it before
/// calling external pool logic. Pools remain derived from the Composition,
/// not the Vault, so their canonical identity survives vault replacement.
module composition_royalty_pool::composition_royalty_pool;

use composition_royalty_pool::witness::{Self, Witness};
use hikida::hikida;
use miso::composition::{Composition, CompositionAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use sui::coin::Coin;
use sui::transfer::Receiving;
use vault::vault::{Self, Vault, VaultAdminCap};

// === Errors ===

#[error]
const ENotVaultAdmin: vector<u8> = b"VaultAdminCap does not belong to this Vault";

// === Installation ===

/// Authorize this package on a Composition capability Vault.
entry fun install<CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new())
}

/// Revoke this package from a Composition capability Vault.
entry fun uninstall<CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    vault.revoke_plugin<CompositionAdminCap<CompositionShare>, Witness>(vault_admin_cap)
}

// === Privileged plugin operations ===

/// Create and share the canonical pool derived from this Composition.
///
/// The matching VaultAdminCap chooses which Currency pools may be created.
/// The result cannot be redirected: the pool ID is claimed from the
/// Composition UID and is typed by both CompositionShare and Currency.
entry fun initialize_pool<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    assert_admin(vault, vault_admin_cap);
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let pool = pool::new<CompositionShare, Currency>(composition.uid_mut(&cap));
    vault.put_back(cap, receipt);
    pool.share();
}

/// Receive coins sent to the Composition and deposit them into its canonical
/// pool. Anyone may crank this after the plugin is installed, but the funds
/// can only reach the pool derived from this Composition.
entry fun receive_and_deposit<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    pool.assert_derived_from(composition.id());
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let balance = hikida::receive_balance(composition.uid_mut(&cap), coins);
    vault.put_back(cap, receipt);
    pool.deposit(balance);
}

/// Redeem funds accumulated at the Composition address and deposit them into
/// its canonical pool. Anyone may crank this after installation.
entry fun redeem_and_deposit<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    value: u64,
) {
    pool.assert_derived_from(composition.id());
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let balance = hikida::redeem_balance<Currency>(composition.uid_mut(&cap), value);
    vault.put_back(cap, receipt);
    pool.deposit(balance);
}

// === Views ===

public fun is_installed<CompositionShare>(
    vault: &Vault<CompositionAdminCap<CompositionShare>>,
): bool {
    vault.is_plugin_authorized<CompositionAdminCap<CompositionShare>, Witness>()
}

/// The canonical pool address for this Composition, share type, and Currency.
public fun pool_address<CompositionShare, Currency>(
    composition: &Composition<CompositionShare>,
): address {
    pool::derived_address<CompositionShare, Currency>(composition.id())
}

// === Private helpers ===

fun assert_admin<CompositionShare>(
    vault: &Vault<CompositionAdminCap<CompositionShare>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    assert!(vault.id() == vault_admin_cap.vault_id(), ENotVaultAdmin)
}

// === Test helpers ===

#[test_only]
public fun install_for_testing<CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    install(vault, vault_admin_cap)
}

#[test_only]
public fun uninstall_for_testing<CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    uninstall(vault, vault_admin_cap)
}

#[test_only]
public fun initialize_pool_for_testing<CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    initialize_pool<CompositionShare, Currency>(vault, composition, vault_admin_cap)
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
