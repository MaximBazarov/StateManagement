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
import OSLog

private let strategyLogger = Logger(
    subsystem: "StateManagement",
    category: "AsyncStrategy"
)

/// Restricted Environment for an AsyncStrategy. Standing for the Environment's lifetime.
///
/// Inbound verbs are hidden Sync operations. No `write`. No `read`. No `spawnService`.
/// Nested ``perform`` has no `write`. Dead Environment: inbound verbs no-op.
@MainActor
public final class AsyncStrategyEnvironment {
    weak var environment: SharedEnvironment?
    /// Identity of the Environment this strategy is bound to. Stable after the Environment dies.
    public let environmentID: ObjectIdentifier

    init(_ environment: SharedEnvironment) {
        self.environment = environment
        self.environmentID = ObjectIdentifier(environment)
    }

    private func liveEnvironment() -> SharedEnvironment? {
        guard let environment else {
            strategyLogger.debug("AsyncStrategy inbound on a dead Environment")
            return nil
        }
        return environment
    }

    /// Writes the Value and `.settled`, and clears dirty.
    public func apply<Storage: StateContainer, S: AsyncStrategy, Value, Status>(
        _ value: Value,
        keyPath: KeyPath<Storage, AsyncState<S, Value, Status>>
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { env in
            env.applyStrategyApply(value, keyPath: keyPath)
        })
    }

    /// Writes the keyed Value and `.settled`, and clears dirty.
    public func apply<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Value, Status>(
        _ value: Value,
        keyPath: KeyPath<Storage, AsyncState<S, [Key: Value], Status>>,
        key: Key
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { env in
            env.applyStrategyKeyedApply(value, keyPath: keyPath, key: key)
        })
    }

    /// Writes `.error`, leaves the sourced Value, and clears dirty.
    public func fail<Storage: StateContainer, S: AsyncStrategy, Value, Status>(
        _ error: S.Failure,
        keyPath: KeyPath<Storage, AsyncState<S, Value, Status>>
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { env in
            env.applyStrategyFail(error, keyPath: keyPath)
        })
    }

    /// Writes keyed `.error`, leaves the sourced Value, and clears dirty.
    public func fail<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Value, Status>(
        _ error: S.Failure,
        keyPath: KeyPath<Storage, AsyncState<S, [Key: Value], Status>>,
        key: Key
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { env in
            env.applyStrategyKeyedFail(error, keyPath: keyPath, key: key)
        })
    }

    /// Writes the seed and `.pending`, and clears dirty. Does not call `onDrop`.
    public func restoreSeed<Storage: StateContainer, S: AsyncStrategy, Value, Status>(
        keyPath: KeyPath<Storage, AsyncState<S, Value, Status>>
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { env in
            env.applyStrategyRestoreSeed(keyPath: keyPath)
        })
    }

    /// Writes the keyed seed and `.pending`, and clears dirty. Does not call `onDrop`.
    public func restoreSeed<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Value, Status>(
        keyPath: KeyPath<Storage, AsyncState<S, [Key: Value], Status>>,
        key: Key
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { env in
            env.applyStrategyKeyedRestoreSeed(keyPath: keyPath, key: key)
        })
    }

    /// Dirties the sourced Address and notifies it. Status stays `.settled`.
    public func markStale<Storage: StateContainer, S: AsyncStrategy, Value, Status>(
        keyPath: KeyPath<Storage, AsyncState<S, Value, Status>>
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { env in
            env.applyStrategyMarkStale(keyPath: keyPath)
        })
    }

    /// Dirties the keyed sourced Address and notifies it. Status stays `.settled`.
    public func markStale<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Value, Status>(
        keyPath: KeyPath<Storage, AsyncState<S, [Key: Value], Status>>,
        key: Key
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { env in
            env.applyStrategyKeyedMarkStale(keyPath: keyPath, key: key)
        })
    }

    /// Runs a Sync Operation owned by this Environment. Nested env has no `write`.
    public func perform<Op: ThrowingSyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) throws(Op.Failure) {
        guard let environment = liveEnvironment() else { return }
        try environment.performClosedWrite(operation, file: file, line: line)
    }

    /// Starts a non-throwing async Operation. Execution is owned by this Environment.
    public func perform<Op: AsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(operation, file: file, line: line)
    }

    /// Runs a throwing async Operation. Execution is owned by this Environment.
    public func perform<Op: ThrowingAsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) async throws(Op.Failure) {
        guard let environment = liveEnvironment() else { return }
        try await environment.perform(operation, file: file, line: line)
    }
}
