//===----------------------------------------------------------------------===//
//
// This source file is part of the StateManagement package open source project
//
// Copyright (c) 2025-2035 Maxim Bazarov and the StateManagement package
// open source project authors
// Licensed under MIT
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

#if DEBUG
import Foundation

extension SharedEnvironment {
    /// Creates a fresh ``SharedEnvironment`` and applies the builder’s operations in one
    /// `perform(_:file:line:)` (single notify). Empty builders skip `perform`.
    ///
    /// DEBUG only. Use for previews and tests.
    public static func seeded(
        @SeedOperationsBuilder _ operations: () -> [any SyncOperation]
    ) -> SharedEnvironment {
        let env = SharedEnvironment()
        env.seed(operations)
        return env
    }

    /// Applies the builder’s operations to this Environment in one `perform(_:file:line:)`
    /// (single notify). Empty builders skip `perform`.
    ///
    /// DEBUG only. Use for previews and tests. ``seeded(_:)`` is the factory that creates a
    /// fresh Environment and calls this.
    public func seed(
        @SeedOperationsBuilder _ operations: () -> [any SyncOperation]
    ) {
        let ops = operations()
        guard !ops.isEmpty else { return }
        perform(SeedBatch(operations: ops))
    }
}
#endif
