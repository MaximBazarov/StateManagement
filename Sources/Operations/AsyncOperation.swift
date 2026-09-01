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
///
/// > Note: The body runs on the main actor. Heavy work goes to an explicitly `nonisolated` async
/// function that takes and returns `Sendable` data. See <doc:Concurrency-and-Offloading>.
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

    /// Starts a non-throwing async Operation without waiting.
    public func perform<Op: AsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) {
        environment.perform(operation, file: file, line: line)
    }

    /// Waits for a non-throwing async Operation. Same pair ``SharedEnvironment`` already has.
    /// Disfavored so `perform(child)` in an async body stays fire-and-forget; `await perform(child)` still waits.
    @_disfavoredOverload
    public func perform<Op: AsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) async {
        await environment.perform(operation, file: file, line: line)
    }

    public func perform<Op: ThrowingAsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) async throws(Op.Failure) {
        try await environment.perform(operation, file: file, line: line)
    }

    // MARK: - I/O

    // `Value` is unconstrained, so a `$` Address satisfies this overload with
    // `Value == AsyncState<…>`. Disfavoured so `read(\C.$value)` reaches the awaitable read below
    // instead of handing back the wrapper (ADR 0024).
    @_disfavoredOverload
    public func read<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>
    ) -> Value {
        environment.read(keyPath)
    }

    /// Reads the whole dictionary. That Address names a whole fact and never kicks a strategy;
    /// reading one entry of the same declaration does (ADR 0026).
    public func read<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>
    ) -> [Key: Value] {
        environment.read(keyPath)
    }

    // MARK: - Computed

    /// Reads an atomic ``Computed``. The Operation does not subscribe: it reads and lets go.
    /// The cache and the dependency edges behave as for any other reader (ADR 0023).
    public func read<Storage: StateContainer, Output>(
        _ keyPath: KeyPath<Storage, Computed<NoKey, Output>>
    ) -> Output {
        environment
            .read(keyPath)
            .read(
                env: environment,
                valueID: ValueID(keyPath: keyPath),
                receiver: nil,
                key: .noKey
            )
    }

    /// Reads a keyed ``Computed`` for `key`, without subscribing.
    public func read<Storage: StateContainer, Key: Hashable, Output>(
        _ keyPath: KeyPath<Storage, Computed<Key, Output>>,
        key: Key
    ) -> Output {
        environment
            .read(keyPath)
            .read(
                env: environment,
                valueID: ValueID(keyPath: keyPath, key: key),
                receiver: nil,
                key: key
            )
    }

    // MARK: - Dictionary

    /// Returns a value in a dictionary stored at the given key path.
    public func read<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) -> Value? {
        environment.read(keyPath, key: key)
    }

    // MARK: - Service

    /// Returns the cached ``EnvironmentService`` of this type, spawning it if needed.
    public func getService<Service: EnvironmentService>(_ type: Service.Type) async -> Service {
        await environment.getService(type)
    }
}
