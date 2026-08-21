// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Canonical installation identity for the Composition routed-stake plugin.
module composition_routed_stake::witness;

public struct Witness() has drop;

public(package) fun new(): Witness {
    Witness()
}
