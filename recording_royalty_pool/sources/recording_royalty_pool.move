// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault-authorized royalty-pool business logic for Miso Recordings.
///
/// The plugin temporarily leases the RecordingAdminCap from its Vault, uses
/// it only to reach the matching Recording UID, and returns it before calling
/// external pool logic. Pools remain derived from the Recording, not the
/// Vault, so their canonical identity survives vault replacement.
module recording_royalty_pool::recording_royalty_pool;

use hikida::hikida;
use miso::recording::{Recording, RecordingAdminCap};
use recording_royalty_pool::witness::{Self, Witness};
use royalty_pool::pool::{Self, RoyaltyPool};
use sui::accumulator::AccumulatorRoot;
use sui::coin::Coin;
use sui::transfer::Receiving;
use vault::vault::{Self, Vault, VaultAdminCap};

// === Errors ===

/// The VaultAdminCap belongs to another Vault.
const ENotVaultAdmin: u64 = 0;

/// No funds of the requested currency were settled for the Recording.
const ENoSettledFunds: u64 = 1;

// === Installation ===

/// Authorize this package on a Recording capability Vault.
public fun install<RecordingShare>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new())
}

/// Revoke this package from a Recording capability Vault.
public fun uninstall<RecordingShare>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    vault.revoke_plugin<RecordingAdminCap<RecordingShare>, Witness>(vault_admin_cap)
}

// === Privileged plugin operations ===

/// Create and share the canonical pool derived from this Recording.
///
/// The matching VaultAdminCap chooses which Currency pools may be created.
/// The result cannot be redirected: the pool ID is claimed from the Recording
/// UID and is typed by both RecordingShare and Currency.
public fun initialize_pool<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    assert_admin(vault, vault_admin_cap);
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let pool = pool::new<RecordingShare, Currency>(recording.uid_mut(&cap));
    vault.put_back(cap, receipt);
    pool.share();
}

/// Receive coins sent to the Recording and deposit them into its canonical
/// pool. Anyone may crank this after the plugin is installed, but the funds
/// can only reach the pool derived from this Recording.
public fun receive_and_deposit<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    pool.assert_derived_from(object::id(recording));
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let balance = hikida::receive_balance(recording.uid_mut(&cap), coins);
    vault.put_back(cap, receipt);
    pool.deposit(balance);
}

/// Redeem the settled `Currency` amount reported for the Recording address
/// and deposit it into the canonical pool. Anyone may crank this after
/// installation.
///
/// Funds sent during the current consensus commit are not yet settled and
/// remain available for a later sweep. Aborts with `ENoSettledFunds` when the
/// settled amount is zero. The framework caps the reported amount at
/// `u64::MAX`; any excess remains for a later sweep.
public fun sweep_and_deposit<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    root: &AccumulatorRoot,
) {
    pool.assert_derived_from(object::id(recording));
    let value = sui::balance::settled_funds_value<Currency>(
        root,
        object::id(recording).to_address(),
    );
    assert!(value > 0, ENoSettledFunds);
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let balance = hikida::redeem_balance<Currency>(recording.uid_mut(&cap), value);
    vault.put_back(cap, receipt);
    pool.deposit(balance);
}

// === Views ===

public fun is_installed<RecordingShare>(
    vault: &Vault<RecordingAdminCap<RecordingShare>>,
): bool {
    vault.is_plugin_authorized<RecordingAdminCap<RecordingShare>, Witness>()
}

/// The canonical pool address for this Recording, share type, and Currency.
public fun pool_address<RecordingShare, CompositionShare, Currency>(
    recording: &Recording<RecordingShare, CompositionShare>,
): address {
    pool::derived_address<RecordingShare, Currency>(object::id(recording))
}

// === Private helpers ===

fun assert_admin<RecordingShare>(
    vault: &Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    assert!(object::id(vault) == vault_admin_cap.vault_id(), ENotVaultAdmin)
}

// === Test helpers ===

#[test_only]
public fun install_for_testing<RecordingShare>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    install(vault, vault_admin_cap)
}

#[test_only]
public fun uninstall_for_testing<RecordingShare>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    uninstall(vault, vault_admin_cap)
}

#[test_only]
public fun initialize_pool_for_testing<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    vault_admin_cap: &VaultAdminCap<RecordingAdminCap<RecordingShare>>,
) {
    initialize_pool<RecordingShare, CompositionShare, Currency>(
        vault,
        recording,
        vault_admin_cap,
    )
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
public fun sweep_and_deposit_for_testing<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<RecordingAdminCap<RecordingShare>>,
    recording: &mut Recording<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    root: &AccumulatorRoot,
) {
    sweep_and_deposit(vault, recording, pool, root)
}
