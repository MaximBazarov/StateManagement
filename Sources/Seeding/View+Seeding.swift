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

#if canImport(SwiftUI) && DEBUG
import SwiftUI

extension View {
    /// Creates a fresh ``SharedEnvironment``, seeds it with the builder’s operations, and
    /// injects it for this view subtree.
    ///
    /// DEBUG only. Prefer named operations in production code.
    public func seedEnvironment(
        @SeedOperationsBuilder _ operations: () -> [any SyncOperation]
    ) -> some View {
        sharedEnvironment(.seeded(operations))
    }
}
#endif
