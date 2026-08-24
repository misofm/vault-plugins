// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault-authorized release revenue routing for Miso.
///
/// Revenue is split from the immutable Release tracklist and sent to each
/// track's Recording address. A caller can select only the funds to receive or
/// the amount to redeem; it cannot select recipients or alter split amounts.
/// Recording-level plugins may subsequently fold those funds into canonical
/// Recording royalty pools.
module release_revenue_distributor::release_revenue_distributor;

use hikida::hikida;
use miso::release::{Release, ReleaseAdminCap};
use release_revenue_distributor::witness::{Self, Witness};
use sui::balance::Balance;
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;
use vault::vault::{Vault, VaultAdminCap};

// === Events ===

/// Emitted for every Release track, including a zero-value rounded split.
public struct ReleaseTrackRevenueDistributedEvent<phantom Currency> has copy, drop {
    release_id: ID,
    track_index: u64,
    recording_id: ID,
    amount: u64,
}

/// Emitted once after an entire Release distribution completes.
public struct ReleaseRevenueDistributedEvent<phantom Currency> has copy, drop {
    release_id: ID,
    total_input: u64,
    total_distributed: u64,
    remainder: u64,
}

// === Installation ===

/// Authorize this package on a Release capability Vault.
public fun install(
    vault: &mut Vault<ReleaseAdminCap>,
    vault_admin_cap: &VaultAdminCap<ReleaseAdminCap>,
) {
    vault.authorize_plugin(vault_admin_cap, witness::new())
}

/// Revoke this package from a Release capability Vault.
public fun uninstall(
    vault: &mut Vault<ReleaseAdminCap>,
    vault_admin_cap: &VaultAdminCap<ReleaseAdminCap>,
) {
    vault.revoke_plugin<ReleaseAdminCap, Witness>(vault_admin_cap)
}

// === Distribution ===

/// Redeem `value` from the Release address and distribute it according to the
/// immutable tracklist. Anyone may crank this after installation.
public fun redeem_and_distribute<Currency>(
    vault: &mut Vault<ReleaseAdminCap>,
    release: &mut Release,
    value: u64,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let revenue = hikida::redeem_balance<Currency>(release.uid_mut(&cap), value);
    vault.put_back(cap, receipt);
    distribute(release, revenue)
}

/// Receive selected `Coin<Currency>` objects sent to the Release and
/// distribute their combined value according to the immutable tracklist.
/// Anyone may crank this after installation.
public fun receive_and_distribute<Currency>(
    vault: &mut Vault<ReleaseAdminCap>,
    release: &mut Release,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    let (cap, receipt) = vault.borrow_as_plugin(witness::new());
    let revenue = hikida::receive_balance(release.uid_mut(&cap), coins);
    vault.put_back(cap, receipt);
    distribute(release, revenue)
}

// === Views ===

public fun is_installed(vault: &Vault<ReleaseAdminCap>): bool {
    vault.is_plugin_authorized<ReleaseAdminCap, Witness>()
}

// === Private helpers ===

/// Route a balance using only immutable Release data. Because every Release's
/// track splits sum to 10,000 BPS, only per-track flooring can remain; that
/// remainder is returned to the Release address for a later distribution.
fun distribute<Currency>(release: &Release, mut revenue: Balance<Currency>) {
    let release_id = object::id(release);
    let total_input = revenue.value();
    let mut total_distributed = 0;
    let mut track_index = 0;

    release.tracks().do_ref!(|track| {
        let amount = track.split_bps().apply(total_input);
        total_distributed = total_distributed + amount;
        if (amount > 0) {
            revenue.split(amount).send_funds(track.recording_id().to_address());
        };
        emit(ReleaseTrackRevenueDistributedEvent<Currency> {
            release_id,
            track_index,
            recording_id: track.recording_id(),
            amount,
        });
        track_index = track_index + 1;
    });

    let remainder = revenue.value();
    if (remainder > 0) {
        revenue.send_funds(release_id.to_address());
    } else {
        revenue.destroy_zero();
    };

    emit(ReleaseRevenueDistributedEvent<Currency> {
        release_id,
        total_input,
        total_distributed,
        remainder,
    });
}

// === Test helpers ===

#[test_only]
public fun install_for_testing(
    vault: &mut Vault<ReleaseAdminCap>,
    vault_admin_cap: &VaultAdminCap<ReleaseAdminCap>,
) {
    install(vault, vault_admin_cap)
}

#[test_only]
public fun uninstall_for_testing(
    vault: &mut Vault<ReleaseAdminCap>,
    vault_admin_cap: &VaultAdminCap<ReleaseAdminCap>,
) {
    uninstall(vault, vault_admin_cap)
}

#[test_only]
public fun redeem_and_distribute_for_testing<Currency>(
    vault: &mut Vault<ReleaseAdminCap>,
    release: &mut Release,
    value: u64,
) {
    redeem_and_distribute<Currency>(vault, release, value)
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
public fun track_event_fields<Currency>(
    event: &ReleaseTrackRevenueDistributedEvent<Currency>,
): (ID, u64, ID, u64) {
    (event.release_id, event.track_index, event.recording_id, event.amount)
}

#[test_only]
public fun distribution_event_fields<Currency>(
    event: &ReleaseRevenueDistributedEvent<Currency>,
): (ID, u64, u64, u64) {
    (event.release_id, event.total_input, event.total_distributed, event.remainder)
}
