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


import Foundation

/// Convenience sync operation that mutates values calling the provided closure
/// with a value and ``SyncOperationEnvironment``.
///
/// Use it only when there's no way to create your own ``AsyncOperation``,
/// e.g. in SwiftUI bindings there's no place to define operations so we use this to "directly" mutate values.
@MainActor public struct InlineValueMutation<Value>: SyncOperation {
    let value: Value
    let mutation: (Value, SyncOperationEnvironment) -> Void

    public init(value: Value, mutation: @escaping (Value, SyncOperationEnvironment) -> Void) {
        self.value = value
        self.mutation = mutation
    }

    public func perform(in env: SyncOperationEnvironment) {
        mutation(value, env)
    }
}

