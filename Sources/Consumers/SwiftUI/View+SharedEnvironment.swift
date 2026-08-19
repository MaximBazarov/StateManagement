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

#if canImport(SwiftUI)
import Foundation
import SwiftUI

import SwiftUI

private struct SharedEnvironment_SwiftUIEnvironmentKey: @MainActor EnvironmentKey {
    @MainActor static let defaultValue: SharedEnvironment = .shared
}

extension EnvironmentValues {

    /// Instance of the ``SharedEnvironment`` in the SwiftUI View environment.
    @MainActor public var sharedEnvironment: SharedEnvironment {
        get { self[SharedEnvironment_SwiftUIEnvironmentKey.self] }
        set { self[SharedEnvironment_SwiftUIEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Overrides ``SharedEnvironment`` in the view environment`.
    public func sharedEnvironment(_ value: SharedEnvironment) -> some View {
        environment(\.sharedEnvironment, value)
    }

    #if DEBUG
    /// Creates a fresh ``SharedEnvironment``, seeds it with the builder’s operations, and
    /// injects it for this view subtree.
    ///
    /// DEBUG only. Prefer named operations in production code.
    public func seedEnvironment(
        @SeedOperationsBuilder _ operations: () -> [any SyncOperation]
    ) -> some View {
        sharedEnvironment(.seeded(operations))
    }
    #endif
}
#endif
