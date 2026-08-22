// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Test-only share type satisfying the `miso_share` issuance gates
/// (`<pkg>::share::Share`), so fixtures can issue recordings through the
/// production `recording::new` path with a real fixed-supply currency.
/// `coin_registry::new_currency` is internal-gated, so the type and the
/// bootstrap helper must live in this defining module.
#[test_only]
module recording_royalty_pool::share;

use sui::coin::TreasuryCap;
use sui::coin_registry::{Self, Currency};

public struct Share has key { id: UID }

/// Run the production currency issuance flow: register the currency, delete
/// the metadata cap, and return the currency with its treasury cap.
/// Requires a system (@0x0) sender context.
public fun bootstrap_currency(ctx: &mut TxContext): (Currency<Share>, TreasuryCap<Share>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (initializer, treasury_cap) = registry.new_currency<Share>(
        6,
        b"SHR".to_string(),
        b"Share".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );
    let (mut currency, metadata_cap) =
        coin_registry::finalize_unwrap_for_testing(initializer, ctx);
    currency.delete_metadata_cap(metadata_cap);
    std::unit_test::destroy(registry);
    (currency, treasury_cap)
}
