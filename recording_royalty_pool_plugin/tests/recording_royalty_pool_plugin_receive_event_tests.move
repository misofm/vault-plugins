// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_royalty_pool_plugin::recording_royalty_pool_plugin_receive_event_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::test_helpers;
use recording_royalty_pool::recording_royalty_pool as action;
use recording_royalty_pool_plugin::recording_royalty_pool_plugin as plugin;
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;
use vault::vault::{Self, Vault, VaultAdminCap};

const STRANGER: address = @0x51;

public struct SHARE() has drop;
public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

fun make(ctx: &mut TxContext): (
    Recording<SHARE, COMPOSITION_SHARE>,
    Vault<RecordingAdminCap<SHARE>>,
    VaultAdminCap<RecordingAdminCap<SHARE>>,
) {
    let (r, c) = recording::new_for_testing<SHARE, COMPOSITION_SHARE>(
        test_helpers::fake_id(ctx),
        ctx,
    );
    let mut reg = vault::new_registry_for_testing(ctx);
    let (v, a) = vault::new(&mut reg, c, ctx);
    destroy(reg);
    (r, v, a)
}

fun pool(
    r: &mut Recording<SHARE, COMPOSITION_SHARE>,
    v: &mut Vault<RecordingAdminCap<SHARE>>,
    a: &VaultAdminCap<RecordingAdminCap<SHARE>>,
): RoyaltyPool<SHARE, CURRENCY> {
    let (c, b) = v.borrow_as_admin(a);
    let p = action::new_pool<SHARE, COMPOSITION_SHARE, CURRENCY>(r, &c);
    v.put_back(c, b);
    p
}

fun clean(
    r: Recording<SHARE, COMPOSITION_SHARE>,
    mut v: Vault<RecordingAdminCap<SHARE>>,
    a: VaultAdminCap<RecordingAdminCap<SHARE>>,
) {
    let c = v.withdraw_cap(&a);
    destroy(a);
    destroy(v);
    destroy(c);
    destroy(r)
}

#[test]
fun direct_action_is_silent_and_receive_event_is_complete() {
    let mut s = test_scenario::begin(@0xA);
    let (mut r, mut v, a) = make(s.ctx());
    let rid = object::id(&r);
    let cid = recording::composition_id(&r);
    let capid = v.cap_id();
    let mut p = pool(&mut r, &mut v, &a);
    let pid = object::id(&p);
    let mut st = stake::new(balance::create_for_testing<SHARE>(100), s.ctx());
    p.register_stake(&mut st);

    let c = coin::from_balance(balance::create_for_testing<CURRENCY>(111), s.ctx());
    let id = object::id(&c);
    transfer::public_transfer(c, rid.to_address());
    s.next_tx(@0xA);
    let t = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(id);
    let (ac, br) = v.borrow_as_admin(&a);
    action::receive_and_deposit(&mut r, &ac, &mut p, vector[t]);
    v.put_back(ac, br);
    assert_eq!(event::events_by_type<plugin::RecordingVaultCapabilityBorrowedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>().length(), 0);
    assert_eq!(event::events_by_type<plugin::RecordingCoinsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>().length(), 0);
    assert_eq!(event::events_by_type<plugin::RecordingFundsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>().length(), 0);

    plugin::install(&mut v, &a);
    let z = coin::from_balance(balance::create_for_testing<CURRENCY>(0), s.ctx());
    let c = coin::from_balance(balance::create_for_testing<CURRENCY>(222), s.ctx());
    let zi = object::id(&z);
    let ci = object::id(&c);
    transfer::public_transfer(z, rid.to_address());
    transfer::public_transfer(c, rid.to_address());
    s.next_tx(STRANGER);
    let zt = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(zi);
    let ct = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(ci);
    let b0 = p.balance().value();
    let q0 = p.staked_shares();
    let r0 = p.cumulative_reward_per_share();
    let k0 = p.carry();
    let d0 = p.cumulative_deposits();
    plugin::receive_and_deposit_for_testing(&mut v, &mut r, &mut p, vector[zt, ct]);
    let b1 = p.balance().value();
    let r1 = p.cumulative_reward_per_share();
    let k1 = p.carry();
    let d1 = p.cumulative_deposits();

    let es = event::events_by_type<plugin::RecordingVaultCapabilityBorrowedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>();
    assert_eq!(es.length(), 1);
    let (x, y, z, w, q, b, c) = plugin::borrowed_event_fields(&es[0]);
    assert_eq!(x, object::id(&v).to_address());
    assert_eq!(y, capid.to_address());
    assert_eq!(z, rid.to_address());
    assert_eq!(w, cid.to_address());
    assert_eq!(q, pid.to_address());
    assert!(b);
    assert!(!c);

    let es = event::events_by_type<plugin::RecordingCoinsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>();
    assert_eq!(es.length(), 1);
    let (x, y, z, w, q, a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, ab, ac) = plugin::coins_deposited_event_fields(&es[0]);
    assert_eq!(x, object::id(&v).to_address());
    assert_eq!(y, capid.to_address());
    assert_eq!(z, rid.to_address());
    assert_eq!(w, cid.to_address());
    assert_eq!(q, pid.to_address());
    assert_eq!(a0, b0);
    assert_eq!(a1, b1);
    assert_eq!(a2, q0);
    assert_eq!(a3, r0);
    assert_eq!(a4, r1);
    assert_eq!(a5, k0);
    assert_eq!(a6, k1);
    assert_eq!(a7, d0);
    assert_eq!(a8, d1);
    assert!(a9);
    assert!(ab);
    assert_eq!(ac, vector[zi.to_address(), ci.to_address()]);

    let reward = p.claim_rewards(&mut st);
    assert_eq!(reward.value(), 333);
    p.unregister_stake(&mut st);
    balance::destroy_for_testing(stake::destroy(st));
    balance::destroy_for_testing(reward);
    plugin::uninstall(&mut v, &a);
    destroy(p);
    clean(r, v, a);
    s.end();
}
