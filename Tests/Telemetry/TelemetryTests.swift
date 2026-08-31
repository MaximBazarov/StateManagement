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
import Testing
@testable import StateManagement

@Suite(.serialized) @MainActor struct TelemetryTests {
    @Test func testW3CCompliance() {
        let traceID = TraceID.generate()
        let spanID = SpanID.generate()
        
        let traceIDStr = traceID.description
        let spanIDStr = spanID.description
        
        #expect(traceIDStr.count == 32)
        #expect(spanIDStr.count == 16)
        
        // Assert hex character validity
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        #expect(CharacterSet(charactersIn: traceIDStr).isSubset(of: hexCharacterSet))
        #expect(CharacterSet(charactersIn: spanIDStr).isSubset(of: hexCharacterSet))
    }
    
    @Test func testImplicitTaskLocalPropagation() async throws {
        let rootTraceID = TraceID.generate()
        let rootContext = TraceContext(traceID: rootTraceID)
        
        // Verify explicit start parent inheritance
        let span = rootContext.start("RootSpan")
        #expect(span.context.traceID == rootTraceID)
        
        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        #expect(span.context.activeSpanID == span.id)
        #else
        #expect(span.context.activeSpanID == nil)
        #endif
        
        // Verify implicit propagation via TaskLocal closure block
        TraceContext.$current.withValue(span.context) {
            #expect(TraceContext.current?.traceID == rootTraceID)
            
            #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
            #expect(TraceContext.current?.activeSpanID == span.id)
            #else
            #expect(TraceContext.current?.activeSpanID == nil)
            #endif
            
            // Nested implicit propagation
            TraceContext.withSpan("ChildSpan") {
                #expect(TraceContext.current?.traceID == rootTraceID)
            }
        }
    }
    


    @Test func testEnvironmentPerformTracing() async throws {
        var events: [TelemetryEvent] = []
        TraceContext.eventHandler = { event in
            events.append(event)
        }
        
        let file = #fileID
        let line = #line; SharedEnvironment.shared.perform(TestSyncOperation())
        
        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        #expect(events.count == 2)
        
        let startEvent = events[0]
        #expect(startEvent.kind == .start)
        #expect(startEvent.name == "Operation: TestSyncOperation")
        #expect(startEvent.file == file)
        #expect(startEvent.line == line)
        #expect(startEvent.durationMachTime == nil)
        
        let endEvent = events[1]
        #expect(endEvent.kind == .end)
        #expect(endEvent.name == "Operation: TestSyncOperation")
        #expect(endEvent.file == file)
        #expect(endEvent.line == line)
        #expect(endEvent.durationMachTime != nil)
        #else
        #expect(events.isEmpty)
        #endif
        
        TraceContext.eventHandler = nil
    }

    @Test func testEnvironmentAsyncPerformTracing() async throws {
        var events: [TelemetryEvent] = []
        TraceContext.eventHandler = { event in
            events.append(event)
        }
        
        let file = #fileID
        let line = #line; await SharedEnvironment.shared.perform(TestAsyncOperation())
        
        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        #expect(events.count == 2)
        
        let startEvent = events[0]
        #expect(startEvent.kind == .start)
        #expect(startEvent.name == "Operation: TestAsyncOperation")
        #expect(startEvent.file == file)
        #expect(startEvent.line == line)
        #expect(startEvent.durationMachTime == nil)
        
        let endEvent = events[1]
        #expect(endEvent.kind == .end)
        #expect(endEvent.name == "Operation: TestAsyncOperation")
        #expect(endEvent.file == file)
        #expect(endEvent.line == line)
        #expect(endEvent.durationMachTime != nil)
        #else
        #expect(events.isEmpty)
        #endif
        
        TraceContext.eventHandler = nil
    }

    @Test func testWatchCoordinates() {
        let file = #fileID
        let line = #line; let watch = Watch<MockStorage, Int>(\.count)
        
        #expect(watch.file == file)
        #expect(watch.line == line)
    }

