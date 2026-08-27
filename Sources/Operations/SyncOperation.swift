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

private let syncOperationLogger = Logger(
    subsystem: "StateManagement",
    category: "SyncOperation"
)

/// A Sync operation that may throw `Failure`.
///
/// `Failure` is `Never` for a non-throwing operation. Write `struct Increment: SyncOperation`
/// with a non-throwing `perform`; the compiler infers `Never`.
@MainActor public protocol ThrowingSyncOperation<Failure> {
    associatedtype Failure: Error = Never
    func perform(in env: SyncOperationEnvironment) throws(Failure)
}

/// A Sync operation that does not throw.
///
/// A refining protocol, not `ThrowingSyncOperation<Never>` as a typealias, so
/// `any SyncOperation` is not a parameterized existential (macOS 12).
@MainActor public protocol SyncOperation: ThrowingSyncOperation where Failure == Never {}

/// A restricted interface of ``SharedEnvironment`` provided to ``SyncOperation``.
///
/// We use those for operations to restrict which actions they could take and define the observation behavior.
@MainActor public final class SyncOperationEnvironment {
    unowned var environment: SharedEnvironment
    let allowsWrite: Bool

    init(_ environment: SharedEnvironment, allowsWrite: Bool = true) {
        self.environment = environment
        self.allowsWrite = allowsWrite
    }

    /// Nested sync `perform` shares this Environment. Notification waits for the original `SharedEnvironment.perform`.
    public func perform<Op: ThrowingSyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) throws(Op.Failure) {
        if allowsWrite {
            try environment.perform(operation, file: file, line: line)
        } else {
            try environment.performClosedWrite(operation, file: file, line: line)
        }
    }

    /// Starts a non-throwing async Operation without waiting. Throwing async is `try await` only.
    public func perform<Op: AsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) {
        environment.perform(operation, file: file, line: line)
    }

    // MARK: - I/O

    public func read<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>
    ) -> Value {
        environment.getValue(keyPath: keyPath)
    }

    public func write<Storage: StateContainer, Value>(
        _ newValue: Value,
        keyPath: WritableKeyPath<Storage, Value>
    ) {
        guard allowsWrite else {
            syncOperationLogger.debug("Nested strategy perform has no write")
            return
        }
        environment.setValue(newValue, keyPath: keyPath)
    }

    // MARK: - Dictionary

    /// Returns a value in a dictionary stored at the given key path.
    public func read<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) -> Value? {
        environment.getValue(keyPath: keyPath, key: key)
    }

    /// Sets a dictionary value for the given key and reports a change for observation.
    public func write<Storage: StateContainer, Key: Hashable, Value>(
        _ newValue: Value,
        keyPath: WritableKeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        guard allowsWrite else {
            syncOperationLogger.debug("Nested strategy perform has no write")
            return
        }
        environment.setValue(newValue, keyPath: keyPath, key: key)
    }

    /// Removes a dictionary value for the given key and reports a change for observation.
    ///
    /// Prefer this over rewriting the whole dictionary when deleting an entry: it invalidates the
    /// keyed value so per-key watchers are notified (and their subscriptions flushed).
    public func remove<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: WritableKeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        guard allowsWrite else {
            syncOperationLogger.debug("Nested strategy perform has no write")
            return
        }
        environment.removeValue(keyPath: keyPath, key: key)
    }

    /// Drops every Container, Service, and AsyncStrategy. Cancels every in-flight Execution.
    public func reset() {
        environment.resetAll()
    }

    /// Drops the named Container type and calls `onDrop` for its sourced Addresses. Cancels every in-flight Execution.
    public func reset<Storage: StateContainer>(_ type: Storage.Type) {
        environment.resetContainer(type)
    }
}
