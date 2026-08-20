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

/// Restricted Environment for a Source. Verbs are hidden Sync operations. No `write`. No general `perform`.
@MainActor
public final class SourceEnvironment {
    unowned var environment: SharedEnvironment

    init(_ environment: SharedEnvironment) {
        self.environment = environment
    }

    /// Snapshots a Value. Does not subscribe.
    public func read<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>
    ) -> Value {
        environment.read(keyPath)
    }

    /// Snapshots a keyed Value. Does not subscribe.
    public func read<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) -> Value? {
        environment.read(keyPath, key: key)
    }

    /// Writes the Value and `.settled`, and clears dirty.
    public func deliver<Storage: StateContainer, Value>(
        _ value: Value,
        keyPath: WritableKeyPath<Storage, Value>
    ) {
        environment.perform(SourceWrite { env in
            env.applySourceDeliver(value, keyPath: keyPath)
        })
    }

    /// Writes the keyed Value and `.settled`, and clears dirty.
    public func deliver<Storage: StateContainer, Key: Hashable, Value>(
        _ value: Value,
        keyPath: WritableKeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        environment.perform(SourceWrite { env in
            env.applySourceKeyedDeliver(value, keyPath: keyPath, key: AnyHashable(key))
        })
    }

    /// Writes `.error`, leaves the sourced Value, and clears dirty.
    public func fail<Storage: StateContainer, Value, Failure: Error>(
        _ error: Failure,
        keyPath: KeyPath<Storage, Value>
    ) {
        environment.perform(SourceWrite { env in
            env.applySourceFail(error, keyPath: keyPath)
        })
    }

    /// Writes keyed `.error`, leaves the sourced Value, and clears dirty.
    public func fail<Storage: StateContainer, Key: Hashable, Value, Failure: Error>(
        _ error: Failure,
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        environment.perform(SourceWrite { env in
            env.applySourceKeyedFail(error, keyPath: keyPath, key: AnyHashable(key))
        })
    }

    /// Writes the seed and `.pending`, and clears dirty. Does not call `dropped`.
    public func clear<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>
    ) {
        environment.perform(SourceWrite { env in
            env.applySourceClear(keyPath: keyPath)
        })
    }

    /// Writes the keyed seed and `.pending`, and clears dirty. Does not call `dropped`.
    public func clear<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        environment.perform(SourceWrite { env in
            env.applySourceKeyedClear(keyPath: keyPath, key: AnyHashable(key))
        })
    }

    /// Dirties the sourced Address and notifies it. Status stays `.settled`.
    public func invalidate<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>
    ) {
        environment.perform(SourceWrite { env in
            env.applySourceInvalidate(keyPath: keyPath)
        })
    }

    /// Dirties the keyed sourced Address and notifies it. Status stays `.settled`.
    public func invalidate<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        environment.perform(SourceWrite { env in
            env.applySourceKeyedInvalidate(keyPath: keyPath, key: AnyHashable(key))
        })
    }

    /// Creates the Service if missing and kicks ``EnvironmentService/serve()`` on the notify Task hop.
    /// Does not await first ``EnvironmentService/serve()``.
    public func spawnService<Service: EnvironmentService>(_ type: Service.Type) {
        environment.perform(SourceWrite { env in
            env.spawnServiceAndKick(type)
        })
    }
}
