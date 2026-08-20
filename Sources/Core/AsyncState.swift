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

/// Marks `[Key: Output]` so a keyed sourced Address can call `Source.provide` with the entry key.
fileprivate protocol AsyncStateDictionary {
    associatedtype DictKey: Hashable
    associatedtype DictOutput
}

extension Dictionary: AsyncStateDictionary {
    typealias DictKey = Key
    typealias DictOutput = Value
}

@MainActor
protocol AsyncStateHandle: AnyObject {
    var isKeyed: Bool { get }
    var sourcedKeyPath: AnyKeyPath? { get set }
    var statusKeyPath: AnyKeyPath? { get set }
    var storageValueKeyPath: AnyKeyPath? { get set }
    var sourceTypeID: ObjectIdentifier { get }

    func resolveSource(in env: SharedEnvironment) -> any Source
    func callProvide(_ source: any Source, _ env: SourceEnvironment, key: AnyHashable?)
    func callDropped(_ source: any Source, key: AnyHashable?)
    func writeDeliver(_ value: Any, key: AnyHashable?)
    func writeFail(_ error: any Error, key: AnyHashable?)
    func writeClear(key: AnyHashable?)
    func seedKeyedPending(key: AnyHashable?)
}

/// Declares that an Atomic or Keyed Value is backed by a Source. `$property` is this wrapper, not a Value.
///
/// Companion Source status is `$property.status`. First read of either Address, or `preheat`, calls
/// ``Source/provide(_:policy:in:)``. Policy is stored here and passed into `provide` and `dropped`.
@propertyWrapper
@MainActor
public final class AsyncState<S: Source, Value, Status> {
    var storage: Value
    let seed: Value
    let policy: S.Policy
    var statusStorage: Status
    let isKeyed: Bool

    var sourcedKeyPath: AnyKeyPath?
    var statusKeyPath: AnyKeyPath?
    var storageValueKeyPath: AnyKeyPath?
    var provideOpener: ((S, SourceEnvironment, AnyHashable?) -> Void)?
    var droppedOpener: ((S, AnyHashable?) -> Void)?
    var deliverWriter: ((Any, AnyHashable?) -> Void)?
    var failWriter: ((any Error, AnyHashable?) -> Void)?
    var clearWriter: ((AnyHashable?) -> Void)?
    var seedPending: ((AnyHashable?) -> Void)?

    /// The wrapper itself. `$property` is this value, not the sourced Value.
    public var projectedValue: AsyncState { self }

    /// Companion Source status at `$property.status`.
    public var status: Status {
        get {
            SharedEnvironment.noteHandleRead(self)
            return statusStorage
        }
        set { statusStorage = newValue }
    }

    /// The sourced Value. Unavailable except through the enclosing instance.
    @available(*, unavailable, message: "@AsyncState can only be applied to properties of classes")
    public var wrappedValue: Value {
        get { storage }
        set { storage = newValue }
    }

    /// Atomic sourced Value. Status starts `.pending`. Type-only; `Policy` must be `Void`.
    @_disfavoredOverload
    public convenience init(wrappedValue: Value, _: S.Type)
        where Status == SourceStatus<S.Failure>, S.Policy == Void {
        self.init(wrappedValue: wrappedValue, policy: ())
    }

    /// Atomic sourced Value. Status starts `.pending`. Passes `policy` to `provide` and `dropped`.
    public convenience init(wrappedValue: Value, _ policy: S.Policy)
        where Status == SourceStatus<S.Failure> {
        self.init(wrappedValue: wrappedValue, policy: policy)
    }

    /// Designated init. App call site is unlabeled ``init(wrappedValue:_:)``.
    /// A Satellite pins `S` by forwarding here; `S.Policy` does not reverse-infer `S`.
    @_disfavoredOverload
    public init(wrappedValue: Value, policy: S.Policy)
        where Status == SourceStatus<S.Failure> {
        self.storage = wrappedValue
        self.seed = wrappedValue
        self.policy = policy
        self.statusStorage = .pending
        self.isKeyed = false
        self.deliverWriter = { [weak self] value, _ in
            self?.writeAtomicDeliver(value)
        }
        self.failWriter = { [weak self] error, _ in
            self?.writeAtomicFail(error)
        }
        self.clearWriter = { [weak self] _ in
            self?.writeAtomicClear()
        }
    }

