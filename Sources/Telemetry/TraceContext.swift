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

import os

/// Represents a precise timing and context event emitted by a telemetry span.
public struct TelemetryEvent: Sendable {
    /// Classifies whether this event marks the beginning or end of a span.
    public enum Kind: Sendable {
        /// The span has just been created; timing has started.
        case start
        /// The span has ended; `durationMachTime` is populated.
        case end
        /// A developer note recorded against its parent span. Single event, no
        /// begin/end pair, `durationMachTime` is `nil`.
        case log
    }

    /// Whether this event represents a span start, end, or a developer log note.
    public let kind: Kind

    /// The human-readable name of the span operation.
    public let name: String

    /// The unique 64-bit identifier representing this specific execution span.
    public let id: SpanID

    /// The parent span's 64-bit identifier, if not starting a root trace.
    public let parentID: SpanID?

    /// The globally unique 128-bit distributed trace identifier.
    public let traceID: TraceID

    /// The source code file originating the span.
    public let file: String

    /// The source code line originating the span.
    public let line: UInt

    /// The duration of the span in Mach continuous time ticks.
    ///
    /// This value is `nil` for `.start` events, and populated with the elapsed duration on `.end` events.
    public let durationMachTime: UInt64?

    /// A debug description of the new state value after a `Set` span.
    ///
    /// Populated only when `TelemetryInternal` is enabled. Never appears in the span `name`.
    public let valueDescription: String?

    public init(
        kind: Kind,
        name: String,
        id: SpanID,
        parentID: SpanID?,
        traceID: TraceID,
        file: String,
        line: UInt,
        durationMachTime: UInt64?,
        valueDescription: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.id = id
        self.parentID = parentID
        self.traceID = traceID
        self.file = file
        self.line = line
        self.durationMachTime = durationMachTime
        self.valueDescription = valueDescription
    }
}

/// The propagation context carrying active distributed trace identity.
///
/// `TraceContext` holds the necessary identifiers to track logical execution paths across asynchronous
/// contexts, task structures, and network boundaries.
///
/// ### Overview
/// The context holds a `traceID` (globally identifying the flow) and an `activeSpanID` (the span that
/// owns this context, used as the parent reference for child spans).
///
/// Context propagation is supported via both explicit argument passing and implicit `@TaskLocal` inheritance.
public struct TraceContext: Sendable {
    /// The globally unique 128-bit distributed trace identifier.
    public let traceID: TraceID

    /// The span ID that owns this context level.
    ///
    /// Children created via `start()` will reference this as their `parentID`.
    /// `nil` for root contexts where no span is active yet.
    public let activeSpanID: SpanID?

    /// Initializes a trace context with specific tracing coordinates.
    /// - Parameters:
    ///   - traceID: The active trace identifier.
    ///   - activeSpanID: The owning span's identifier (optional).
    public init(traceID: TraceID, activeSpanID: SpanID? = nil) {
        self.traceID = traceID
        self.activeSpanID = activeSpanID
    }

    /// TaskLocal storage for implicit trace propagation across asynchronous boundaries.
    @TaskLocal
    public static var current: TraceContext?

    /// Global callback invoked whenever a telemetry span starts or ends.
    ///
    /// Declared `nonisolated(unsafe)` to allow synchronous invocation from `Span.deinit`
    /// without `Task` allocation overhead.
    /// Safety: all span lifetimes are bounded to `@MainActor` execution.
    nonisolated(unsafe) public static var eventHandler: ((TelemetryEvent) -> Void)?

    #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
    internal static let signposter = OSSignposter(subsystem: "StateManagement", category: "Telemetry")
    #endif

    /// Starts a new active span under the current context coordinate.
    ///
    /// The span automatically tracks continuous duration using system clocks and finalizes its logging block
    /// when the returned `Span` structure falls out of scope.
    ///
    /// - Parameters:
    ///   - name: The human-readable name identifying the span operation.
    ///   - kind: The categorization target of the span (e.g. user-facing or internal).
    ///   - valueDescription: A debug description of the value to attach to the span. Populated only when `TelemetryInternal` is enabled.
    ///   - file: The source code file location. Defaults to caller `#fileID`.
    ///   - line: The source code line number. Defaults to caller `#line`.
    /// - Returns: A non-copyable `Span` lifetime handle.
    @inline(__always)
    @MainActor
    public func start(
        _ name: @autoclosure () -> String,
        kind: TelemetryKind = .user,
        valueDescription: String? = nil,
        file: String = #fileID,
        line: Int = #line
    ) -> Span {
        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        let enabled: Bool
        switch kind {
        case .user:
            #if STATE_MANAGEMENT_TELEMETRY
            enabled = true
            #else
            enabled = false
            #endif
        case .internal:
            #if STATE_MANAGEMENT_TELEMETRY_INTERNAL
            enabled = true
            #else
            enabled = false
            #endif
        }

        guard enabled else {
            return .empty(fallbackContext: self)
        }

        let resolvedName = name()
        let id = SpanID.generate()

        let signpostID = OSSignpostID(id.val)
        let signpostState = Self.signposter.beginInterval("Span", id: signpostID)

        let startEvent = TelemetryEvent(
            kind: .start,
            name: resolvedName,
            id: id,
            parentID: activeSpanID,
            traceID: traceID,
            file: file,
            line: UInt(line),
            durationMachTime: nil
        )
        Self.eventHandler?(startEvent)

        return Span(
            id: id,
            context: TraceContext(traceID: traceID, activeSpanID: id),
            name: resolvedName,
            active: true,
            signpostState: signpostState,
            file: file,
            line: UInt(line),
            parentID: activeSpanID,
            valueDescription: valueDescription
        )
        #else
        return .empty(fallbackContext: self)
        #endif
    }

