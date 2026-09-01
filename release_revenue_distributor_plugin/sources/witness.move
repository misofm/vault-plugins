// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module release_revenue_distributor_plugin::witness;

public struct Witness() has drop;

public(package) fun new(): Witness {
    Witness()
}
