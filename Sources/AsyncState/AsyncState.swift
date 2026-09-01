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
import OSLog

let asyncStateLogger = Logger(
    subsystem: "StateManagement",
    category: "AsyncState"
)

/// What the runtime needs from a wrapper it reached through an erased Address.
@MainActor
protocol AsyncStateHandle: AnyObject {
    var sourcedKeyPath: AnyKeyPath? { get }
    var statusKeyPath: AnyKeyPath? { get }
    var storageValueKeyPath: AnyKeyPath? { get }
    var dollarKeyPath: AnyKeyPath? { get }
    var wrapperKeyPath: AnyKeyPath? { get }

    /// The three kicks. The wrapper knows `S`, so it fetches its own strategy and no erased
    /// instance travels back through a cast.
    func kickOnRead(key: AnyHashable?, in runtime: AsyncStateRuntime)
    func kickOnWrite(key: AnyHashable?, in runtime: AsyncStateRuntime)
    func kickOnDrop(key: AnyHashable?, in runtime: AsyncStateRuntime)
    func settleAfterAppWrite(key: AnyHashable?)
    func seedPendingStatus(key: AnyHashable?)
    func evictStatus(key: AnyHashable)
    func bind(environment: SharedEnvironment)
}

/// Declares that an Atomic or Keyed Value is backed by an AsyncStrategy. `$property` is this
/// wrapper, not a Value.
///
/// Atomic is `Key == NoKey, Entry == Value`; Keyed is `Value == [Key: Entry]`. The Key is a
/// parameter of the wrapper, so a keyed kick receives the key type the strategy is called with and
/// nothing has to be recovered at run time.
///
/// > Important: A dictionary Value is the Keyed case. `@AsyncState var done: [UUID: Bool] = [:]`
/// declares one Address per entry, and the dictionary Address `\C.done` names the whole fact:
/// reading it binds the wrapper and kicks nothing, while reading one entry kicks for that key.
/// To source the dictionary as a single Value, give it a non-dictionary wrapper type.
///
/// > Warning: `@AsyncState` does not compose with ``SMPublished``. Both are enclosing-instance
/// wrappers over the same stored Value, and a property carries one wrapper.
///
/// Companion status is `$property.status`. First read of either Address, or `preheat`, calls
/// ``AsyncStrategy/onRead(_:policy:current:)`` with the `$` Address. Policy is stored here and
/// passed into `onRead`, `onWrite`, and `onDrop`.
@propertyWrapper
@MainActor
public final class AsyncState<S: AsyncStrategy, Key: Hashable, Entry, Value> {
    var storage: Value
    let seed: Value
    let policy: S.Policy
    /// One status per key. Atomic keeps its single status under ``NoKey/noKey``.
    var statusStorage: [Key: AsyncStateStatus<S.Failure>] = [:]

    /// Atomic or Keyed, answered by the init that already knows. See ``AsyncStateShape``.
    private let shape: any AsyncStateShape<S, Key, Entry, Value>

    private(set) var sourcedKeyPath: AnyKeyPath?
    private(set) var statusKeyPath: AnyKeyPath?
    private(set) var storageValueKeyPath: AnyKeyPath?
    private(set) var dollarKeyPath: AnyKeyPath?
    private(set) var wrapperKeyPath: AnyKeyPath?

    /// The Environment that read this Address. `refresh()` needs it, and the Environment
    /// owns the Container that owns this wrapper, so the reference is weak.
    weak var boundEnvironment: SharedEnvironment?

    /// The three kicks, bound to the `$` Address the first subscript access supplied. Installed
    /// from the Atomic or Keyed extension, which is where the strategy overloads are visible.
    var onReadKick: ((S, AnyHashable?) -> Void)?
    var onWriteKick: ((S, AnyHashable?) -> Void)?
    var onDropKick: ((S, AnyHashable?) -> Void)?

    /// The wrapper itself. `$property` is this value, not the sourced Value.
    public var projectedValue: AsyncState { self }

    /// The sourced Value. Unavailable except through the enclosing instance.
    @available(*, unavailable, message: "@AsyncState can only be applied to properties of classes")
    public var wrappedValue: Value {
        get { storage }
        set { storage = newValue }
    }

    // MARK: - Atomic declaration

    /// Atomic sourced Value. Status starts `.pending`. Type-only; `Policy` must be `Void`.
    @_disfavoredOverload
    public convenience init(wrappedValue: Value, _: S.Type)
        where Key == NoKey, Entry == Value, S.Policy == Void {
        self.init(wrappedValue: wrappedValue, policy: ())
    }

    /// Atomic sourced Value. Status starts `.pending`. Passes `policy` to `onRead`, `onWrite`, and `onDrop`.
    public convenience init(wrappedValue: Value, _ policy: S.Policy)
        where Key == NoKey, Entry == Value {
        self.init(wrappedValue: wrappedValue, policy: policy)
    }

    /// Designated init. App call site is unlabeled ``init(wrappedValue:_:)-(Value,S.Policy)``.
    /// A Satellite pins `S` by forwarding here; `S.Policy` does not reverse-infer `S`.
    @_disfavoredOverload
    public init(wrappedValue: Value, policy: S.Policy)
        where Key == NoKey, Entry == Value {
        self.storage = wrappedValue
        self.seed = wrappedValue
        self.policy = policy
        self.shape = AtomicAsyncState<S, Value>()
    }

    // MARK: - Keyed declaration

