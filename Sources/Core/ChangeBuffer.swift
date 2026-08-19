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

/// The set of value IDs changed during one operation.
///
/// ``ObservationRegistry`` collects invalidations here as an operation runs, then drains them at
/// `notifyAll()` so notifications fire once per operation instead of once per write.
struct ChangeBuffer {

    private var ids: Set<ValueID> = []

    /// Marks a value changed for the current operation.
    mutating func insert(_ id: ValueID) {
        ids.insert(id)
    }

    /// Folds in more changed IDs, e.g. the dependents invalidated by a change.
    mutating func formUnion(_ other: Set<ValueID>) {
        ids.formUnion(other)
    }

    /// Returns the collected IDs and clears the buffer for the next operation.
    mutating func drain() -> Set<ValueID> {
        defer { ids = [] }
        return ids
    }
}
