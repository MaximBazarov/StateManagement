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

private let asyncStateLogger = Logger(
    subsystem: "StateManagement",
    category: "AsyncStrategy"
)

/// Marks `[Key: Output]` so a keyed sourced Address can call `AsyncStrategy` with the entry key.
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
    var dollarKeyPath: AnyKeyPath? { get set }
    var wrapperKeyPath: AnyKeyPath? { get set }
    var sourceTypeID: ObjectIdentifier { get }

    func resolveStrategy(in env: SharedEnvironment) -> any AsyncStrategy
    func callOnRead(_ strategy: any AsyncStrategy, key: AnyHashable?)
    func callOnWrite<Value>(_ strategy: any AsyncStrategy, value: Value)
    func callOnWrite<Key: Hashable, Output>(_ strategy: any AsyncStrategy, value: Output, key: Key)
    func callOnDrop(_ strategy: any AsyncStrategy, key: AnyHashable?)
    func writeDeliver<Value>(_ value: Value)
    func writeDeliver<Key: Hashable, Output>(_ value: Output, key: Key)
    func writeFail(_ error: any Error, key: AnyHashable?)
    func writeClear(key: AnyHashable?)
    func seedKeyedPending(key: AnyHashable?)
    func bind(environment: SharedEnvironment)
}

/// Declares that an Atomic or Keyed Value is backed by an AsyncStrategy. `$property` is this wrapper, not a Value.
///
/// Companion status is `$property.status`. First read of either Address, or `preheat`, calls
/// ``AsyncStrategy/onRead(_:policy:current:)`` with the `$` Address. Policy is stored here and passed into `onRead`, `onWrite`, and `onDrop`.
@propertyWrapper
@MainActor
public final class AsyncState<S: AsyncStrategy, Value, Status> {
    var storage: Value
    let seed: Value
    let policy: S.Policy
    var statusStorage: Status
    let isKeyed: Bool

    var sourcedKeyPath: AnyKeyPath?
    var statusKeyPath: AnyKeyPath?
    var storageValueKeyPath: AnyKeyPath?
    var dollarKeyPath: AnyKeyPath?
    var wrapperKeyPath: AnyKeyPath?
    /// The Environment that read this Address. `refresh()` needs it, and the Environment
    /// owns the Container that owns this wrapper, so the reference is weak.
    weak var boundEnvironment: SharedEnvironment?
    var onReadOpener: ((S, AnyHashable?) -> Void)?
    var onWriteAtomic: ((S, Value) -> Void)?
    var onDropOpener: ((S, AnyHashable?) -> Void)?
    var failWriter: ((any Error, AnyHashable?) -> Void)?
    var clearWriter: ((AnyHashable?) -> Void)?
    var seedPending: ((AnyHashable?) -> Void)?
    var keyedWriteBox: ((S, Any, AnyHashable) -> Void)?
    var keyedDeliverBox: ((Any, AnyHashable) -> Void)?

    /// The wrapper itself. `$property` is this value, not the sourced Value.
    public var projectedValue: AsyncState { self }

    /// Companion status at `$property.status`.
    public var status: Status {
        get {
            SharedEnvironment.noteHandleRead(self)
            return statusStorage
        }
        set { statusStorage = newValue }
    }

    /// Marks this Address Stale and calls `onRead` again.
    ///
    /// Synchronous. ``status`` does not change until the strategy calls `apply` or `fail`, so a
    /// `.settled` Address keeps serving its Value while the reload runs. To await the reload,
    /// `read` the `$` Address from an Operation or a Service.
    ///
    /// No-op (logged) before the Address has been read, and on a keyed Address, which needs
    /// ``refresh(key:)``.
    public func refresh() {
        guard let environment = boundEnvironment else {
            asyncStateLogger.debug("refresh() before the Address was read: no-op")
            return
        }
        environment.refreshHandle(self, key: nil)
    }