    /// Keyed sourced Value. Per-key status starts missing and is seeded `.pending` on first read.
    /// Type-only; `Policy` must be `Void`.
    public convenience init<Key: Hashable, Output>(wrappedValue: [Key: Output], _: S.Type)
        where Value == [Key: Output], Status == [Key: SourceStatus<S.Failure>], S.Policy == Void {
        self.init(wrappedValue: wrappedValue, policy: ())
    }

    /// Keyed sourced Value. Per-key status starts missing and is seeded `.pending` on first read.
    /// Passes `policy` to `provide` and `dropped`.
    public convenience init<Key: Hashable, Output>(wrappedValue: [Key: Output], _ policy: S.Policy)
        where Value == [Key: Output], Status == [Key: SourceStatus<S.Failure>] {
        self.init(wrappedValue: wrappedValue, policy: policy)
    }

    /// Designated keyed init. App call site is unlabeled ``init(wrappedValue:_:)``.
    /// A Satellite pins `S` by forwarding here; `S.Policy` does not reverse-infer `S`.
    @_disfavoredOverload
    public init<Key: Hashable, Output>(wrappedValue: [Key: Output], policy: S.Policy)
        where Value == [Key: Output], Status == [Key: SourceStatus<S.Failure>] {
        self.storage = wrappedValue
        self.seed = wrappedValue
        self.policy = policy
        self.statusStorage = [:]
        self.isKeyed = true
        self.deliverWriter = { [weak self] value, key in
            guard let self, let typedKey = key?.base as? Key else { return }
            guard let typed = value as? Output else {
                preconditionFailure("Source deliver type \(type(of: value)), expected \(Output.self)")
            }
            self.storage[typedKey] = typed
            self.statusStorage[typedKey] = .settled
        }
        self.failWriter = { [weak self] error, key in
            guard let self, let typedKey = key?.base as? Key else { return }
            guard let typed = error as? S.Failure else {
                preconditionFailure("Source fail type \(type(of: error)), expected \(S.Failure.self)")
            }
            self.statusStorage[typedKey] = .error(typed)
        }
        self.clearWriter = { [weak self] key in
            guard let self, let typedKey = key?.base as? Key else { return }
            self.storage[typedKey] = self.seed[typedKey]
            self.statusStorage[typedKey] = .pending
        }
        self.seedPending = { [weak self] key in
            guard let self, let typedKey = key?.base as? Key else { return }
            if self.statusStorage[typedKey] == nil {
                self.statusStorage[typedKey] = .pending
            }
        }
    }

    /// Reads and writes the sourced Value through the enclosing Container.
    public static subscript<Storage: StateContainer>(
        _enclosingInstance instance: Storage,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Storage, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Storage, AsyncState<S, Value, Status>>
    ) -> Value {
        get {
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.sourcedKeyPath = wrappedKeyPath
            wrapper.storageValueKeyPath = storageKeyPath.appending(path: \.storage)
            wrapper.installProvideOpener(sourced: wrappedKeyPath)
            SharedEnvironment.noteHandleRead(wrapper)
            return wrapper.storage
        }
        set {
            instance[keyPath: storageKeyPath].storage = newValue
        }
    }

    /// Reads `$property` through the enclosing Container. Status-first read still needs a writable Address for `provide`.
    public static subscript<Storage: StateContainer>(
        _enclosingInstance instance: Storage,
        projected projectedKeyPath: KeyPath<Storage, AsyncState<S, Value, Status>>,
        storage storageKeyPath: ReferenceWritableKeyPath<Storage, AsyncState<S, Value, Status>>
    ) -> AsyncState<S, Value, Status> {
        get {
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.statusKeyPath = projectedKeyPath.appending(path: \.status)
            let sourcedStorage = storageKeyPath.appending(path: \.storage)
            wrapper.storageValueKeyPath = sourcedStorage
            if wrapper.provideOpener == nil {
                // `$property.storage` is read-only; `_property.storage` is writable so `deliver` can round-trip.
                wrapper.installProvideOpener(sourced: sourcedStorage)
            }
            SharedEnvironment.noteHandleRead(wrapper)
            return wrapper
        }
    }