    /// Records a developer note against the current span.
    ///
    /// A note always belongs to a span: outside an active operation span this does
    /// nothing. The message is whatever the developer writes, the library never puts
    /// a state value here.
    ///
    /// - Parameters:
    ///   - message: The note to attach to the active span.
    ///   - file: The source code file location. Defaults to caller `#fileID`.
    ///   - line: The source code line number. Defaults to caller `#line`.
    @inline(__always)
    @MainActor
    public static func log(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        line: Int = #line
    ) {
        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        guard let context = TraceContext.current, let parentID = context.activeSpanID else { return }
        let event = TelemetryEvent(
            kind: .log,
            name: message(),
            id: SpanID.generate(),
            parentID: parentID,
            traceID: context.traceID,
            file: file,
            line: UInt(line),
            durationMachTime: nil
        )
        Self.eventHandler?(event)
        #endif
    }
}

extension TraceContext {
    /// Executes an operation under a newly started span, binding it to the implicit `@TaskLocal` context.
    ///
    /// This method simplifies hierarchical distributed tracing by propagating context implicitly without
    /// polluting user function interfaces.
    ///
    /// ```swift
    /// try TraceContext.withSpan("PerformAction") {
    ///     // Child scopes automatically inherit parent TraceID and parent SpanID
    ///     try performDatabaseWrite()
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name: The human-readable name of the scope.
    ///   - kind: The classification of the operation.
    ///   - valueDescription: A debug description of the value to attach to the span. Populated only when `TelemetryInternal` is enabled.
    ///   - file: The source code file location.
    ///   - line: The source code line.
    ///   - operation: The execution block representing the span duration.
    /// - Returns: The value returned by the execution block.
    @inline(__always)
    @MainActor
    public static func withSpan<T, E: Error>(
        _ name: @autoclosure () -> String,
        kind: TelemetryKind = .user,
        valueDescription: String? = nil,
        file: String = #fileID,
        line: Int = #line,
        _ operation: () throws(E) -> T
    ) throws(E) -> T {
        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        let parent = TraceContext.current ?? TraceContext(traceID: TraceID.generate())
        let span = parent.start(name(), kind: kind, valueDescription: valueDescription, file: file, line: line)
        return try bindCurrent(span.context, operation)
        #else
        return try operation()
        #endif
    }

    /// Executes an asynchronous operation under a newly started span, binding it to the implicit `@TaskLocal` context.
    @inline(__always)
    @MainActor
    public static func withSpan<T, E: Error>(
        _ name: @autoclosure () -> String,
        kind: TelemetryKind = .user,
        valueDescription: String? = nil,
        file: String = #fileID,
        line: Int = #line,
        _ operation: () async throws(E) -> T
    ) async throws(E) -> T {
        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        let parent = TraceContext.current ?? TraceContext(traceID: TraceID.generate())
        let span = parent.start(name(), kind: kind, valueDescription: valueDescription, file: file, line: line)
        return try await bindCurrent(span.context, operation)
        #else
        return try await operation()
        #endif
    }

    /// `TaskLocal.withValue` is `rethrows` (`any Error`). Box the typed result so
    /// `throws(E)` survives the bind.
    @inline(__always)
    @MainActor
    private static func bindCurrent<T, E: Error>(
        _ context: TraceContext,
        _ operation: () throws(E) -> T
    ) throws(E) -> T {
        var captured: Result<T, E>?
        TraceContext.$current.withValue(context) {
            do throws(E) {
                captured = .success(try operation())
            } catch {
                captured = .failure(error)
            }
        }
        switch captured {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            preconditionFailure("TraceContext.withSpan body did not run")
        }
    }

    @inline(__always)
    @MainActor
    private static func bindCurrent<T, E: Error>(
        _ context: TraceContext,
        _ operation: () async throws(E) -> T
    ) async throws(E) -> T {
        var captured: Result<T, E>?
        await TraceContext.$current.withValue(context) {
            do throws(E) {
                captured = .success(try await operation())
            } catch {
                captured = .failure(error)
            }
        }
        switch captured {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            preconditionFailure("TraceContext.withSpan body did not run")
        }
    }
}