    @Test func testOSLogTelemetryLogger() async throws {
        OSLogTelemetryLogger.enable()
        
        var capturedEvents: [TelemetryEvent] = []
        let originalHandler = TraceContext.eventHandler
        TraceContext.eventHandler = { event in
            originalHandler?(event)
            capturedEvents.append(event)
        }
        
        SharedEnvironment.shared.perform(TestSyncOperation())
        
        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        #expect(capturedEvents.count == 2)
        #else
        #expect(capturedEvents.isEmpty)
        #endif
        
        OSLogTelemetryLogger.disable()
    }

    @Test func testStateUpdatePerformTracing() async throws {
        var events: [TelemetryEvent] = []
        TraceContext.eventHandler = { event in
            events.append(event)
        }
        
        let env = SharedEnvironment.shared
        env.perform(TestStateMutationOperation())
        
        #if STATE_MANAGEMENT_TELEMETRY && STATE_MANAGEMENT_TELEMETRY_INTERNAL
        #expect(events.count == 4)
        
        let operationStart = events[0]
        let mutationStart = events[1]
        let mutationEnd = events[2]
        let operationEnd = events[3]
        
        #expect(operationStart.kind == .start)
        #expect(operationStart.name == "Operation: TestStateMutationOperation")
        #expect(mutationStart.kind == .start)
        #expect(mutationStart.name.contains("MockStorage.count"))
        #expect(mutationStart.parentID == operationStart.id)
        #expect(mutationEnd.kind == .end)
        #expect(mutationEnd.id == mutationStart.id)
        #expect(mutationEnd.valueDescription == "42")
        #expect(operationEnd.kind == .end)
        #expect(operationEnd.id == operationStart.id)
        #elseif STATE_MANAGEMENT_TELEMETRY
        // User level only: the operation span emits, the internal Set span is gated off.
        #expect(events.count == 2)
        #expect(events[0].name == "Operation: TestStateMutationOperation")
        #else
        #expect(events.isEmpty)
        #endif
        
        TraceContext.eventHandler = nil
    }

    @Test func testOSLogTelemetryLoggerTreeFormatting() {
        let opEvent = TelemetryEvent(
            kind: .end,
            name: "Operation: TestSyncOperation",
            id: SpanID.generate(),
            parentID: nil,
            traceID: TraceID.generate(),
            file: "StateManagement_Tests/TelemetryTests.swift",
            line: 42,
            durationMachTime: 1_000_000
        )
        
        let stateEvent = TelemetryEvent(
            kind: .end,
            name: "Set: \\MockStorage.count",
            id: SpanID.generate(),
            parentID: opEvent.id,
            traceID: opEvent.traceID,
            file: "StateManagement/SharedEnvironment.swift",
            line: 79,
            durationMachTime: 500_000,
            valueDescription: "42"
        )
        
        let treeLog = OSLogTelemetryLogger.buildTreeString(root: opEvent, allSpans: [opEvent, stateEvent])
        
        #expect(treeLog.contains("TestSyncOperation"))
        #expect(treeLog.contains("[StateManagement_Tests/TelemetryTests.swift:42]"))
        
        #expect(treeLog.contains("MockStorage.count changed"))
        #expect(treeLog.contains("-> 42"))
        #expect(!treeLog.contains("changed to"))
        #expect(!treeLog.contains("[StateManagement/SharedEnvironment.swift:79]"))
    }

    // MARK: - Span.empty

    @Test func testSpanEmpty() {
        let ctx = TraceContext(traceID: TraceID.generate())
        let span = Span.empty(fallbackContext: ctx)
        #expect(span.id.val == 0)
        #expect(span.context.traceID == ctx.traceID)
    }

    // MARK: - NotificationReceiver.id

    @Test func testNotificationReceiverID() {
        let receiver = NotificationReceiver { _ in }
        let id1 = receiver.id
        let id2 = receiver.id
        #expect(!id1.isEmpty)
        #expect(id1 == id2)
    }

    // MARK: - OSLogTelemetryLogger nested child spans

