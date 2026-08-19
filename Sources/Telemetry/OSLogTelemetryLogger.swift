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
import OSLog

/// A premium, customizable telemetry consumer that outputs events to Apple's native OSLog framework.
@MainActor
public final class OSLogTelemetryLogger {
    private static let logger = Logger(subsystem: "StateManagement", category: "Telemetry")
    private static var completedSpans: [TraceID: [TelemetryEvent]] = [:]

    /// Maximum number of pending (incomplete) traces before eviction.
    /// Prevents unbounded memory growth from orphaned traces.
    private static let maxPendingTraces = 256

    /// Registers the logger as the global telemetry event handler.
    public static func enable() {
        completedSpans.removeAll()
        TraceContext.eventHandler = { event in
            switch event.kind {
            case .start:
                // Evict stale traces if over capacity
                if completedSpans.count > maxPendingTraces {
                    completedSpans.removeAll()
                }

            case .end:
                if event.parentID == nil {
                    // Root span ended: build and print the entire tree atomically

                    var allSpans = completedSpans[event.traceID] ?? []
                    completedSpans.removeValue(forKey: event.traceID)
                    allSpans.append(event)

                    let treeLog = buildTreeString(root: event, allSpans: allSpans)
                    logger.debug("\(treeLog)")
                } else {
                    // Child span ended: save it
                    completedSpans[event.traceID, default: []].append(event)
                }

            case .log:
                // A developer note: buffer it under its trace like a child end.
                // It renders as a leaf under its parent span in the tree.
                completedSpans[event.traceID, default: []].append(event)
            }
        }
    }

    /// Unregisters the logger, disabling telemetry output.
    public static func disable() {
        TraceContext.eventHandler = nil
        completedSpans.removeAll()
    }

    internal static func buildTreeString(root: TelemetryEvent, allSpans: [TelemetryEvent]) -> String {
        var parentToChildren: [SpanID: [TelemetryEvent]] = [:]
        for span in allSpans {
            if let parent = span.parentID {
                parentToChildren[parent, default: []].append(span)
            }
        }
        
        var lines: [String] = []
        
        func traverse(span: TelemetryEvent, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let prefix = depth == 0 ? "" : "- "

            if span.kind == .log {
                // A note has no duration and no children: render it as a leaf.
                lines.append("\(indent)\(prefix)\(span.name) 📝")
                return
            }

            let durationStr = formatMachTime(span.durationMachTime ?? 0)
            let prettyName = prettyfyName(span.name)
            
            let fileLineInfo = span.name.hasPrefix("Operation: ") && !span.file.isEmpty ? " [\(span.file):\(span.line)]" : ""
            lines.append("\(indent)\(prefix)\(prettyName) ⏳ \(durationStr)\(fileLineInfo)")

            if let valueDescription = span.valueDescription {
                let valueIndent = indent + (depth == 0 ? "  " : " ")
                lines.append("\(valueIndent)-> \(valueDescription)")
            }
            
            let children = parentToChildren[span.id] ?? []
            for child in children {
                traverse(span: child, depth: depth + 1)
            }
        }
        
        traverse(span: root, depth: 0)
        return lines.joined(separator: "\n")
    }

    private static func prettyfyName(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "Operation: ", with: "")
        if clean.hasPrefix("Set: ") {
            let content = clean.dropFirst("Set: ".count)
            return "\(content) changed"
        }
        if clean.hasPrefix("Remove: ") {
            let content = clean.dropFirst("Remove: ".count)
            return "\(content) removed"
        }
        return clean
    }

    /// Cached Mach timebase info — constant for the lifetime of the process.
    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func formatMachTime(_ ticks: UInt64) -> String {
        let denom = timebaseInfo.denom == 0 ? 1 : timebaseInfo.denom
        let nanoseconds = Double(ticks) * Double(timebaseInfo.numer) / Double(denom)
        if nanoseconds >= 1_000_000_000 {
            return String(format: "%.2fs", nanoseconds / 1_000_000_000.0)
        } else if nanoseconds >= 1_000_000 {
            return String(format: "%.2fms", nanoseconds / 1_000_000.0)
        } else if nanoseconds >= 1_000 {
            return String(format: "%.2fμs", nanoseconds / 1_000.0)
        } else {
            return String(format: "%.0fns", nanoseconds)
        }
    }
}
