// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_royalty_pool_plugin::recording_royalty_pool_plugin_funds_event_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::test_helpers;
use recording_royalty_pool::recording_royalty_pool as action;
use recording_royalty_pool_plugin::recording_royalty_pool_plugin as plugin;
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::event;
use recording_royalty_pool_plugin::witness::Witness;
use sui::test_scenario;
use vault::vault::{Self, Vault, VaultAdminCap};

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

/// The borrow -> Action -> put_back sequence with a
/// positive settled value: exact before/after pool metrics, restored custody,
/// and `amount` equal to the settled snapshot.
#[test]
fun redeem_event_snapshots_funds_and_restored_custody() {
    let ctx = &mut tx_context::dummy();
    let (mut r, mut v, a) = make(ctx);
    let rid = object::id(&r);
    let cid = recording::composition_id(&r);
    let capid = v.cap_id();
    let mut p = pool(&mut r, &mut v, &a);
    let pid = object::id(&p);
    let mut st = stake::new(balance::create_for_testing<SHARE>(100), ctx);
    p.register_stake(&mut st);
    plugin::install(&mut v, &a);
    balance::create_for_testing<CURRENCY>(333).send_funds(rid.to_address());

    let b0 = p.balance().value();
    let q0 = p.staked_shares();
    let r0 = p.cumulative_reward_per_share();
    let k0 = p.carry();
    let d0 = p.cumulative_deposits();
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_settled_value_and_deposit_for_testing(&mut v, &mut r, &mut p, 333);
    assert_eq!(event::num_events() - event_count_before, 3);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    let b1 = p.balance().value();
    let r1 = p.cumulative_reward_per_share();
    let k1 = p.carry();
    let d1 = p.cumulative_deposits();

    let es = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>();
    assert_eq!(es.length(), 1);
    let (x, y, b, c) = vault::capability_borrowed_by_plugin_event_fields(&es[0]);
    assert_eq!(x, object::id(&v).to_address());
    assert_eq!(y, capid.to_address());
    assert!(b);
    assert!(!c);

    let es = event::events_by_type<action::RecordingFundsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>();
    assert_eq!(es.length(), 1);
    let (z, w, y, q, ac, a0, a1, a2, a3, a4, a5, a6, a7, a8) = action::funds_deposited_event_fields(&es[0]);
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
    assert_eq!(ac, 333);

    let reward = p.claim_rewards(&mut st);
    assert_eq!(reward.value(), 333);
    p.unregister_stake(&mut st);
    balance::destroy_for_testing(stake::destroy(st));
    balance::destroy_for_testing(reward);
    plugin::uninstall(&mut v, &a);
    destroy(p);
    clean(r, v, a);
}

/// A zero settled snapshot through the real entry: the cap is leased and
/// returned (generic borrow and return events only), nothing is deposited, no funds event.
#[test]
fun zero_snapshot_crank_emits_only_custody_events() {
    let mut s = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(s.ctx());
    s.next_tx(@0xA);
    let (mut r, mut v, a) = make(s.ctx());
    let mut p = pool(&mut r, &mut v, &a);
    let mut st = stake::new(balance::create_for_testing<SHARE>(100), s.ctx());
    p.register_stake(&mut st);
    plugin::install(&mut v, &a);

    s.next_tx(@0x51);
    let root = s.take_shared<AccumulatorRoot>();
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_all_and_deposit_for_testing(&mut v, &mut r, &mut p, &root);
    assert_eq!(event::num_events() - event_count_before, 1);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_all_and_deposit_for_testing(&mut v, &mut r, &mut p, &root);
    assert_eq!(event::num_events() - event_count_before, 1);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), 2);
    assert_eq!(event::events_by_type<action::RecordingFundsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>().length(), 0);
    assert_eq!(event::events_by_type<pool::RoyaltyDepositedEvent<SHARE, CURRENCY>>().length(), 0);
    assert_eq!(p.cumulative_deposits(), 0);
    let (c, b) = v.borrow_as_admin(&a);
    v.put_back(c, b);
    test_scenario::return_shared(root);

    p.unregister_stake(&mut st);
    balance::destroy_for_testing(stake::destroy(st));
    plugin::uninstall(&mut v, &a);
    destroy(p);
    clean(r, v, a);
    s.end();
}

