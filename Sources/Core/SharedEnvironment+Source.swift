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

@MainActor
final class SourceBinding {
    let handle: any AsyncStateHandle
    var sourcedID: ValueID?
    var statusID: ValueID?
    var dirty = false
    var bound = false
    let key: AnyHashable?

    init(handle: any AsyncStateHandle, key: AnyHashable?) {
        self.handle = handle
        self.key = key
    }
}

extension SharedEnvironment {
    @MainActor
    private enum SourceAccess {
        static var current: SharedEnvironment?
    }

    static func noteHandleRead(_ handle: any AsyncStateHandle) {
        SourceAccess.current?.pendingHandle = handle
    }

    func install<S: Source>(_ source: S) {
        sourceWarehouse[ObjectIdentifier(S.self)] = source
    }

    func sourceInstance<S: Source>(_ type: S.Type) -> S {
        let id = ObjectIdentifier(S.self)
        if let existing = sourceWarehouse[id] {
            // Type is keyed by ObjectIdentifier of S.self.
            return unsafeDowncast(existing, to: S.self)
        }
        let created = S()
        sourceWarehouse[id] = created
        return created
    }

    /// Calls `provide` for a sourced Address without a Watch. Same as first read.
    public func preheat<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>
    ) {
        _ = read(keyPath)
    }

    /// Calls `provide` for a keyed sourced Address without a Watch. Same as first read.
    public func preheat<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        _ = read(keyPath, key: key)
    }

    func accessSourced<Storage: StateContainer, Value>(
        _ storage: Storage,
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> Value {
        let previousAccess = SourceAccess.current
        let previousHandle = pendingHandle
        SourceAccess.current = self
        pendingHandle = nil
        _ = storage[keyPath: keyPath]
        let handle = pendingHandle
        if let handle {
            activate(handle, keyPath: keyPath, key: key)
        }
        // First walk records the handle and may `provide`. Nested `deliver` writes before this snapshot.
        let value = storage[keyPath: keyPath]
        pendingHandle = previousHandle
        SourceAccess.current = previousAccess
        return value
    }

    func activate<Storage: StateContainer, Value>(
        _ handle: any AsyncStateHandle,
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) {
        if handle.isKeyed, key == nil {
            return
        }
        let valueID = makeValueID(keyPath: keyPath, key: key)
        let binding = binding(for: handle, valueID: valueID, keyPath: keyPath, key: key)
        handle.seedKeyedPending(key: key)
        if !binding.bound {
            binding.bound = true
            provide(binding)
            return
        }
        if binding.dirty {
            provide(binding)
        }
    }

    private func makeValueID<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> ValueID {
        if let key {
            return ValueID(keyPath: keyPath, key: key)
        }
        return ValueID(keyPath: keyPath)
    }

    private func binding<Storage: StateContainer, Value>(
        for handle: any AsyncStateHandle,
        valueID: ValueID,
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> SourceBinding {
        if let existing = sourceBinds[valueID] {
            classify(existing, valueID: valueID, keyPath: keyPath, handle: handle)
            return existing
        }
        if let existing = uniqueBinds.first(where: {
            ObjectIdentifier($0.handle) == ObjectIdentifier(handle) && $0.key == key
        }) {
            sourceBinds[valueID] = existing
            classify(existing, valueID: valueID, keyPath: keyPath, handle: handle)
            return existing
        }
        let created = SourceBinding(handle: handle, key: key)
        sourceBinds[valueID] = created
        classify(created, valueID: valueID, keyPath: keyPath, handle: handle)
        return created
    }

    private var uniqueBinds: [SourceBinding] {
        var seen: [ObjectIdentifier: SourceBinding] = [:]
        for bind in sourceBinds.values {
            seen[ObjectIdentifier(bind)] = bind
        }
        return Array(seen.values)
    }

    private func classify<Storage: StateContainer, Value>(
        _ binding: SourceBinding,
        valueID: ValueID,
        keyPath: KeyPath<Storage, Value>,
        handle: any AsyncStateHandle
    ) {
        if handle.statusKeyPath == keyPath {
            binding.statusID = valueID
        }
        if handle.sourcedKeyPath == keyPath {
            binding.sourcedID = valueID
        }
        if binding.sourcedID == nil, binding.statusID == nil {
            binding.sourcedID = valueID
        }
    }

    private func provide(_ binding: SourceBinding) {
        let source = binding.handle.resolveSource(in: self)
        let env = SourceEnvironment(self)
        binding.handle.callProvide(source, env, key: binding.key)
    }

    func applySourceDeliver<Storage: StateContainer, Value>(
        _ value: Value,
        keyPath: KeyPath<Storage, Value>
    ) {
        let binding = bindMatching(keyPath: keyPath, key: nil)
        binding?.handle.writeDeliver(value, key: nil)
        binding?.dirty = false
        notifySource(binding)
    }

    func applySourceKeyedDeliver<Storage: StateContainer, Key: Hashable, Value>(
        _ value: Value,
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: AnyHashable
    ) {
        let binding = bindMatching(keyPath: keyPath, key: key)
        binding?.handle.writeDeliver(value, key: key)
        binding?.dirty = false
        notifySource(binding)
    }

    func applySourceFail<Storage: StateContainer, Value>(
        _ error: any Error,
        keyPath: KeyPath<Storage, Value>
    ) {
        let binding = bindMatching(keyPath: keyPath, key: nil)
        binding?.handle.writeFail(error, key: nil)
        binding?.dirty = false
        if let statusID = binding?.statusID {
            observation.invalidateValue(at: statusID)
        }
    }

    func applySourceKeyedFail<Storage: StateContainer, Key: Hashable, Value>(
        _ error: any Error,
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: AnyHashable
    ) {
        let binding = bindMatching(keyPath: keyPath, key: key)
        binding?.handle.writeFail(error, key: key)
        binding?.dirty = false
        if let statusID = binding?.statusID {
            observation.invalidateValue(at: statusID)
        }
    }

    func applySourceClear<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>
    ) {
        let binding = bindMatching(keyPath: keyPath, key: nil)
        binding?.handle.writeClear(key: nil)
        binding?.dirty = false
        notifySource(binding)
    }

    func applySourceKeyedClear<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: AnyHashable
    ) {
        let binding = bindMatching(keyPath: keyPath, key: key)
        binding?.handle.writeClear(key: key)
        binding?.dirty = false
        notifySource(binding)
    }

    func applySourceInvalidate<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>
    ) {
        let binding = bindMatching(keyPath: keyPath, key: nil)
        binding?.dirty = true
        if let sourcedID = binding?.sourcedID {
            observation.invalidateValue(at: sourcedID)
        }
    }

    func applySourceKeyedInvalidate<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: AnyHashable
    ) {
        let binding = bindMatching(keyPath: keyPath, key: key)
        binding?.dirty = true
        if let sourcedID = binding?.sourcedID {
            observation.invalidateValue(at: sourcedID)
        }
    }

    private func bindMatching<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> SourceBinding? {
        let id = makeValueID(keyPath: keyPath, key: key)
        if let binding = sourceBinds[id] {
            return binding
        }
        if let match = uniqueBinds.first(where: { bind in
            bind.key == key && Self.addressMatches(bind.handle, keyPath: keyPath)
        }) {
            sourceBinds[id] = match
            match.sourcedID = id
            return match
        }
        _ = getValue(keyPath: keyPath)
        if let binding = sourceBinds[id] {
            return binding
        }
        return uniqueBinds.first { bind in
            bind.key == key && Self.addressMatches(bind.handle, keyPath: keyPath)
        }
    }

    private static func addressMatches(_ handle: any AsyncStateHandle, keyPath: AnyKeyPath) -> Bool {
        handle.sourcedKeyPath == keyPath || handle.storageValueKeyPath == keyPath
    }

    private func notifySource(_ binding: SourceBinding?) {
        guard let binding else { return }
        if let sourcedID = binding.sourcedID {
            observation.invalidateValue(at: sourcedID)
        }
        if let statusID = binding.statusID {
            observation.invalidateValue(at: statusID)
        }
    }

    func dropAllBinds() {
        for bind in uniqueBinds {
            endBind(bind)
        }
        sourceBinds.removeAll()
    }

    func dropBinds<Storage: StateContainer>(in type: Storage.Type) {
        var kept: [ValueID: SourceBinding] = [:]
        var ended: Set<ObjectIdentifier> = []
        for (id, bind) in sourceBinds {
            if bindBelongs(bind, to: type) {
                let token = ObjectIdentifier(bind)
                if ended.insert(token).inserted {
                    endBind(bind)
                }
            } else {
                kept[id] = bind
            }
        }
        sourceBinds = kept
    }

    private func bindBelongs<Storage: StateContainer>(
        _ bind: SourceBinding,
        to type: Storage.Type
    ) -> Bool {
        bind.handle.sourcedKeyPath is PartialKeyPath<Storage>
            || bind.handle.statusKeyPath is PartialKeyPath<Storage>
            || bind.handle.storageValueKeyPath is PartialKeyPath<Storage>
    }

    private func endBind(_ bind: SourceBinding) {
        let source = bind.handle.resolveSource(in: self)
        bind.handle.callDropped(source, key: bind.key)
    }
}
