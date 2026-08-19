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

/// A 64-bit globally unique identifier for a single trace span.
///
/// `SpanID` identifies an individual unit of work within a larger trace flow.
/// It conforms to the W3C Trace Context standard and is represented as a 16-character hex string.
///
/// Spans are organized hierarchically within a `TraceID` using parent-child relations.
public struct SpanID: Sendable, Equatable, Hashable, CustomStringConvertible {
    let val: UInt64

    /// Returns the W3C standard 16-character hexadecimal representation.
    public var description: String {
        let s = String(val, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }

    /// Generates a unique 64-bit random `SpanID`.
    ///
    /// The generated value relies on the platform's native high-entropy random source.
    /// - Returns: A random, high-entropy 64-bit `SpanID`.
    public static func generate() -> Self {
        .init(val: UInt64.random(in: UInt64.min...UInt64.max))
    }
}

/// A 128-bit W3C-compliant unique identifier for a single distributed trace.
///
/// `TraceID` represents the globally unique identifier associated with an execution flow.
/// It is composed of two independent 64-bit entropy blocks, yielding 128 bits of randomness.
///
/// ### Format
/// String representation is a 32-character hexadecimal string padded with leading zeros:
/// ```swift
/// let traceID = TraceID.generate()
/// print(traceID.description) // e.g. "00a4fb819c927f12bc0df19ef9100a42"
/// ```
public struct TraceID: Sendable, Equatable, Hashable, CustomStringConvertible {
    let hi: UInt64
    let lo: UInt64

    /// Returns the W3C standard 32-character hexadecimal representation.
    public var description: String {
        let hiStr = String(hi, radix: 16)
        let loStr = String(lo, radix: 16)
        let hiPad = String(repeating: "0", count: 16 - hiStr.count) + hiStr
        let loPad = String(repeating: "0", count: 16 - loStr.count) + loStr
        return hiPad + loPad
    }

    /// Generates a globally unique W3C-compliant 128-bit random `TraceID`.
    ///
    /// This method uses the system's cryptographically secure random number generator
    /// (`SystemRandomNumberGenerator`) to ensure zero-collision likelihood.
    /// - Returns: A fully random, unique 128-bit `TraceID`.
    public static func generate() -> Self {
        .init(
            hi: UInt64.random(in: UInt64.min...UInt64.max),
            lo: UInt64.random(in: UInt64.min...UInt64.max)
        )
    }
}
