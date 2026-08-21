// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Canonical installation identity for the release revenue distributor.
module release_revenue_distributor::witness;

public struct Witness() has drop;

public(package) fun new(): Witness {
    Witness()
}