    /// Marks one key of a keyed Address Stale and calls `onRead` again for that key.
    public func refresh<Key: Hashable, Output>(key: Key)
        where Value == [Key: Output], Status == [Key: SourceStatus<S.Failure>] {
        guard let environment = boundEnvironment else {
            asyncStateLogger.debug("refresh(key:) before the Address was read: no-op")
            return
        }
        environment.refreshHandle(self, key: AnyHashable(key))
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

    /// Atomic sourced Value. Status starts `.pending`. Passes `policy` to `onRead`, `onWrite`, and `onDrop`.
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
    /// Passes `policy` to `onRead`, `onWrite`, and `onDrop`.
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
        self.keyedDeliverBox = { [weak self] value, key in
            guard let self, let typedKey = key.base as? Key else { return }
            guard let typed = value as? Output else {
                preconditionFailure("AsyncStrategy apply type \(type(of: value)), expected \(Output.self)")
            }
            self.storage[typedKey] = typed
            self.statusStorage[typedKey] = .settled
        }
        self.failWriter = { [weak self] error, key in
            guard let self, let typedKey = key?.base as? Key else { return }
            guard let typed = error as? S.Failure else {
                preconditionFailure("AsyncStrategy fail type \(type(of: error)), expected \(S.Failure.self)")
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
            wrapper.bindValuePath(wrappedKeyPath, storageKeyPath: storageKeyPath)
            wrapper.installOpenersIfNeeded(dollar: storageKeyPath)
            SharedEnvironment.noteHandleRead(wrapper)
            return wrapper.storage
        }
        set {
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.bindValuePath(wrappedKeyPath, storageKeyPath: storageKeyPath)
            wrapper.installOpenersIfNeeded(dollar: storageKeyPath)
            SharedEnvironment.noteHandleRead(wrapper)
            wrapper.storage = newValue
        }
    }

    /// Reads `$property` through the enclosing Container.
    public static subscript<Storage: StateContainer>(
        _enclosingInstance instance: Storage,
        projected projectedKeyPath: KeyPath<Storage, AsyncState<S, Value, Status>>,
        storage storageKeyPath: ReferenceWritableKeyPath<Storage, AsyncState<S, Value, Status>>
    ) -> AsyncState<S, Value, Status> {
        get {
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.bindDollarPath(projectedKeyPath, storageKeyPath: storageKeyPath)
            wrapper.installOpenersIfNeeded(dollar: projectedKeyPath)
            SharedEnvironment.noteHandleRead(wrapper)
            return wrapper
        }
    }

    private func bindValuePath<Storage: StateContainer>(
        _ wrappedKeyPath: ReferenceWritableKeyPath<Storage, Value>,
        storageKeyPath: ReferenceWritableKeyPath<Storage, AsyncState<S, Value, Status>>
    ) {
        sourcedKeyPath = wrappedKeyPath
        storageValueKeyPath = storageKeyPath.appending(path: \.storage)
        wrapperKeyPath = storageKeyPath
    }

    private func bindDollarPath<Storage: StateContainer>(
        _ projectedKeyPath: KeyPath<Storage, AsyncState<S, Value, Status>>,
        storageKeyPath: ReferenceWritableKeyPath<Storage, AsyncState<S, Value, Status>>
    ) {
        statusKeyPath = projectedKeyPath.appending(path: \.status)
        storageValueKeyPath = storageKeyPath.appending(path: \.storage)
        wrapperKeyPath = storageKeyPath
        dollarKeyPath = projectedKeyPath
    }

    private func installOpenersIfNeeded<Storage: StateContainer>(
        dollar: KeyPath<Storage, AsyncState<S, Value, Status>>
    ) {
        if dollarKeyPath == nil {
            dollarKeyPath = dollar
        }
        guard onReadOpener == nil else { return }
        let policy = self.policy
        onReadOpener = { [weak self] strategy, key in
            guard let self else { return }
            if let key, let dictType = Value.self as? any AsyncStateDictionary.Type {
                Self.onReadKeyedDictionary(
                    dictType,
                    strategy: strategy,
                    dollar: dollar,
                    key: key,
                    policy: policy,
                    current: self.storage
                )
                return
            }
            strategy.onRead(dollar, policy: policy, current: self.storage)
        }
        onWriteAtomic = { strategy, value in
            strategy.onWrite(value, dollar, policy: policy)
        }
        keyedWriteBox = { strategy, value, key in
            if let dictType = Value.self as? any AsyncStateDictionary.Type {
                Self.onWriteKeyedDictionary(
                    dictType,
                    strategy: strategy,
                    dollar: dollar,
                    key: key,
                    policy: policy,
                    value: value
                )
            }
        }
        onDropOpener = { strategy, key in
            if let key, let dictType = Value.self as? any AsyncStateDictionary.Type {
                Self.onDropKeyedDictionary(
                    dictType,
                    strategy: strategy,
                    dollar: dollar,
                    key: key,
                    policy: policy
                )
                return
            }
            strategy.onDrop(dollar, policy: policy)
        }
    }

    /// Opens `Value` as `[Key: Output]` so keyed `onDrop` is not lost to overload resolution.
    private static func onDropKeyedDictionary<Storage: StateContainer, D: AsyncStateDictionary>(
        _ type: D.Type,
        strategy: S,
        dollar: KeyPath<Storage, AsyncState<S, Value, Status>>,
        key: AnyHashable,
        policy: S.Policy
    ) {
        guard let typedKey = key.base as? D.DictKey else { return }
        // AsyncState specializations are invariant, so a direct `as?` is diagnosed as always
        // failing. `Any` makes this a runtime check; Value is that dictionary when Keyed.
        guard let dictPath = dollar as Any as? KeyPath<
            Storage,
            AsyncState<S, [D.DictKey: D.DictOutput], Status>
        > else { return }
        strategy.onDrop(dictPath, key: typedKey, policy: policy)
    }

    /// Opens `Value` as `[Key: Output]` so keyed `onRead` is not lost to overload resolution.
    private static func onReadKeyedDictionary<Storage: StateContainer, D: AsyncStateDictionary>(
        _ type: D.Type,
        strategy: S,
        dollar: KeyPath<Storage, AsyncState<S, Value, Status>>,
        key: AnyHashable,
        policy: S.Policy,
        current: Value
    ) {
        guard let typedKey = key.base as? D.DictKey else { return }
        guard let dictPath = dollar as Any as? KeyPath<
            Storage,
            AsyncState<S, [D.DictKey: D.DictOutput], Status>
        > else { return }
        let entry = (current as? [D.DictKey: D.DictOutput])?[typedKey]
        strategy.onRead(dictPath, key: typedKey, policy: policy, current: entry)
    }

    /// Opens `Value` as `[Key: Output]` so keyed `onWrite` is not lost to overload resolution.
    private static func onWriteKeyedDictionary<Storage: StateContainer, D: AsyncStateDictionary>(
        _ type: D.Type,
        strategy: S,
        dollar: KeyPath<Storage, AsyncState<S, Value, Status>>,
        key: AnyHashable,
        policy: S.Policy,
        value: Any
    ) {
        guard let typedKey = key.base as? D.DictKey else { return }
        guard let dictPath = dollar as Any as? KeyPath<
            Storage,
            AsyncState<S, [D.DictKey: D.DictOutput], Status>
        > else { return }
        guard let typed = value as? D.DictOutput else {
            preconditionFailure(
                "AsyncStrategy onWrite type \(Swift.type(of: value)), expected keyed entry"
            )
        }
        strategy.onWrite(typed, dictPath, key: typedKey, policy: policy)
    }

    private func writeAtomicDeliver(_ value: Value) {
        storage = value
        if let next = SourceStatus<S.Failure>.settled as? Status {
            statusStorage = next
        }
    }

    private func writeAtomicFail(_ error: any Error) {
        guard let typed = error as? S.Failure else {
            preconditionFailure("AsyncStrategy fail type \(type(of: error)), expected \(S.Failure.self)")
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

    func resolveStrategy(in env: SharedEnvironment) -> any AsyncStrategy {
        env.strategyInstance(S.self)
    }

    func callOnRead(_ strategy: any AsyncStrategy, key: AnyHashable?) {
        guard let typed = strategy as? S else { return }
        onReadOpener?(typed, key)
    }

    func callOnWrite<Written>(_ strategy: any AsyncStrategy, value: Written) {
        guard let typed = strategy as? S else { return }
        guard let typedValue = value as? Value else {
            preconditionFailure(
                "AsyncStrategy onWrite type \(type(of: value)), expected \(Value.self)"
            )
        }
        onWriteAtomic?(typed, typedValue)
    }

    func callOnWrite<Key: Hashable, Output>(_ strategy: any AsyncStrategy, value: Output, key: Key) {
        guard let typed = strategy as? S else { return }
        keyedWriteBox?(typed, value, AnyHashable(key))
    }

    func callOnDrop(_ strategy: any AsyncStrategy, key: AnyHashable?) {
        guard let typed = strategy as? S else { return }
        onDropOpener?(typed, key)
    }

    func writeDeliver<Delivered>(_ value: Delivered) {
        guard let typed = value as? Value else {
            preconditionFailure(
                "AsyncStrategy apply type \(type(of: value)), expected \(Value.self)"
            )
        }
        writeAtomicDeliver(typed)
    }

    func writeDeliver<Key: Hashable, Output>(_ value: Output, key: Key) {
        keyedDeliverBox?(value, AnyHashable(key))
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

    func bind(environment: SharedEnvironment) {
        boundEnvironment = environment
    }
}
