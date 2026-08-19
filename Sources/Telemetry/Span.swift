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
import OSLog

/// A non-copyable lifetime handle representing an active span interval.
///
/// `Span` structures record interval durations and link execution scopes.
///
/// ### Resource Management
/// `Span` conforms to `~Copyable`. It enforces a strict scoped boundary and automatically finalizes
/// the telemetry recording in its `deinit` block, removing manual `stop()` requirements.
public struct Span: ~Copyable {
    /// The active telemetry propagation context bound to this span.
    public let context: TraceContext
    
    /// The unique 64-bit identifier representing this specific execution span.
    public let id: SpanID

    #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
    private let name: String
    private let active: Bool
    private let signpostState: OSSignpostIntervalState?
    private let startTimestamp: UInt64
    private let file: String
    private let line: UInt
    private let parentID: SpanID?
    private let valueDescription: String?

    internal init(
        id: SpanID,
        context: TraceContext,
        name: String,
        active: Bool = true,
        signpostState: OSSignpostIntervalState? = nil,
        startTimestamp: UInt64 = mach_continuous_time(),
        file: String,
        line: UInt,
        parentID: SpanID?,
        valueDescription: String? = nil
    ) {
        self.id = id
        self.context = context
        self.name = name
        self.active = active
        self.signpostState = signpostState
        self.startTimestamp = startTimestamp
        self.file = file
        self.line = line
        self.parentID = parentID
        self.valueDescription = valueDescription
    }
    #else
    internal init(id: SpanID, context: TraceContext) {
        self.id = id
        self.context = context
    }
    #endif

    @inline(__always)
    internal static func empty(fallbackContext: TraceContext) -> Span {
        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        return Span(
            id: SpanID(val: 0),
            context: fallbackContext,
            name: "",
            active: false,
            signpostState: nil,
            startTimestamp: 0,
            file: "",
            line: 0,
            parentID: nil
        )
        #else
        return Span(id: SpanID(val: 0), context: fallbackContext)
        #endif
    }

    /// Automatically terminates and records the active span interval when falling out of scope.
    deinit {
        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        guard active else { return }
        let endTimestamp = mach_continuous_time()
        let duration = endTimestamp - startTimestamp
        
        let event = TelemetryEvent(
            kind: .end,
            name: name,
            id: id,
            parentID: parentID,
            traceID: context.traceID,
            file: file,
            line: line,
            durationMachTime: duration,
            valueDescription: valueDescription
        )
        TraceContext.eventHandler?(event)

        if let state = signpostState {
            TraceContext.signposter.endInterval("Span", state)
        }
        #endif
    }
}
