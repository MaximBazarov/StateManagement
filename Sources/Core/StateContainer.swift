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

/// A class that holds a slice of application state as plain stored properties.
///
/// You never create or hold a container yourself. The environment owns exactly one instance per type,
/// created lazily on first access and identified by the type itself. Every read and
/// write goes through a key path into that shared instance, so `\ListContainer.items` always refers to
/// the same storage no matter where it is read from.
///
/// The only requirement is a parameterless `init`. The environment uses it to spawn the instance. Give
/// each stored property a default value. That default is the state's initial value.
///
/// > Note: The instance lives for the lifetime of its ``SharedEnvironment`` (the process, for the
/// production ``SharedEnvironment/shared``).
///
/// A Value sits on two independent axes: it is Atomic or Keyed, and it is stored or Computed. That
/// makes four cases, and a container may mix all four:
///
/// - **Atomic**: a single stored property, addressed by its key path (`\TodoContainer.title`).
/// - **Keyed**:  a `[Key: Value]` dictionary, addressed by key path *and* a key
/// (`\TodoContainer.done`, key: `id`). Reads return `Value?`. Each key is observed independently.
/// - **Computed**: a ``Computed`` property derived from the others, recomputed on demand and cached.
///
/// Mark leftover Combine properties with ``SMPublished``. A plain `var` on the same class stays
/// per-instance. Only `@SMPublished` is Environment state.
///
/// An Atomic or Keyed Value may be backed by an ``AsyncStrategy`` with ``AsyncState``. That is sourced State,
/// not a fourth shape. `$property` is the wrapper. `$property.status` is the companion Source status.
/// Address names the Value. Policy on ``AsyncState`` is how that Address is backed, not a second Address.
///
/// ```swift
/// final class TodoContainer: StateContainer {
///
///     // Atomic: one value for the whole container.
///     var title: String = ""
///
///     // Atomic collection: the set of item ids.
///     var items: [UUID] = []
///
///     // Keyed: a completion flag per item id.
///     var done: [UUID: Bool] = [:]
///
///     // Atomic computed: derived from `items`.
///     @Computed var count = { env in
///         env.read(\TodoContainer.items).count
///     }
///
///     // Keyed computed: derived per item id.
///     @Computed<UUID, Bool> var isDone = { env, id in
///         env.read(\TodoContainer.done, key: id) ?? false
///     }
/// }
/// ```
///
/// Read the state from a SwiftUI view with ``Watch``, one wrapper per shape:
///
/// ```swift
/// struct TodoRow: View {
///     let id: UUID
///
///     @Watch(\TodoContainer.title) var title             // atomic
///     @Watch(\TodoContainer.done, key: id) var done      // keyed → Bool?
///     @Watch(\TodoContainer.count) var count             // atomic computed
///     @Watch(\TodoContainer.isDone, key: id) var isDone  // keyed computed
///
///     var body: some View { Text(title) }
/// }
/// ```
///
/// Mutate the state only through an operation, which reads and writes by the same key paths and reports
/// the change so every watcher and dependent computed is notified:
///
/// ```swift
/// struct MarkDone: SyncOperation {
///     let id: UUID
///     func perform(in env: SyncOperationEnvironment) {
///         env.write(\TodoContainer.done, key: id, value: true)     // keyed write
///     }
/// }
/// ```
@MainActor public protocol StateContainer: AnyObject {
    init()
}
