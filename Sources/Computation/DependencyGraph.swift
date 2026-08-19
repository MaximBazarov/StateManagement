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

/// Tracks which derived values (``Dependent``) depend on which inputs, and invalidates them when an
/// input changes.
///
/// This is the derivation concern extracted out of ``ObservationRegistry``: the observer table stays
/// there, while the input→dependents edges and the eager cache-clearing live here. The edges are a
/// ``DependencyTable`` of ``Dependent``, this type adds the transitive cascade on top.
@MainActor final class DependencyGraph {

    /// Input ``ValueID`` → the dependents that read it.
    private var table = DependencyTable<Dependent>()

    /// Records that `dependent` reads the value at `input`, so it is invalidated when `input` changes.
    func register(dependent: Dependent, on input: ValueID) {
        table.register(dependent, on: input)
    }

    /// Invalidates every dependent of `input`, *transitively*: runs each ``Dependent/invalidate``
    /// eagerly, drops each visited input's edges (rebuilt on the next recompute), and returns every
    /// invalidated dependent's own ``ValueID`` so the caller can fold them into the operation's
    /// change set.
    ///
    /// A dependent is itself an input to its own dependents, so the cascade walks the graph: an
    /// invalidated computation feeds the next level down the chain. The visited set dedups diamonds
    /// (`X → {A, B} → C` clears `C` once) and terminates any accidental edge cycle — a correct
    /// program never forms one, since the read guard traps first (ADR 0014).
    @discardableResult
    func invalidate(input: ValueID) -> Set<ValueID> {
        var invalidated: Set<ValueID> = []
        var stack: [ValueID] = [input]
        while let current = stack.popLast() {
            for dependent in table.take(current) where !invalidated.contains(dependent.id) {
                dependent.invalidate()
                invalidated.insert(dependent.id)
                stack.append(dependent.id)   // cascade: it is an input to its own dependents
            }
        }
        return invalidated
    }
}
