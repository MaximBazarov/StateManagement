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

/// Groups Executions of one Operation type. Folded into `firstWins` and `newestWins`.
public struct ReentrancyIdentity: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case wholeOperation
        case key(SendableValueKey)
    }

    let kind: Kind

    /// Every Execution of this Operation type shares one group.
    public static var wholeOperation: ReentrancyIdentity {
        ReentrancyIdentity(kind: .wholeOperation)
    }

    /// Executions that share this value are one group. Comparison is by value.
    public static func key<Value: Hashable & Sendable>(_ value: Value) -> ReentrancyIdentity {
        ReentrancyIdentity(kind: .key(SendableValueKey(value)))
    }
}

/// `AnyHashable` is not Sendable. Equality still goes through the value, not a bare hash.
struct SendableValueKey: Hashable, Sendable {
    private let base: any Hashable & Sendable

    init<Value: Hashable & Sendable>(_ value: Value) {
        self.base = value
    }

    static func == (lhs: SendableValueKey, rhs: SendableValueKey) -> Bool {
        AnyHashable(lhs.base) == AnyHashable(rhs.base)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(AnyHashable(base))
    }
}

/// How overlapping Executions of the same async Operation are handled.
///
/// A value, not a closed enum. The Environment reads this and owns the Task. The Operation does not.
public struct ReentrancyDecision: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case runAll
        case firstWins(ReentrancyIdentity)
        case newestWins(ReentrancyIdentity)
    }

    let kind: Kind

    /// Overlapping Executions all proceed. No Identity.
    public static var runAll: ReentrancyDecision {
        ReentrancyDecision(kind: .runAll)
    }

    /// Join the live Execution of this Identity. Do not start a second.
    public static func firstWins(_ identity: ReentrancyIdentity) -> ReentrancyDecision {
        ReentrancyDecision(kind: .firstWins(identity))
    }

    /// Start a new Execution, Cancel the previous live one of this Identity, move awaiters onto the new one.
    public static func newestWins(_ identity: ReentrancyIdentity) -> ReentrancyDecision {
        ReentrancyDecision(kind: .newestWins(identity))
    }
}
