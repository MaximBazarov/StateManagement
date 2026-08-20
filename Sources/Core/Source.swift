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

/// How a Source applies an external update: write the Value, or mark it dirty.
public enum SourceUpdate: Sendable {
    /// Every external update `deliver`s the new Value.
    case write
    /// The Source still watches. `invalidate` dirties; the next read calls `provide`.
    case invalidate
}

/// Companion status at `$property.status`. It does not carry the sourced Value.
public enum SourceStatus<Failure: Error>: Sendable {
    /// Seed is showing. No successful `deliver` yet, or `clear` restored the seed.
    case pending
    /// A Value has been delivered. Stays settled while dirty.
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

/// An inbound producer. The Environment owns one instance per type.
///
/// ``provide`` and ``dropped`` take an Address and a Policy value. Address names the Value. Policy is
/// how that Address is sourced — a per-Address value stored on ``AsyncState``, not a second Address.
///
/// The sourced Address stays live until the Container drops. `provide` is synchronous. Nested
/// `deliver` is a nested Sync operation.
@MainActor
public protocol Source: AnyObject {
    /// Failure type for `$property.status`. Use `Never` if this Source cannot fail.
    associatedtype Failure: Error
    /// Per-Address value stored on ``AsyncState`` and passed to ``provide`` and ``dropped``.
    ///
    /// Default `Void` keeps type-only `@AsyncState(SomeSource.self)` for mocks. A non-Void Policy
    /// requires a Policy value at the property wrapper.
    associatedtype Policy: Sendable = Void
    /// Creates the one instance the Environment owns for this type.
    init()
    /// How this Source applies an external update. Required. No default.
    var sourceUpdate: SourceUpdate { get }

    /// Pull for one Atomic Address. Synchronous. Nested `deliver` is nested `perform`.
    /// `policy` is the value stored on ``AsyncState`` for this Address.
    func provide<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy: Policy,
        in env: SourceEnvironment
    )

    /// Pull for one Keyed Address. Synchronous. Nested `deliver` is nested `perform`.
    /// `policy` is the value stored on ``AsyncState`` for this Address.
    func provide<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: Policy,
        in env: SourceEnvironment
    )

    /// The sourced Address died because this Address's Container dropped. Default is empty.
    /// `policy` is the same value ``provide`` received.
    func dropped<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy: Policy
    )

    /// The sourced Address died because this keyed Address's Container dropped. Default is empty.
    /// `policy` is the same value ``provide`` received.
    func dropped<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: Policy
    )
}

extension Source {
    /// Default so a Keyed-only Source can omit the Atomic overload.
    public func provide<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy: Policy,
        in env: SourceEnvironment
    ) {}

    /// Default so an Atomic-only Source can omit the Keyed overload.
    public func provide<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: Policy,
        in env: SourceEnvironment
    ) {}

    /// Default so a Keyed-only Source can omit the Atomic overload.
    public func dropped<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        policy: Policy
    ) {}

    /// Default so an Atomic-only Source can omit the Keyed overload.
    public func dropped<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key,
        policy: Policy
    ) {}
}
