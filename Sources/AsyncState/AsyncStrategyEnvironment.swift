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
/// Nested `perform` has no `write`. Dead Environment: inbound verbs no-op.
///
/// > Important: A strategy retains this, never the ``SharedEnvironment``. The Environment owns the
/// strategy, so holding it back is a cycle; this type holds the Environment weakly and answers
/// ``environmentID`` after it dies, which is what an overlay keyed by Environment identity needs.
/// It is what every verb a strategy may call is reached through, so there is nothing else to keep.
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

    /// Writes the Value and `.settled`, clears Stale, and resumes every waiter on this Address.
    public func apply<Storage: StateContainer, S: AsyncStrategy, Value>(
        _ address: KeyPath<Storage, AsyncState<S, NoKey, Value, Value>>,
        value: Value
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { runtime in
            runtime.apply(value, at: address)
        })
    }

    /// Writes the keyed Value and `.settled`, and clears Stale. `nil` settles a missing key.
    public func apply<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<S, Key, Entry, [Key: Entry]>>,
        key: Key,
        value: Entry?
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { runtime in
            runtime.apply(value, at: address, key: key)
        })
    }

    /// Writes `.error`, leaves the sourced Value, clears Stale, and throws to the waiters.
    public func fail<Storage: StateContainer, S: AsyncStrategy, Value>(
        _ address: KeyPath<Storage, AsyncState<S, NoKey, Value, Value>>,
        error: S.Failure
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { runtime in
            runtime.fail(error, at: address)
        })
    }

    /// Writes keyed `.error`, leaves the sourced Value, and clears Stale.
    public func fail<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<S, Key, Entry, [Key: Entry]>>,
        key: Key,
        error: S.Failure
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { runtime in
            runtime.fail(error, at: address, key: key)
        })
    }

    /// Dirties the sourced Address and notifies it. Status stays `.settled`.
    public func markStale<Storage: StateContainer, S: AsyncStrategy, Value>(
        _ address: KeyPath<Storage, AsyncState<S, NoKey, Value, Value>>
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { runtime in
            runtime.markStale(at: address, keys: [nil])
        })
    }

    /// Dirties these entries and notifies them, in one Operation and one observation round.
    public func markStale<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<S, Key, Entry, [Key: Entry]>>,
        keys: Set<Key>
    ) {
        guard let environment = liveEnvironment() else { return }
        environment.perform(StrategyWrite { runtime in
            runtime.markStale(at: address, keys: keys.map { AnyHashable($0) })
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
