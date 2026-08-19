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

/// A derived value that depends on other values and must react *eagerly* when one of its inputs
/// changes — as opposed to a ``NotificationReceiver``, which reacts *batched* at the end of an
/// operation.
///
/// A ``Computed`` registers one `Dependent` (per key) on each input it reads through
/// ``DependencyGraph/register(dependent:on:)``. When an input changes,
/// ``DependencyGraph/invalidate(input:)`` runs ``invalidate`` synchronously — clearing the
/// computation's cached output — and reports ``id`` so the derived value's own observers are
/// notified at flush. The reaction lives on the `Computed` (captured in ``invalidate``); the graph
/// only holds the hook.
///
/// Identity is the dependent's own ``ValueID``: two `Dependent`s for the same computation (and key)
/// are equal, so re-registering on each recompute dedups instead of accumulating. Every `Dependent`
/// sharing an `id` has an equivalent ``invalidate`` (clear the same cache slot), so keeping either
/// is correct.
@MainActor final class Dependent: @MainActor Hashable {

    /// The derived value's own ``ValueID`` (e.g. the computation's identifier).
    let id: ValueID

    /// The eager reaction, run when a tracked input changes. For a ``Computed`` this clears the
    /// cached output for the relevant key.
    let invalidate: () -> Void

    init(id: ValueID, invalidate: @escaping () -> Void) {
        self.id = id
        self.invalidate = invalidate
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Dependent, rhs: Dependent) -> Bool {
        lhs.id == rhs.id
    }
}
