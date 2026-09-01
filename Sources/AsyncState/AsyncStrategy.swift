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

/// Owns read, write, and external side effects for `@AsyncState` Addresses.
/// The Environment owns one instance per type and always holds the Value.
///
/// Every kick takes the `$` Address first and unlabelled, with `Self` pinned, so another
/// strategy's `$` Address or a plain stored Address does not compile. Then the key, then the
/// Policy, then the payload. Atomic and Keyed keep paired declarations because a Keyed entry can
/// be absent, so a strategy may implement one axis and take the empty default for the other.
///
/// The sourced Address stays live until the Container drops. Kicks are synchronous and return
/// nothing. Later inbound is ``AsyncStrategyEnvironment/apply(_:value:)`` / `fail`.
///
/// > Note: A kick returns immediately, so off-main work goes through `perform` with an
/// ``AsyncOperation``, never a bare `Task`. See <doc:Concurrency-and-Offloading>.
@MainActor
public protocol AsyncStrategy: AnyObject {
    /// Failure type for `$property.status`. Use `Never` if this strategy cannot fail.
    associatedtype Failure: Error
    /// Per-Address value stored on ``AsyncState`` and passed to ``onRead(_:policy:current:)``,
    /// ``onWrite(_:policy:value:)``, and ``onDrop(_:policy:)``.
    ///
    /// Default `Void` keeps type-only `@AsyncState(SomeStrategy.self)` for mocks. A non-Void Policy
    /// requires a Policy value at the property wrapper.
    associatedtype Policy: Sendable = Void
    /// Creates the one instance the Environment owns for this type. `env` is standing and weak.
    init(env: AsyncStrategyEnvironment)

    /// First read, `preheat`, or Stale only. `current` is the Value the Environment already holds.
    /// `policy` is the value stored on ``AsyncState`` for this Address.
    func onRead<Storage: StateContainer, Value>(
        _ address: KeyPath<Storage, AsyncState<Self, NoKey, Value, Value>>,
        policy: Policy,
        current: Value
    )

    /// First read, `preheat`, or Stale only for one entry of a Keyed Address.
    /// `current` is `nil` when that entry is absent.
    func onRead<Storage: StateContainer, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<Self, Key, Entry, [Key: Entry]>>,
        key: Key,
        policy: Policy,
        current: Entry?
    )

    /// After every app Sync write. The Value is already in the Environment, `.settled`.
    func onWrite<Storage: StateContainer, Value>(
        _ address: KeyPath<Storage, AsyncState<Self, NoKey, Value, Value>>,
        policy: Policy,
        value: Value
    )

    /// After every app Sync write to one entry of a Keyed Address.
    func onWrite<Storage: StateContainer, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<Self, Key, Entry, [Key: Entry]>>,
        key: Key,
        policy: Policy,
        value: Entry
    )

    /// The sourced Address died because this Address's Container dropped. Default is empty.
    /// `policy` is the same value ``onRead(_:policy:current:)`` received.
    func onDrop<Storage: StateContainer, Value>(
        _ address: KeyPath<Storage, AsyncState<Self, NoKey, Value, Value>>,
        policy: Policy
    )

    /// One entry of a Keyed Address died because its Container dropped. Default is empty.
    func onDrop<Storage: StateContainer, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<Self, Key, Entry, [Key: Entry]>>,
        key: Key,
        policy: Policy
    )
}

extension AsyncStrategy {
    /// Default so a Keyed-only strategy can omit the Atomic overload.
    public func onRead<Storage: StateContainer, Value>(
        _ address: KeyPath<Storage, AsyncState<Self, NoKey, Value, Value>>,
        policy: Policy,
        current: Value
    ) {}

    /// Default so an Atomic-only strategy can omit the Keyed overload.
    public func onRead<Storage: StateContainer, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<Self, Key, Entry, [Key: Entry]>>,
        key: Key,
        policy: Policy,
        current: Entry?
    ) {}

    /// Default so a Keyed-only strategy can omit the Atomic overload.
    public func onWrite<Storage: StateContainer, Value>(
        _ address: KeyPath<Storage, AsyncState<Self, NoKey, Value, Value>>,
        policy: Policy,
        value: Value
    ) {}

    /// Default so an Atomic-only strategy can omit the Keyed overload.
    public func onWrite<Storage: StateContainer, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<Self, Key, Entry, [Key: Entry]>>,
        key: Key,
        policy: Policy,
        value: Entry
    ) {}

    /// Default so a Keyed-only strategy can omit the Atomic overload.
    public func onDrop<Storage: StateContainer, Value>(
        _ address: KeyPath<Storage, AsyncState<Self, NoKey, Value, Value>>,
        policy: Policy
    ) {}

    /// Default so an Atomic-only strategy can omit the Keyed overload.
    public func onDrop<Storage: StateContainer, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<Self, Key, Entry, [Key: Entry]>>,
        key: Key,
        policy: Policy
    ) {}
}
