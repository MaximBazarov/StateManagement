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

/// DEBUG helper that writes one value through ``SyncOperationEnvironment/write(_:keyPath:)``
/// or one dictionary entry through ``SyncOperationEnvironment/write(_:keyPath:key:)``.
///
/// Prefer named operations in production code. Use ``Write`` in previews and tests with
/// ``SharedEnvironment/seeded(_:)`` or ``SwiftUI/View/seedEnvironment(_:)``.
@MainActor public struct Write<Storage: StateContainer, Value>: SyncOperation {
    private let apply: (SyncOperationEnvironment) -> Void

    /// Writes a whole value at `keyPath`.
    public init(_ keyPath: WritableKeyPath<Storage, Value>, _ value: Value) {
        apply = { env in
            env.write(value, keyPath: keyPath)
        }
    }

    /// Writes one dictionary entry at `keyPath[key]`.
    public init<Key: Hashable>(
        _ keyPath: WritableKeyPath<Storage, [Key: Value]>,
        key: Key,
        _ value: Value
    ) {
        apply = { env in
            env.write(value, keyPath: keyPath, key: key)
        }
    }

    public func perform(in env: SyncOperationEnvironment) {
        apply(env)
    }
}
#endif
