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
import Combine
import SwiftUI

/// Counts Executions this `@Perform` instance started or is awaiting.
@MainActor
final class PerformInFlight: ObservableObject {
    private(set) var count = 0
    var isInProgress: Bool { count > 0 }

    func begin() {
        objectWillChange.sendAfterViewUpdate()
        count += 1
    }

    func end() {
        objectWillChange.sendAfterViewUpdate()
        count -= 1
    }
}

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
    @StateObject private var inFlight: PerformInFlight

    public init() {
        self._inFlight = StateObject(wrappedValue: PerformInFlight())
    }

    /// The callable handle vended by ``Perform/wrappedValue``.
    ///
    /// Exposing dispatch through a dedicated `callAsFunction` type keeps the `perform(_:)` call
    /// ergonomics at the use site while keeping those overloads off ``SharedEnvironment`` itself.
    @MainActor
    public struct Runner {
        private let environment: SharedEnvironment
        private let inFlight: PerformInFlight

        init(_ environment: SharedEnvironment, inFlight: PerformInFlight) {
            self.environment = environment
            self.inFlight = inFlight
        }

        /// True while this handle has a started Execution, or an awaited Join, still in flight.
        public var isInProgress: Bool { inFlight.isInProgress }

        /// Dispatches a synchronous operation, applying its mutations and notifying observers once.
        public func callAsFunction<Op: ThrowingSyncOperation>(
            _ operation: Op,
            file: String = #fileID,
            line: UInt = #line
        ) throws(Op.Failure) {
            try environment.perform(operation, file: file, line: line)
        }

        /// Dispatches an asynchronous operation without waiting, returning immediately.
        ///
        /// Use this from synchronous contexts (button actions, gestures). To wait for completion
        /// from an `async` context, use the awaiting overload below instead.
        /// Fire-and-forget exists only for a non-throwing ``AsyncOperation``.
        public func callAsFunction<Op: AsyncOperation>(
            _ operation: Op,
            file: String = #fileID,
            line: UInt = #line
        ) {
            let inFlight = self.inFlight
            let started = environment.performFireAndForget(
                operation,
                file: file,
                line: line,
                onFinish: { [weak inFlight] in
                    inFlight?.end()
                }
            )
            if started {
                inFlight.begin()
            }
        }

        /// Dispatches an asynchronous operation and suspends until it completes.
        ///
        /// Prefer this inside `.task { }` or other `async` contexts where completion matters.
        public func callAsFunction<Op: AsyncOperation>(
            _ operation: Op,
            file: String = #fileID,
            line: UInt = #line
        ) async {
            inFlight.begin()
            defer { inFlight.end() }
            await environment.perform(operation, file: file, line: line)
        }

        /// Dispatches a throwing asynchronous operation and suspends until it completes or throws.
        public func callAsFunction<Op: ThrowingAsyncOperation>(
            _ operation: Op,
            file: String = #fileID,
            line: UInt = #line
        ) async throws(Op.Failure) {
            inFlight.begin()
            defer { inFlight.end() }
            try await environment.perform(operation, file: file, line: line)
        }
    }

    /// A ``Runner`` bound to the resolved environment. Call it directly to dispatch an operation.
    public var wrappedValue: Runner {
        Runner(environment, inFlight: inFlight)
    }
}
#endif
