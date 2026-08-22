// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault-authorized control over Recording shares owned by a Composition.
///
/// The plugin redeems Recording shares held at the Composition address and
/// places them in a generic `routed_stake::RoutedStake`. The independently
/// shared wrapper prevents rewards from surfacing as freely claimable funds:
/// its permissionless `sweep` operation can route them only into the royalty
/// pool derived from the same Composition.
module composition_routed_stake::composition_routed_stake;

use composition_routed_stake::witness::{Self, Witness};
use hikida::hikida;
use miso::composition::{Composition, CompositionAdminCap};
use miso::recording::Recording;
use royalty_pool::pool::{Self, RoyaltyPool};
use routed_stake::routed_stake::{Self, RoutedStake};
use vault::vault::{Vault, VaultAdminCap};

// === Errors ===

/// The RoyaltyPool is not derived from the supplied Recording.
const EPoolNotForRecording: u64 = 0;
/// The VaultAdminCap belongs to another Vault.
const ENotVaultAdmin: u64 = 1;
/// The RoutedStake is not derived from the supplied Composition.
const EStakeNotForComposition: u64 = 2;
/// The Recording does not belong to the supplied Composition.
const ERecordingNotForComposition: u64 = 3;

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

// === Lifecycle ===

/// Redeem Composition-owned Recording shares, create the Composition-derived
/// routed stake, and share it. The Recording reference pins both share types
/// to a real Composition/Recording relationship.
entry fun create_stake<RecordingShare, CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    recording: &Recording<RecordingShare, CompositionShare>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
    value: u64,
    ctx: &mut TxContext,
) {
    assert_admin(vault, vault_admin_cap);
    assert!(
        recording.composition_id() == object::id(composition),
        ERecordingNotForComposition,
    );
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let uid = composition.uid_mut(&cap);
    let shares = hikida::redeem_balance<RecordingShare>(uid, value);
    let routed = routed_stake::new<RecordingShare, CompositionShare>(uid, shares, ctx);
    vault.put_back(cap, receipt);
    routed_stake::share(routed)
}

/// Register the routed stake with the canonical pool derived from the supplied
/// Recording. The Vault administrator controls which currencies are enabled.
entry fun register<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    recording: &Recording<RecordingShare, CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    assert_admin(vault, vault_admin_cap);
    assert_stake_for_composition(routed, object::id(composition));
    assert_pool_for_recording(pool, object::id(recording));
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    routed.register(composition.uid_mut(&cap), pool);
    vault.put_back(cap, receipt)
}

/// Unregister the routed stake after its pending reward has been swept.
entry fun unregister<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    recording: &Recording<RecordingShare, CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    assert_admin(vault, vault_admin_cap);
    assert_stake_for_composition(routed, object::id(composition));
    assert_pool_for_recording(pool, object::id(recording));
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    routed.unregister(composition.uid_mut(&cap), pool);
    vault.put_back(cap, receipt)
}

/// Remove the routed position and return its principal to the Composition
/// address. Principal never becomes a caller-controlled Coin or Balance.
entry fun unstake<RecordingShare, CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    assert_admin(vault, vault_admin_cap);
    let composition_id = object::id(composition);
    assert_stake_for_composition(routed, composition_id);
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let shares = routed.unstake(composition.uid_mut(&cap));
    vault.put_back(cap, receipt);
    shares.send_funds(composition_id.to_address())
}

/// Refill an empty routed stake from Recording shares held at the Composition
/// address.
entry fun restake<RecordingShare, CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
    value: u64,
    ctx: &mut TxContext,
) {
    assert_admin(vault, vault_admin_cap);
    assert_stake_for_composition(routed, object::id(composition));
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let uid = composition.uid_mut(&cap);
    let shares = hikida::redeem_balance<RecordingShare>(uid, value);
    routed.restake(uid, shares, ctx);
    vault.put_back(cap, receipt)
}

// === Views ===

public fun is_installed<CompositionShare>(
    vault: &Vault<CompositionAdminCap<CompositionShare>>,
): bool {
    vault.is_plugin_authorized<CompositionAdminCap<CompositionShare>, Witness>()
}

/// Canonical routed-stake address for this Composition and RecordingShare.
public fun stake_address<RecordingShare, CompositionShare>(
    composition: &Composition<CompositionShare>,
): address {
    routed_stake::derived_address<RecordingShare>(object::id(composition))
}

// === Private helpers ===

fun assert_admin<CompositionShare>(
    vault: &Vault<CompositionAdminCap<CompositionShare>>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    assert!(object::id(vault) == vault_admin_cap.vault_id(), ENotVaultAdmin)
}

fun assert_pool_for_recording<RecordingShare, Currency>(
    pool: &RoyaltyPool<RecordingShare, Currency>,
    recording_id: ID,
) {
    assert!(
        object::id(pool).to_address() == pool::derived_address<RecordingShare, Currency>(recording_id),
        EPoolNotForRecording,
    )
}

fun assert_stake_for_composition<RecordingShare, CompositionShare>(
    routed: &RoutedStake<RecordingShare, CompositionShare>,
    composition_id: ID,
) {
    assert!(
        object::id(routed).to_address() == routed_stake::derived_address<RecordingShare>(composition_id),
        EStakeNotForComposition,
    )
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
public fun create_stake_for_testing<RecordingShare, CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    recording: &Recording<RecordingShare, CompositionShare>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
    value: u64,
    ctx: &mut TxContext,
) {
    create_stake(vault, composition, recording, vault_admin_cap, value, ctx)
}

#[test_only]
public fun register_for_testing<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    recording: &Recording<RecordingShare, CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    register(vault, composition, recording, routed, pool, vault_admin_cap)
}

#[test_only]
public fun unregister_for_testing<RecordingShare, CompositionShare, Currency>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    recording: &Recording<RecordingShare, CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    unregister(vault, composition, recording, routed, pool, vault_admin_cap)
}

#[test_only]
public fun unstake_for_testing<RecordingShare, CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
) {
    unstake(vault, composition, routed, vault_admin_cap)
}

#[test_only]
public fun restake_for_testing<RecordingShare, CompositionShare>(
    vault: &mut Vault<CompositionAdminCap<CompositionShare>>,
    composition: &mut Composition<CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    vault_admin_cap: &VaultAdminCap<CompositionAdminCap<CompositionShare>>,
    value: u64,
    ctx: &mut TxContext,
) {
    restake(vault, composition, routed, vault_admin_cap, value, ctx)
}