    /// Keyed sourced Value. Per-entry status starts missing and is seeded `.pending` on first read.
    /// Type-only; `Policy` must be `Void`.
    public convenience init(wrappedValue: [Key: Entry], _: S.Type)
        where Value == [Key: Entry], S.Policy == Void {
        self.init(wrappedValue: wrappedValue, policy: ())
    }

    /// Keyed sourced Value. Per-entry status starts missing and is seeded `.pending` on first read.
    /// Passes `policy` to `onRead`, `onWrite`, and `onDrop`.
    public convenience init(wrappedValue: [Key: Entry], _ policy: S.Policy)
        where Value == [Key: Entry] {
        self.init(wrappedValue: wrappedValue, policy: policy)
    }

    /// Designated keyed init. App call site is unlabeled ``init(wrappedValue:_:)-([Key:Entry],S.Policy)``.
    /// A Satellite pins `S` by forwarding here; `S.Policy` does not reverse-infer `S`.
    @_disfavoredOverload
    public init(wrappedValue: [Key: Entry], policy: S.Policy)
        where Value == [Key: Entry] {
        self.storage = wrappedValue
        self.seed = wrappedValue
        self.policy = policy
        self.shape = KeyedAsyncState<S, Key, Entry>()
    }

    // MARK: - Enclosing instance

    /// Reads and writes the sourced Value through the enclosing Container.
    public static subscript<Storage: StateContainer>(
        _enclosingInstance instance: Storage,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Storage, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Storage, AsyncState>
    ) -> Value {
        get {
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.bindValuePath(wrappedKeyPath, storageKeyPath: storageKeyPath)
            wrapper.bind(dollar: storageKeyPath)
            AsyncStateRuntime.noteHandleRead(wrapper)
            return wrapper.storage
        }
        set {
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.bindValuePath(wrappedKeyPath, storageKeyPath: storageKeyPath)
            wrapper.bind(dollar: storageKeyPath)
            AsyncStateRuntime.noteHandleRead(wrapper)
            wrapper.storage = newValue
        }
    }

    /// Reads `$property` through the enclosing Container.
    public static subscript<Storage: StateContainer>(
        _enclosingInstance instance: Storage,
        projected projectedKeyPath: KeyPath<Storage, AsyncState>,
        storage storageKeyPath: ReferenceWritableKeyPath<Storage, AsyncState>
    ) -> AsyncState {
        get {
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.bindDollarPath(projectedKeyPath, storageKeyPath: storageKeyPath)
            wrapper.bind(dollar: projectedKeyPath)
            AsyncStateRuntime.noteHandleRead(wrapper)
            return wrapper
        }
    }

    // MARK: - Address binding

    private func bindValuePath<Storage: StateContainer>(
        _ wrappedKeyPath: ReferenceWritableKeyPath<Storage, Value>,
        storageKeyPath: ReferenceWritableKeyPath<Storage, AsyncState>
    ) {
        sourcedKeyPath = wrappedKeyPath
        storageValueKeyPath = storageKeyPath.appending(path: \.storage)
        wrapperKeyPath = storageKeyPath
    }

    private func bindDollarPath<Storage: StateContainer>(
        _ projectedKeyPath: KeyPath<Storage, AsyncState>,
        storageKeyPath: ReferenceWritableKeyPath<Storage, AsyncState>
    ) {
        statusKeyPath = (projectedKeyPath as AnyKeyPath).appending(path: shape.statusMember)
        storageValueKeyPath = storageKeyPath.appending(path: \.storage)
        wrapperKeyPath = storageKeyPath
        dollarKeyPath = projectedKeyPath
    }

    /// Remembers the `$` Address and installs the kicks against it, once, on first access.
    private func bind<Storage: StateContainer>(dollar: KeyPath<Storage, AsyncState>) {
        if dollarKeyPath == nil {
            dollarKeyPath = dollar
        }
        guard onReadKick == nil else { return }
        shape.installKicks(on: self, dollar: dollar)
    }

    // MARK: - Status

    /// The Key an erased call means. `nil` on a keyed Address whose key type does not match,
    /// which is a logged no-op rather than a trap.
    func resolveKey(_ key: AnyHashable?) -> Key? {
        guard let key else { return shape.unkeyedKey }
        guard let typed = key.base as? Key else {
            asyncStateLogger.debug("AsyncState key type \(String(describing: type(of: key.base))), expected \(String(describing: Key.self)): no-op")
            return nil
        }
        return typed
    }
}

extension AsyncState: AsyncStateHandle {

    func kickOnRead(key: AnyHashable?, in runtime: AsyncStateRuntime) {
        onReadKick?(runtime.strategyInstance(S.self), key)
    }

    func kickOnWrite(key: AnyHashable?, in runtime: AsyncStateRuntime) {
        onWriteKick?(runtime.strategyInstance(S.self), key)
    }

    func kickOnDrop(key: AnyHashable?, in runtime: AsyncStateRuntime) {
        onDropKick?(runtime.strategyInstance(S.self), key)
    }

    func settleAfterAppWrite(key: AnyHashable?) {
        guard let resolved = resolveKey(key) else { return }
        statusStorage[resolved] = .settled
    }

    func seedPendingStatus(key: AnyHashable?) {
        guard let resolved = resolveKey(key) else { return }
        if statusStorage[resolved] == nil {
            statusStorage[resolved] = .pending
        }
    }

    func evictStatus(key: AnyHashable) {
        guard let resolved = resolveKey(key) else { return }
        statusStorage[resolved] = .pending
    }

    func bind(environment: SharedEnvironment) {
        boundEnvironment = environment
    }
}
