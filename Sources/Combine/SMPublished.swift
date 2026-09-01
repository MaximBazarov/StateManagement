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

#if canImport(Combine)
import Combine
import Foundation

/// Replaces `@Published` on a ``StateContainer`` that is also `ObservableObject`.
///
/// Leftover `instance.thisValue` and `$thisValue` always use ``SharedEnvironment/shared``.
/// ``Watch``, ``Computed``, and Operations use the Environment they were given. Overriding
/// the Environment for leftover Combine is unsupported.
///
/// `$thisValue` is `Publisher<Value, Never>`, not `Published.Publisher`. `assign(to:)` is out.
///
/// A plain `var` on the same class stays per-instance. Only `@SMPublished` is Environment state.
///
/// It does not compose with ``AsyncState``: both are enclosing-instance wrappers over the same
/// stored Value, and a property carries one wrapper. Publish a sourced Value by watching it.
///
/// The class must use the default ``ObservableObjectPublisher``.
///
/// - SeeAlso: <doc:Leftover-Combine>
@propertyWrapper
@MainActor public struct SMPublished<Value> {

    var stored: Value

    public init(wrappedValue: Value) {
        stored = wrappedValue
    }

    @available(*, unavailable, message: "@SMPublished is only available on properties of classes that are StateContainer and ObservableObject")
    public var wrappedValue: Value {
        get { stored }
        set { stored = newValue }
    }

    public var projectedValue: AnyPublisher<Value, Never> {
        Empty<Value, Never>().eraseToAnyPublisher()
    }

    public static subscript<EnclosingSelf>(
        _enclosingInstance object: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, SMPublished<Value>>
    ) -> Value
    where EnclosingSelf: StateContainer & ObservableObject,
          EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher
    {
        get {
            if SharedEnvironment.warehouseAccess != nil {
                return object[keyPath: storageKeyPath].stored
            }
            return SharedEnvironment.shared.read(wrappedKeyPath)
        }
        set {
            if let env = SharedEnvironment.warehouseAccess {
                var wrapper = object[keyPath: storageKeyPath]
                wrapper.stored = newValue
                object[keyPath: storageKeyPath] = wrapper
                if env === SharedEnvironment.shared {
                    SMPublishedHub.subject(storageKeyPath).send(newValue)
                }
                return
            }

            object.objectWillChange.send()
            SMPublishedAccess.isLeftoverWriting = true
            defer { SMPublishedAccess.isLeftoverWriting = false }
            SharedEnvironment.shared.perform(
                SMPublishedWrite(keyPath: wrappedKeyPath, value: newValue)
            )
        }
    }

    public static subscript<EnclosingSelf>(
        _enclosingInstance object: EnclosingSelf,
        projected _: KeyPath<EnclosingSelf, AnyPublisher<Value, Never>>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, SMPublished<Value>>
    ) -> AnyPublisher<Value, Never>
    where EnclosingSelf: StateContainer & ObservableObject,
          EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher
    {
        let current = SharedEnvironment.shared.getStorage(EnclosingSelf.self)[keyPath: storageKeyPath].stored
        return SMPublishedHub.subject(storageKeyPath)
            .handleEvents(receiveOutput: { [weak object] _ in
                guard let object, !SMPublishedAccess.isLeftoverWriting else { return }
                object.objectWillChange.send()
            })
            .prepend(current)
            .eraseToAnyPublisher()
    }
}

@MainActor
private enum SMPublishedAccess {
    static var isLeftoverWriting = false
}

@MainActor
private enum SMPublishedHub {
    private static var subjects: [AnyKeyPath: Any] = [:]

    static func subject<Value>(_ storage: AnyKeyPath) -> PassthroughSubject<Value, Never> {
        if let existing = subjects[storage] as? PassthroughSubject<Value, Never> {
            return existing
        }
        let created = PassthroughSubject<Value, Never>()
        subjects[storage] = created
        return created
    }
}

@MainActor
private struct SMPublishedWrite<Storage: StateContainer, Value>: SyncOperation {
    let keyPath: WritableKeyPath<Storage, Value>
    let value: Value

    func perform(in env: SyncOperationEnvironment) {
        let old = env.read(keyPath)
        env.write(keyPath, value: value)
        invalidateChangedDictionaryKeys(old: old, new: value, keyPath: keyPath, env: env)
    }
}

@MainActor
private protocol SMPublishedDictionary {
    var smPublishedKeys: [AnyHashable] { get }
    func smPublishedValue(for key: AnyHashable) -> Any?
}

extension Dictionary: SMPublishedDictionary {
    var smPublishedKeys: [AnyHashable] {
        keys.map { AnyHashable($0) }
    }

    func smPublishedValue(for key: AnyHashable) -> Any? {
        guard let typed = key.base as? Key else { return nil }
        return self[typed].map { $0 as Any }
    }
}

extension Equatable {
    fileprivate func smPublishedEquals(_ other: Any) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

@MainActor
private func invalidateChangedDictionaryKeys<Storage: StateContainer, Value>(
    old: Value,
    new: Value,
    keyPath: WritableKeyPath<Storage, Value>,
    env: SyncOperationEnvironment
) {
    guard let oldDict = old as? any SMPublishedDictionary,
          let newDict = new as? any SMPublishedDictionary
    else { return }

    let keys = Set(oldDict.smPublishedKeys).union(newDict.smPublishedKeys)
    for key in keys {
        if smPublishedDiffer(oldDict.smPublishedValue(for: key), newDict.smPublishedValue(for: key)) {
            env.environment.observation.invalidateValue(
                at: ValueID(keyPath: keyPath, key: key)
            )
        }
    }
}

private func smPublishedDiffer(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil):
        return false
    case (nil, _), (_, nil):
        return true
    case let (a?, b?):
        if let a = a as? any Equatable {
            return !a.smPublishedEquals(b)
        }
        return true
    }
}
#endif
