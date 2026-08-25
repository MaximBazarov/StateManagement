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
public enum SourceStatus<Failure: Error>: Sendable {
    /// Seed is showing. No successful `apply` yet, or `restoreSeed` restored the seed.
    case pending
    /// A Value has been applied. Stays settled while dirty.
    case settled
    /// Last `fail`. The sourced Value is unchanged.
    case error(Failure)
}

extension SourceStatus: Equatable where Failure: Equatable {
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

/// Owns read, write, and external side effects for `@AsyncState` Addresses.
/// The Environment owns one instance per type and always holds the Value.
///
/// ``onRead``, ``onWrite``, and ``onDrop`` take an Address and a Policy value. Address names the
/// Value. Policy is how that Address is backed — a per-Address value stored on ``AsyncState``, not
/// a second Address.
///
/// The sourced Address stays live until the Container drops. Kicks are synchronous and return
/// nothing. Later inbound is ``AsyncStrategyEnvironment/apply(_:keyPath:)`` / `fail`.
@MainActor
public protocol AsyncStrategy: AnyObject {
    /// Failure type for `$property.status`. Use `Never` if this strategy cannot fail.
    associatedtype Failure: Error
    /// Per-Address value stored on ``AsyncState`` and passed to ``onRead``, ``onWrite``, and ``onDrop``.
    ///
    /// Default `Void` keeps type-only `@AsyncState(SomeStrategy.self)` for mocks. A non-Void Policy
    /// requires a Policy value at the property wrapper.
    associatedtype Policy: Sendable = Void
    /// Creates the one instance the Environment owns for this type. `env` is standing and weak.
    init(env: AsyncStrategyEnvironment)

    /// First read, `preheat`, or dirty only. `current` is the Value the Environment already holds.
    /// `policy` is the value stored on ``AsyncState`` for this Address.
    func onRead<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy: Policy,
        current: Value
    )

    /// First read, `preheat`, or dirty only for one Keyed Address.
    func onRead<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: Policy,
        current: Value?
    )

    /// After every app Sync write. The Value is already in the Environment, `.settled`.
    func onWrite<Storage: StateContainer, Value>(
        _ value: Value,
        _ keyPath: KeyPath<Storage, Value>,
        policy: Policy
    )

    /// After every app Sync write to one Keyed Address.
    func onWrite<Storage: StateContainer, Key: Hashable, Value>(
        _ value: Value,
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: Policy
    )

    /// The sourced Address died because this Address's Container dropped. Default is empty.
    /// `policy` is the same value ``onRead`` received.
    func onDrop<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy: Policy
    )

    /// The sourced Address died because this keyed Address's Container dropped. Default is empty.
    func onDrop<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: Policy
    )
}

extension AsyncStrategy {
    /// Default so a Keyed-only strategy can omit the Atomic overload.
    public func onRead<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy: Policy,
        current: Value
    ) {}

    /// Default so an Atomic-only strategy can omit the Keyed overload.
    public func onRead<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: Policy,
        current: Value?
    ) {}

    /// Default so a Keyed-only strategy can omit the Atomic overload.
    public func onWrite<Storage: StateContainer, Value>(
        _ value: Value,
        _ keyPath: KeyPath<Storage, Value>,
        policy: Policy
    ) {}

    /// Default so an Atomic-only strategy can omit the Keyed overload.
    public func onWrite<Storage: StateContainer, Key: Hashable, Value>(
        _ value: Value,
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: Policy
    ) {}

    /// Default so a Keyed-only strategy can omit the Atomic overload.
    public func onDrop<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy: Policy
    ) {}

    /// Default so an Atomic-only strategy can omit the Keyed overload.
    public func onDrop<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: Policy
    ) {}
}