    @Test func testOSLogTelemetryLoggerNestedChildSpans() {
        OSLogTelemetryLogger.enable()

        var capturedEvents: [TelemetryEvent] = []
        let originalHandler = TraceContext.eventHandler
        TraceContext.eventHandler = { event in
            originalHandler?(event)
            capturedEvents.append(event)
        }

        SharedEnvironment.shared.perform(TestStateMutationOperation())

        // 4 events: op start, mutation start, mutation end, op end.
        // The mutation end (child) hits the completedSpans append,
        // and the op end (root) drains and logs the tree.
        #if STATE_MANAGEMENT_TELEMETRY && STATE_MANAGEMENT_TELEMETRY_INTERNAL
        #expect(capturedEvents.count == 4)

        let mutationEnd = capturedEvents[2]
        #expect(mutationEnd.kind == .end)
        #expect(mutationEnd.parentID != nil)
        #elseif STATE_MANAGEMENT_TELEMETRY
        #expect(capturedEvents.count == 2)
        #else
        #expect(capturedEvents.isEmpty)
        #endif

        OSLogTelemetryLogger.disable()
        TraceContext.eventHandler = nil
    }

    // MARK: - Remove: prettify

    @Test func testOSLogTelemetryLoggerRemovePrettify() {
        let opID = SpanID.generate()
        let traceID = TraceID.generate()

        let removeEvent = TelemetryEvent(
            kind: .end,
            name: "Remove: \\TelemetryDictState.items[\"x\"]",
            id: SpanID.generate(),
            parentID: opID,
            traceID: traceID,
            file: "",
            line: 0,
            durationMachTime: 100
        )

        let rootEvent = TelemetryEvent(
            kind: .end,
            name: "Operation: RemoveOp",
            id: opID,
            parentID: nil,
            traceID: traceID,
            file: "Tests/TelemetryTests.swift",
            line: 1,
            durationMachTime: 200
        )

        let tree = OSLogTelemetryLogger.buildTreeString(root: rootEvent, allSpans: [rootEvent, removeEvent])
        #expect(tree.contains("removed"))
        #expect(!tree.contains("Remove: "))
    }

    // MARK: - Duration formatting branches

    @Test func testDurationFormattingAllBranches() {
        let traceID = TraceID.generate()
        let rootID = SpanID.generate()

        func makeRoot(duration: UInt64) -> TelemetryEvent {
            TelemetryEvent(
                kind: .end,
                name: "Operation: Bench",
                id: rootID,
                parentID: nil,
                traceID: traceID,
                file: "Test.swift",
                line: 1,
                durationMachTime: duration
            )
        }

        // >=1s branch
        let treeSec = OSLogTelemetryLogger.buildTreeString(root: makeRoot(duration: 2_000_000_000), allSpans: [makeRoot(duration: 2_000_000_000)])
        #expect(treeSec.contains("s"))
        #expect(!treeSec.contains("ms"))

        // >=1μs branch
        let treeMicro = OSLogTelemetryLogger.buildTreeString(root: makeRoot(duration: 50), allSpans: [makeRoot(duration: 50)])
        #expect(treeMicro.contains("μs"))

        // <1μs branch: 0 ticks → 0ns, always hits the ns formatter
        let treeNano = OSLogTelemetryLogger.buildTreeString(root: makeRoot(duration: 0), allSpans: [makeRoot(duration: 0)])
        #expect(treeNano.contains("ns"))
    }

    // MARK: - Eviction of stale traces

    @Test func testOSLogTelemetryLoggerEviction() {
        OSLogTelemetryLogger.enable()

        // Simulate >256 pending child spans from unique traces.
        // Each child end event goes into completedSpans keyed by its traceID.
        // Once count exceeds maxPendingTraces, next start event evicts.
        let handler = TraceContext.eventHandler

        for _ in 0...256 {
            let tid = TraceID.generate()
            let childEnd = TelemetryEvent(
                kind: .end,
                name: "Set: child",
                id: SpanID.generate(),
                parentID: SpanID.generate(),
                traceID: tid,
                file: "",
                line: 0,
                durationMachTime: 10
            )
            handler?(childEnd)
        }

        // Now there are 257 entries in completedSpans.
        // A start event triggers eviction (line 33-34).
        let startEvent = TelemetryEvent(
            kind: .start,
            name: "Operation: Trigger",
            id: SpanID.generate(),
            parentID: nil,
            traceID: TraceID.generate(),
            file: "",
            line: 0,
            durationMachTime: nil
        )
        handler?(startEvent)

        // If eviction didn't crash, the test passes (the branch was exercised).
        OSLogTelemetryLogger.disable()
        TraceContext.eventHandler = nil
    }