/// With no registered stake the crank leases and returns the cap but redeems
/// nothing; once a stake registers the same funds are deposited and reported.
#[test]
fun zero_staker_crank_is_a_no_op_until_a_stake_registers() {
    let ctx = &mut tx_context::dummy();
    let (mut r, mut v, a) = make(ctx);
    let rid = object::id(&r);
    let mut p = pool(&mut r, &mut v, &a);
    plugin::install(&mut v, &a);
    balance::create_for_testing<CURRENCY>(333).send_funds(rid.to_address());

    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_settled_value_and_deposit_for_testing(&mut v, &mut r, &mut p, 333);
    assert_eq!(event::num_events() - event_count_before, 1);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), 1);
    assert_eq!(event::events_by_type<action::RecordingFundsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>().length(), 0);
    assert_eq!(p.cumulative_deposits(), 0);
    assert_eq!(p.balance().value(), 0);

    let mut st = stake::new(balance::create_for_testing<SHARE>(100), ctx);
    p.register_stake(&mut st);
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_settled_value_and_deposit_for_testing(&mut v, &mut r, &mut p, 333);
    assert_eq!(event::num_events() - event_count_before, 3);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    let es = event::events_by_type<action::RecordingFundsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>();
    assert_eq!(es.length(), 1);
    let (_, _, _, _, amount, b0, b1, q, _, _, _, _, d0, d1) = action::funds_deposited_event_fields(&es[0]);
    assert_eq!(b0, 0);
    assert_eq!(b1, 333);
    assert_eq!(q, 100);
    assert_eq!(d0, 0);
    assert_eq!(d1, 333);
    assert_eq!(amount, 333);
    let reward = p.claim_rewards(&mut st);
    assert_eq!(reward.value(), 333);

    p.unregister_stake(&mut st);
    balance::destroy_for_testing(stake::destroy(st));
    balance::destroy_for_testing(reward);
    plugin::uninstall(&mut v, &a);
    destroy(p);
    clean(r, v, a);
}

/// Batch safety through the plugin: three recordings in one transaction, one
/// with a zero snapshot and one with no stakers; only the funded, staked one
/// deposits, and every vault gets its cap back.
#[test]
fun batch_with_no_op_items_still_deposits_the_funded_staked_recording() {
    let mut s = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(s.ctx());
    s.next_tx(@0xA);
    let (mut ra, mut va, aa) = make(s.ctx());
    let (mut rb, mut vb, ab) = make(s.ctx());
    let (mut rc, mut vc, ac) = make(s.ctx());
    let mut pa = pool(&mut ra, &mut va, &aa);
    let mut pb = pool(&mut rb, &mut vb, &ab);
    let mut pc = pool(&mut rc, &mut vc, &ac);
    let mut sa = stake::new(balance::create_for_testing<SHARE>(10), s.ctx());
    let mut sb = stake::new(balance::create_for_testing<SHARE>(10), s.ctx());
    pa.register_stake(&mut sa);
    pb.register_stake(&mut sb);
    plugin::install(&mut va, &aa);
    plugin::install(&mut vb, &ab);
    plugin::install(&mut vc, &ac);
    balance::create_for_testing<CURRENCY>(1_000).send_funds(object::id(&ra).to_address());
    balance::create_for_testing<CURRENCY>(250).send_funds(object::id(&rc).to_address());

    s.next_tx(@0x51);
    let root = s.take_shared<AccumulatorRoot>();
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_settled_value_and_deposit_for_testing(&mut va, &mut ra, &mut pa, 1_000);
    assert_eq!(event::num_events() - event_count_before, 3);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_all_and_deposit_for_testing(&mut vb, &mut rb, &mut pb, &root);
    assert_eq!(event::num_events() - event_count_before, 1);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_settled_value_and_deposit_for_testing(&mut vc, &mut rc, &mut pc, 250);
    assert_eq!(event::num_events() - event_count_before, 1);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    let es = event::events_by_type<action::RecordingFundsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>();
    assert_eq!(es.length(), 1);
    let (z, _, _, q, amount, _, _, _, _, _, _, _, _, _) = action::funds_deposited_event_fields(&es[0]);
    assert_eq!(z, object::id(&ra).to_address());
    assert_eq!(q, object::id(&pa).to_address());
    assert_eq!(amount, 1_000);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), 3);
    assert_eq!(pa.cumulative_deposits(), 1_000);
    assert_eq!(pb.cumulative_deposits(), 0);
    assert_eq!(pc.cumulative_deposits(), 0);
    test_scenario::return_shared(root);

    let (c, b) = va.borrow_as_admin(&aa);
    va.put_back(c, b);
    let (c, b) = vb.borrow_as_admin(&ab);
    vb.put_back(c, b);
    let (c, b) = vc.borrow_as_admin(&ac);
    vc.put_back(c, b);
    let reward = pa.claim_rewards(&mut sa);
    assert_eq!(reward.value(), 1_000);
    pa.unregister_stake(&mut sa);
    pb.unregister_stake(&mut sb);
    balance::destroy_for_testing(stake::destroy(sa));
    balance::destroy_for_testing(stake::destroy(sb));
    balance::destroy_for_testing(reward);
    plugin::uninstall(&mut va, &aa);
    plugin::uninstall(&mut vb, &ab);
    plugin::uninstall(&mut vc, &ac);
    destroy(pa);
    destroy(pb);
    destroy(pc);
    clean(ra, va, aa);
    clean(rb, vb, ab);
    clean(rc, vc, ac);
    s.end();
}

