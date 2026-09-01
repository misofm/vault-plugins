// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module recording_royalty_pool_plugin::witness;

public struct Witness() has drop;

public(package) fun new(): Witness {
    Witness()
}