    // MARK: - Zero cost when off

    @Test func testWithSpanRunsBodyAndStripsWhenOff() {
        var events: [TelemetryEvent] = []
        TraceContext.eventHandler = { events.append($0) }

        var ran = false
        let result = TraceContext.withSpan("Probe") { () -> Int in
            ran = true
            return 7
        }

        #expect(ran)
        #expect(result == 7)

        #if STATE_MANAGEMENT_TELEMETRY || STATE_MANAGEMENT_TELEMETRY_INTERNAL
        #expect(!events.isEmpty)
        #else
        #expect(events.isEmpty)
        #endif

        TraceContext.eventHandler = nil
    }

    // MARK: - Author log line

    @Test func testLogInsideSpanEmitsNote() {
        var events: [TelemetryEvent] = []
        TraceContext.eventHandler = { events.append($0) }

        TraceContext.withSpan("Operation: Host", kind: .user) {
            TraceContext.log("checkpoint")
        }

        #if STATE_MANAGEMENT_TELEMETRY
        let notes = events.filter { $0.kind == .log }
        #expect(notes.count == 1)
        #expect(notes[0].name == "checkpoint")
        #expect(notes[0].durationMachTime == nil)

        let start = events.first { $0.kind == .start }
        #expect(notes[0].parentID == start?.id)
        #else
        #expect(events.allSatisfy { $0.kind != .log })
        #endif

        TraceContext.eventHandler = nil
    }

    @Test func testLogOutsideSpanDoesNothing() {
        var events: [TelemetryEvent] = []
        TraceContext.eventHandler = { events.append($0) }

        TraceContext.log("orphan")

        #expect(events.isEmpty)

        TraceContext.eventHandler = nil
    }

    @Test func testOSLogRendersLogAsLeaf() {
        let opID = SpanID.generate()
        let traceID = TraceID.generate()

        let logEvent = TelemetryEvent(
            kind: .log,
            name: "checkpoint",
            id: SpanID.generate(),
            parentID: opID,
            traceID: traceID,
            file: "",
            line: 0,
            durationMachTime: nil
        )

        let rootEvent = TelemetryEvent(
            kind: .end,
            name: "Operation: Host",
            id: opID,
            parentID: nil,
            traceID: traceID,
            file: "Tests/TelemetryTests.swift",
            line: 1,
            durationMachTime: 200
        )

        let tree = OSLogTelemetryLogger.buildTreeString(root: rootEvent, allSpans: [rootEvent, logEvent])
        #expect(tree.contains("checkpoint 📝"))
        #expect(!tree.contains("checkpoint ⏳"))
    }

    // MARK: - Privacy

    @Test func testSetSpanCarriesNoValue() {
        var events: [TelemetryEvent] = []
        TraceContext.eventHandler = { events.append($0) }

        SharedEnvironment.shared.perform(TestStateMutationOperation())

        // The value 42 must never appear in any emitted span name.
        for event in events {
            #expect(!event.name.contains("42"))
            #expect(!event.name.contains("->"))
        }

        TraceContext.eventHandler = nil
    }
}

// MARK: - Mocks for Testing

struct TestSyncOperation: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {}
}

struct TestAsyncOperation: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }
    func perform(in env: AsyncOperationEnvironment) async {}
}

struct TestStateMutationOperation: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(\MockStorage.count, value: 42)
    }
}

final class MockStorage: StateContainer {
    var count = 0
    required init() {}
}

final class TelemetryDictState: StateContainer {
    var items: [String: Int] = ["x": 1]
    required init() {}
}
