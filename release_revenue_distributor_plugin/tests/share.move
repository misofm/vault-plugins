// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Test-only fixed-supply share currency for the end-to-end pipeline.
#[test_only]
module release_revenue_distributor_plugin::share;

use sui::balance::Balance;
use sui::coin_registry::{Self, Currency};

public struct Share has key { id: UID }

public fun bootstrap_currency(ctx: &mut TxContext): (Currency<Share>, Balance<Share>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (initializer, mut treasury_cap) = registry.new_currency<Share>(
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
    let supply = treasury_cap.mint_balance(100_000_000_000_000);
    currency.make_supply_fixed(treasury_cap);
    std::unit_test::destroy(registry);
    (currency, supply)
}
