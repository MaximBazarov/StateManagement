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

/// The storage both dependency tables share: a map from a value's ``ValueID`` to the set of things
/// that read it. `Element` is a ``NotificationReceiver`` (batched) or a ``Dependent`` (eager).
/// The table holds no firing policy: the caller decides when and how to fire a taken set.
/// Lifecycle is register on read, clear on fire, rebuild on next read, so ``take(_:)`` removes as it
/// returns.
@MainActor struct DependencyTable<Element: Hashable> {

    private var edges: [ValueID: Set<Element>] = [:]

    /// Records that `element` read the value at `input`.
    mutating func register(_ element: Element, on input: ValueID) {
        edges[input, default: []].insert(element)
    }

    /// Returns the elements registered on `input` and drops them. Empty if none.
    mutating func take(_ input: ValueID) -> Set<Element> {
        edges.removeValue(forKey: input) ?? []
    }
}