/// Two cranks of the same object in ONE transaction re-redeem the same
/// snapshot in the unit VM. On the network the second withdrawal exceeds the
/// settled balance and the whole transaction fails with
/// `InsufficientFundsForWithdraw`; batched crankers must dedupe objects per
/// PTB. Pins that the plugin has no in-transaction dedupe either.
#[test]
fun duplicate_crank_in_one_tx_is_not_a_no_op() {
    let ctx = &mut tx_context::dummy();
    let (mut r, mut v, a) = make(ctx);
    let mut p = pool(&mut r, &mut v, &a);
    let mut st = stake::new(balance::create_for_testing<SHARE>(100), ctx);
    p.register_stake(&mut st);
    plugin::install(&mut v, &a);
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_settled_value_and_deposit_for_testing(&mut v, &mut r, &mut p, 333);
    assert_eq!(event::num_events() - event_count_before, 3);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_settled_value_and_deposit_for_testing(&mut v, &mut r, &mut p, 333);
    assert_eq!(event::num_events() - event_count_before, 3);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    assert_eq!(p.cumulative_deposits(), 666);
    assert_eq!(event::events_by_type<action::RecordingFundsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>().length(), 2);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), 2);
    balance::destroy_for_testing(p.claim_rewards(&mut st));
    p.unregister_stake(&mut st);
    balance::destroy_for_testing(stake::destroy(st));
    plugin::uninstall(&mut v, &a);
    destroy(p);
    clean(r, v, a);
}

/// The action event's `amount` is the pool's cumulative-deposit delta, so it
/// always equals what the pool actually received from the Action.
#[test]
fun deposit_event_amount_matches_pool_delta() {
    let ctx = &mut tx_context::dummy();
    let (mut r, mut v, a) = make(ctx);
    let mut p = pool(&mut r, &mut v, &a);
    let mut st = stake::new(balance::create_for_testing<SHARE>(7), ctx);
    p.register_stake(&mut st);
    plugin::install(&mut v, &a);
    let before = p.cumulative_deposits();
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_settled_value_and_deposit_for_testing(&mut v, &mut r, &mut p, 1_000_003);
    assert_eq!(event::num_events() - event_count_before, 3);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    let es = event::events_by_type<action::RecordingFundsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>();
    assert_eq!(es.length(), 1);
    let (_, _, _, _, amount, _, _, _, _, _, _, _, d0, d1) = action::funds_deposited_event_fields(&es[0]);
    assert_eq!(d0, before);
    assert_eq!(d1 - d0, amount as u128);
    assert_eq!(amount, 1_000_003);
    assert_eq!(p.cumulative_deposits() - before, 1_000_003);
    let pool_events = event::events_by_type<pool::RoyaltyDepositedEvent<SHARE, CURRENCY>>();
    assert_eq!(pool_events.length(), 1);
    let (_, value, _, _, _, _, _, _, _) = pool::deposited_event_fields(&pool_events[0]);
    assert_eq!(value, amount);
    balance::destroy_for_testing(p.claim_rewards(&mut st));
    p.unregister_stake(&mut st);
    balance::destroy_for_testing(stake::destroy(st));
    plugin::uninstall(&mut v, &a);
    destroy(p);
    clean(r, v, a);
}

/// The framework caps the settled snapshot at `u64::MAX`; the plugin path
/// must not abort at the cap and must report it exactly.
#[test]
fun u64_max_snapshot_through_the_plugin_deposits_without_abort() {
    let ctx = &mut tx_context::dummy();
    let (mut r, mut v, a) = make(ctx);
    let mut p = pool(&mut r, &mut v, &a);
    let mut st = stake::new(balance::create_for_testing<SHARE>(100), ctx);
    p.register_stake(&mut st);
    plugin::install(&mut v, &a);
    let max = std::u64::max_value!();
    let event_count_before = event::num_events();
    let borrow_count_before = event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length();
    plugin::redeem_settled_value_and_deposit_for_testing(&mut v, &mut r, &mut p, max);
    assert_eq!(event::num_events() - event_count_before, 3);
    assert_eq!(event::events_by_type<vault::VaultCapabilityBorrowedByPluginEvent<RecordingAdminCap<SHARE>, Witness>>().length(), borrow_count_before + 1);
    let es = event::events_by_type<action::RecordingFundsDepositedEvent<SHARE, COMPOSITION_SHARE, CURRENCY>>();
    assert_eq!(es.length(), 1);
    let (_, _, _, _, amount, b0, b1, _, _, _, _, _, d0, d1) = action::funds_deposited_event_fields(&es[0]);
    assert_eq!(amount, max);
    assert_eq!(b0, 0);
    assert_eq!(b1, max);
    assert_eq!(d0, 0);
    assert_eq!(d1, max as u128);
    let reward = p.claim_rewards(&mut st);
    assert_eq!(reward.value(), max);
    balance::destroy_for_testing(reward);
    p.unregister_stake(&mut st);
    balance::destroy_for_testing(stake::destroy(st));
    plugin::uninstall(&mut v, &a);
    destroy(p);
    clean(r, v, a);
}
