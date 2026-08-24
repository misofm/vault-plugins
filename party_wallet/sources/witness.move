// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module party_wallet::witness;

/// Canonical package witness used to authorize this plugin on a Vault.
public struct Witness() has drop;

/// Only modules in this package can construct the plugin witness.
public(package) fun new(): Witness {
    Witness()
}
