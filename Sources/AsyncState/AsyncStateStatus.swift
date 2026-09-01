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

/// Companion status at `$property.status`. It does not carry the sourced Value.
public enum AsyncStateStatus<Failure: Error>: Sendable {
    /// Seed is showing. No successful `apply` yet.
    case pending
    /// A Value has been applied. Stays settled while Stale.
    case settled
    /// Last `fail`. The sourced Value is unchanged.
    case error(Failure)
}

extension AsyncStateStatus: Equatable where Failure: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.settled, .settled):
            return true
        case (.error(let left), .error(let right)):
            return left == right
        default:
            return false
        }
    }
}