    private func installProvideOpener<Storage: StateContainer>(
        sourced: KeyPath<Storage, Value>
    ) {
        let policy = self.policy
        provideOpener = { source, env, key in
            if let key, let dictType = Value.self as? any AsyncStateDictionary.Type {
                Self.provideKeyedDictionary(
                    dictType,
                    source: source,
                    env: env,
                    sourced: sourced,
                    key: key,
                    policy: policy
                )
                return
            }
            source.provide(sourced, policy: policy, in: env)
        }
        droppedOpener = { source, key in
            if let key, let dictType = Value.self as? any AsyncStateDictionary.Type {
                Self.droppedKeyedDictionary(
                    dictType,
                    source: source,
                    sourced: sourced,
                    key: key,
                    policy: policy
                )
                return
            }
            source.dropped(sourced, policy: policy)
        }
    }

    /// Opens `Value` as `[Key: Output]` so keyed `dropped` is not lost to overload resolution.
    private static func droppedKeyedDictionary<Storage: StateContainer, D: AsyncStateDictionary>(
        _ type: D.Type,
        source: S,
        sourced: KeyPath<Storage, Value>,
        key: AnyHashable,
        policy: S.Policy
    ) {
        guard let typedKey = key.base as? D.DictKey else { return }
        guard let dictPath = sourced as? KeyPath<Storage, [D.DictKey: D.DictOutput]> else {
            source.dropped(sourced, policy: policy)
            return
        }
        source.dropped(dictPath, key: typedKey, policy: policy)
    }

    /// Opens `Value` as `[Key: Output]` so keyed `provide` is not lost to overload resolution.
    private static func provideKeyedDictionary<Storage: StateContainer, D: AsyncStateDictionary>(
        _ type: D.Type,
        source: S,
        env: SourceEnvironment,
        sourced: KeyPath<Storage, Value>,
        key: AnyHashable,
        policy: S.Policy
    ) {
        guard let typedKey = key.base as? D.DictKey else { return }
        guard let dictPath = sourced as? KeyPath<Storage, [D.DictKey: D.DictOutput]> else {
            source.provide(sourced, policy: policy, in: env)
            return
        }
        source.provide(dictPath, key: typedKey, policy: policy, in: env)
    }

    private func writeAtomicDeliver(_ value: Any) {
        guard let typed = value as? Value else {
            preconditionFailure("Source deliver type \(type(of: value)), expected \(Value.self)")
        }
        storage = typed
        if let next = SourceStatus<S.Failure>.settled as? Status {
            statusStorage = next
        }
    }

    private func writeAtomicFail(_ error: any Error) {
        guard let typed = error as? S.Failure else {
            preconditionFailure("Source fail type \(type(of: error)), expected \(S.Failure.self)")
        }
        if let next = SourceStatus<S.Failure>.error(typed) as? Status {
            statusStorage = next
        }
    }

    private func writeAtomicClear() {
        storage = seed
        if let next = SourceStatus<S.Failure>.pending as? Status {
            statusStorage = next
        }
    }
}

extension AsyncState: AsyncStateHandle {
    var sourceTypeID: ObjectIdentifier { ObjectIdentifier(S.self) }

    func resolveSource(in env: SharedEnvironment) -> any Source {
        env.sourceInstance(S.self)
    }

    func callProvide(_ source: any Source, _ env: SourceEnvironment, key: AnyHashable?) {
        guard let typed = source as? S else { return }
        provideOpener?(typed, env, key)
    }

    func callDropped(_ source: any Source, key: AnyHashable?) {
        guard let typed = source as? S else { return }
        droppedOpener?(typed, key)
    }

    func writeDeliver(_ value: Any, key: AnyHashable?) {
        deliverWriter?(value, key)
    }

    func writeFail(_ error: any Error, key: AnyHashable?) {
        failWriter?(error, key)
    }

    func writeClear(key: AnyHashable?) {
        clearWriter?(key)
    }

    func seedKeyedPending(key: AnyHashable?) {
        seedPending?(key)
    }
}
