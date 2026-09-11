// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_royalty_pool_plugin::recording_royalty_pool_plugin_install_event_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use musicos::test_helpers;
use recording_royalty_pool_plugin::recording_royalty_pool_plugin as plugin;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use vault::vault::{Self, Vault, VaultAdminCap};

public struct SHARE() has drop;
public struct COMPOSITION_SHARE() has drop;

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
fun install_uninstall_events_and_silent_status() {
    let ctx = &mut tx_context::dummy();
    let (r, mut v, a) = make(ctx);
    let vi = object::id(&v).to_address();
    let ci = v.cap_id().to_address();
    let ai = object::id(&a).to_address();
    let pi = object::id(v.authorized_plugins()).to_address();

    assert!(!plugin::is_installed(&v));
    let n = event::num_events();
    assert!(!plugin::is_installed(&v));
    assert_eq!(event::num_events(), n);

    plugin::install(&mut v, &a);
    let es = event::events_by_type<plugin::RecordingRoyaltyPoolPluginInstalledEvent<SHARE>>();
    assert_eq!(es.length(), 1);
    let (x, y, z, w, q, b) = plugin::installed_event_fields(&es[0]);
    assert_eq!(x, vi);
    assert_eq!(y, ci);
    assert_eq!(z, ai);
    assert_eq!(w, pi);
    assert_eq!(q, 1);
    assert!(b);

    plugin::uninstall(&mut v, &a);
    let es = event::events_by_type<plugin::RecordingRoyaltyPoolPluginUninstalledEvent<SHARE>>();
    assert_eq!(es.length(), 1);
    let (x, y, z, w, q, b) = plugin::uninstalled_event_fields(&es[0]);
    assert_eq!(x, vi);
    assert_eq!(y, ci);
    assert_eq!(z, ai);
    assert_eq!(w, pi);
    assert_eq!(q, 0);
    assert!(!b);
    assert!(!plugin::is_installed(&v));

    clean(r, v, a);
}
