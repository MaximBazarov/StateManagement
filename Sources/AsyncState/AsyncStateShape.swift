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

/// Which half of ``AsyncStrategy``'s verb table an ``AsyncState`` declaration binds, decided once
/// by the init that already knows.
///
/// Swift finds an enclosing-instance subscript only in the wrapper's own body, never in an
/// extension, so the one place that knows the Container type cannot also state `Key == NoKey`.
/// The declaration hands its answer down instead, and nothing is recovered from a cast.
@MainActor
protocol AsyncStateShape<S, Key, Entry, Value> {
    associatedtype S: AsyncStrategy
    associatedtype Key: Hashable
    associatedtype Entry
    associatedtype Value

    /// The Key an unkeyed call means: ``NoKey/noKey`` for Atomic, `nil` for Keyed, where an
    /// unkeyed call names the dictionary rather than an entry.
    var unkeyedKey: Key? { get }

    /// `\AsyncState.status`, appended to the `$` Address to address the companion status.
    var statusMember: AnyKeyPath { get }

    /// Binds the three kicks to the `$` Address the first subscript access supplied.
    func installKicks<Storage: StateContainer>(
        on wrapper: AsyncState<S, Key, Entry, Value>,
        dollar: KeyPath<Storage, AsyncState<S, Key, Entry, Value>>
    )
}

/// One whole fact at one name.
struct AtomicAsyncState<S: AsyncStrategy, Value>: AsyncStateShape {
    typealias Key = NoKey
    typealias Entry = Value

    var unkeyedKey: NoKey? { .noKey }

    var statusMember: AnyKeyPath { \AsyncState<S, NoKey, Value, Value>.status }

    func installKicks<Storage: StateContainer>(
        on wrapper: AsyncState<S, NoKey, Value, Value>,
        dollar: KeyPath<Storage, AsyncState<S, NoKey, Value, Value>>
    ) {
        wrapper.installKicks(dollar: dollar)
    }
}

/// One fact per key, in a dictionary Value.
struct KeyedAsyncState<S: AsyncStrategy, Key: Hashable, Entry>: AsyncStateShape {
    typealias Value = [Key: Entry]

    var unkeyedKey: Key? { nil }

    var statusMember: AnyKeyPath { \AsyncState<S, Key, Entry, [Key: Entry]>.status }

    func installKicks<Storage: StateContainer>(
        on wrapper: AsyncState<S, Key, Entry, [Key: Entry]>,
        dollar: KeyPath<Storage, AsyncState<S, Key, Entry, [Key: Entry]>>
    ) {
        wrapper.installKicks(dollar: dollar)
    }
}
