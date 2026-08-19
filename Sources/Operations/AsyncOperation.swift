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

    // MARK: - Service

    /// Returns the cached ``EnvironmentService`` of this type, spawning it if needed.
    public func getService<Service: EnvironmentService>(_ type: Service.Type) async -> Service {
        await environment.getService(type)
    }
}
