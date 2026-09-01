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

/// Collects ``SyncOperation``s for ``SharedEnvironment/seeded(_:)``,
/// ``SharedEnvironment/seed(_:)``, and `SwiftUI.View.seedEnvironment(_:)`.
@resultBuilder
public enum SeedOperationsBuilder {
    public static func buildExpression(_ operation: any SyncOperation) -> [any SyncOperation] {
        [operation]
    }

    public static func buildBlock(_ components: [any SyncOperation]...) -> [any SyncOperation] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [any SyncOperation]?) -> [any SyncOperation] {
        component ?? []
    }

    public static func buildEither(first component: [any SyncOperation]) -> [any SyncOperation] {
        component
    }

    public static func buildEither(second component: [any SyncOperation]) -> [any SyncOperation] {
        component
    }

    public static func buildArray(_ components: [[any SyncOperation]]) -> [any SyncOperation] {
        components.flatMap { $0 }
    }
}

/// Runs child operations by calling ``SyncOperation/perform(in:)`` directly so one outer
/// ``SharedEnvironment/perform(_:file:line:)`` yields a single ``ObservationRegistry/notifyAll()``.
@MainActor
struct SeedBatch: SyncOperation {
    let operations: [any SyncOperation]

    func perform(in env: SyncOperationEnvironment) {
        for operation in operations {
            operation.perform(in: env)
        }
    }
}
#endif
