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
import StateManagement

/// A public, read-only synchronous environment service interface designed specifically for unit testing.
///
/// It allows tests to perform synchronous state reads (including atomic, keyed, and computed values)
/// in a single line, without manually setting up reactive bookkeeping or custom mocks.
@MainActor public final class StateReader: EnvironmentService {
    
    /// Reads an atomic state property from the environment.
    public func read<S: StateContainer, V>(_ kp: KeyPath<S, V>) -> V {
        getValue(kp)
    }
    
    /// Reads a specific dictionary entry by key from the environment.
    public func read<S: StateContainer, K: Hashable, V>(_ kp: KeyPath<S, [K: V]>, key: K) -> V? {
        getValue(keyPath: kp, key: key)
    }
    
    /// Reads a computed property from the environment.
    public func read<S: StateContainer, V>(computed kp: KeyPath<S, Computed<NoKey, V>>) -> V {
        getValue(kp)
    }

    /// Reads a keyed computed property by key from the environment.
    public func read<S: StateContainer, K: Hashable, V>(computed kp: KeyPath<S, Computed<K, V>>, key: K) -> V {
        getValue(kp, key: key)
    }
}
