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

#if canImport(SwiftUI)
import SwiftUI

/// A write-only handle a view uses to dispatch state operations into the ``SharedEnvironment``.
///
/// ```swift
/// struct CounterView: View {
///     @Watch(\CounterContainer.count) var count
///     @Perform var perform
///
///     var body: some View {
///         Button("Increment: \(count)") {
///             perform(IncrementCount())     // SyncOperation
///         }
///         .task {
///             await perform(LoadInitialState())  // awaits an AsyncOperation
///         }
///     }
/// }
/// ```
@propertyWrapper
@MainActor
public struct Perform: DynamicProperty {
    @Environment(\.sharedEnvironment) private var environment

    public init() {}

    /// The callable handle vended by ``Perform/wrappedValue``.
    ///
    /// Exposing dispatch through a dedicated `callAsFunction` type keeps the `perform(_:)` call
    /// ergonomics at the use site while keeping those overloads off ``SharedEnvironment`` itself.
    @MainActor
    public struct Runner {
        private let environment: SharedEnvironment

        init(_ environment: SharedEnvironment) {
            self.environment = environment
        }

        /// Dispatches a synchronous operation, applying its mutations and notifying observers once.
        public func callAsFunction<Op: ThrowingSyncOperation>(
            _ operation: Op,
            file: String = #fileID,
            line: UInt = #line
        ) throws(Op.Failure) {
            try environment.perform(operation, file: file, line: line)
        }

        /// Dispatches an asynchronous operation as a detached task, returning immediately.
        ///
        /// Use this from synchronous contexts (button actions, gestures). To wait for completion
        /// from an `async` context, use the awaiting overload below instead.
        /// Fire-and-forget exists only for a non-throwing ``AsyncOperation``.
        public func callAsFunction<Op: AsyncOperation>(
            _ operation: Op,
            file: String = #fileID,
            line: UInt = #line
        ) {
            environment.perform(operation, file: file, line: line)
        }

        /// Dispatches an asynchronous operation and suspends until it completes.
        ///
        /// Prefer this inside `.task { }` or other `async` contexts where completion matters.
        public func callAsFunction<Op: AsyncOperation>(
            _ operation: Op,
            file: String = #fileID,
            line: UInt = #line
        ) async {
            await environment.perform(operation, file: file, line: line)
        }

        /// Dispatches a throwing asynchronous operation and suspends until it completes or throws.
        public func callAsFunction<Op: ThrowingAsyncOperation>(
            _ operation: Op,
            file: String = #fileID,
            line: UInt = #line
        ) async throws(Op.Failure) {
            try await environment.perform(operation, file: file, line: line)
        }
    }

    /// A ``Runner`` bound to the resolved environment. Call it directly to dispatch an operation.
    public var wrappedValue: Runner {
        Runner(environment)
    }
}
#endif
