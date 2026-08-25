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

/// An Async operation that may throw `Failure`.
///
/// Non-throwing operations use ``AsyncOperation`` instead. The two protocols are siblings so
/// fire-and-forget (`perform` without `await`) does not collide with `try await perform`.
@MainActor public protocol ThrowingAsyncOperation<Failure> {
    associatedtype Failure: Error
    /// How overlapping Executions of this Operation are handled. No default. The Environment owns the Execution.
    var reentrancy: ReentrancyDecision { get }
    func perform(in env: AsyncOperationEnvironment) async throws(Failure)
}

/// An Async operation that does not throw.
@MainActor public protocol AsyncOperation {
    /// How overlapping Executions of this Operation are handled. No default. The Environment owns the Execution.
    var reentrancy: ReentrancyDecision { get }
    func perform(in env: AsyncOperationEnvironment) async
}

/// A restricted interface of ``SharedEnvironment`` provided to an Async operation.
///
/// We use those for operations to restrict which actions they could take and define the observation behavior.
@MainActor public final class AsyncOperationEnvironment {
    unowned var environment: SharedEnvironment
    let execution: Execution?

    init(_ environment: SharedEnvironment, execution: Execution? = nil) {
        self.environment = environment
        self.execution = execution
    }

    public func perform<Op: ThrowingSyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) throws(Op.Failure) {
        // Cancel stops the next write. A committed child already went through this door.
        if let execution, execution.isCancelled { return }
        try environment.perform(operation, file: file, line: line)
    }

    public func perform<Op: AsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) {
        environment.perform(operation, file: file, line: line)
    }

    public func perform<Op: ThrowingAsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) async throws(Op.Failure) {
        try await environment.perform(operation, file: file, line: line)
    }

    // MARK: - I/O

    public func read<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>
    ) -> Value {
        environment.getValue(keyPath: keyPath)
    }

    // MARK: - Dictionary

    /// Returns a value in a dictionary stored at the given key path.
    public func read<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) -> Value? {
        environment.getValue(keyPath: keyPath, key: key)
    }

    // MARK: - Awaitable sourced read

    /// Awaits the sourced Value at a `$` Address.
    ///
    /// `.settled` returns the Value with no kick. `.pending` or Stale kicks `onRead`, or Joins the
    /// kick already in flight, and waits for `apply` / `fail`. `.error` throws the stored `Failure`.
    ///
    /// A one-shot wait: it leaves no receiver behind. A strategy whose `onRead` returns without
    /// `apply` or `fail` leaves this call suspended; `reset` and Cancel release it with the
    /// current Value.
    public func read<Storage: StateContainer, S: AsyncStrategy, Value>(
        _ keyPath: KeyPath<Storage, AsyncState<S, Value, SourceStatus<S.Failure>>>
    ) async throws(S.Failure) -> Value {
        try await environment.awaitSourced(keyPath, subscribe: nil)
    }

    /// Awaits one key of a keyed sourced Address. Another key's `apply` does not resume this wait.
    public func read<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Output>(
        _ keyPath: KeyPath<Storage, AsyncState<S, [Key: Output], [Key: SourceStatus<S.Failure>]>>,
        key: Key
    ) async throws(S.Failure) -> Output? {
        try await environment.awaitSourced(keyPath, key: key, subscribe: nil)
    }

    // MARK: - Service

    /// Returns the cached ``EnvironmentService`` of this type, spawning it if needed.
    public func getService<Service: EnvironmentService>(_ type: Service.Type) async -> Service {
        await environment.getService(type)
    }
}
