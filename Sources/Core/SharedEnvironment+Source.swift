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
final class SourceRecord {
    let handle: any AsyncStateHandle
    var sourcedID: ValueID?
    var statusID: ValueID?
    var dirty = false
    var didProvide = false
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
        let record = record(for: handle, valueID: valueID, keyPath: keyPath, key: key)
        handle.seedKeyedPending(key: key)
        if !record.didProvide {
            record.didProvide = true
            provide(record)
            return
        }
        if record.dirty {
            provide(record)
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

    private func record<Storage: StateContainer, Value>(
        for handle: any AsyncStateHandle,
        valueID: ValueID,
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> SourceRecord {
        if let existing = sourceRecords[valueID] {
            classify(existing, valueID: valueID, keyPath: keyPath, handle: handle)
            return existing
        }
        if let existing = uniqueRecords.first(where: {
            ObjectIdentifier($0.handle) == ObjectIdentifier(handle) && $0.key == key
        }) {
            sourceRecords[valueID] = existing
            classify(existing, valueID: valueID, keyPath: keyPath, handle: handle)
            return existing
        }
        let created = SourceRecord(handle: handle, key: key)
        sourceRecords[valueID] = created
        classify(created, valueID: valueID, keyPath: keyPath, handle: handle)
        return created
    }

    private var uniqueRecords: [SourceRecord] {
        var seen: [ObjectIdentifier: SourceRecord] = [:]
        for record in sourceRecords.values {
            seen[ObjectIdentifier(record)] = record
        }
        return Array(seen.values)
    }

    private func classify<Storage: StateContainer, Value>(
        _ record: SourceRecord,
        valueID: ValueID,
        keyPath: KeyPath<Storage, Value>,
        handle: any AsyncStateHandle
    ) {
        if handle.statusKeyPath == keyPath {
            record.statusID = valueID
        }
        if handle.sourcedKeyPath == keyPath {
            record.sourcedID = valueID
        }
        if record.sourcedID == nil, record.statusID == nil {
            record.sourcedID = valueID
        }
    }

    private func provide(_ record: SourceRecord) {
        let source = record.handle.resolveSource(in: self)
        let env = SourceEnvironment(self)
        record.handle.callProvide(source, env, key: record.key)
    }

    func applySourceDeliver<Storage: StateContainer, Value>(
        _ value: Value,
        keyPath: KeyPath<Storage, Value>
    ) {
        let record = recordMatching(keyPath: keyPath, key: nil)
        record?.handle.writeDeliver(value, key: nil)
        record?.dirty = false
        notifySource(record)
    }

    func applySourceKeyedDeliver<Storage: StateContainer, Key: Hashable, Value>(
        _ value: Value,
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: AnyHashable
    ) {
        let record = recordMatching(keyPath: keyPath, key: key)
        record?.handle.writeDeliver(value, key: key)
        record?.dirty = false
        notifySource(record)
    }

    func applySourceFail<Storage: StateContainer, Value>(
        _ error: any Error,
        keyPath: KeyPath<Storage, Value>
    ) {
        let record = recordMatching(keyPath: keyPath, key: nil)
        record?.handle.writeFail(error, key: nil)
        record?.dirty = false
        if let statusID = record?.statusID {
            observation.invalidateValue(at: statusID)
        }
    }

    func applySourceKeyedFail<Storage: StateContainer, Key: Hashable, Value>(
        _ error: any Error,
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: AnyHashable
    ) {
        let record = recordMatching(keyPath: keyPath, key: key)
        record?.handle.writeFail(error, key: key)
        record?.dirty = false
        if let statusID = record?.statusID {
            observation.invalidateValue(at: statusID)
        }
    }

    func applySourceClear<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>
    ) {
        let record = recordMatching(keyPath: keyPath, key: nil)
        record?.handle.writeClear(key: nil)
        record?.dirty = false
        notifySource(record)
    }

    func applySourceKeyedClear<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: AnyHashable
    ) {
        let record = recordMatching(keyPath: keyPath, key: key)
        record?.handle.writeClear(key: key)
        record?.dirty = false
        notifySource(record)
    }

    func applySourceInvalidate<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>
    ) {
        let record = recordMatching(keyPath: keyPath, key: nil)
        record?.dirty = true
        if let sourcedID = record?.sourcedID {
            observation.invalidateValue(at: sourcedID)
        }
    }

    func applySourceKeyedInvalidate<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: AnyHashable
    ) {
        let record = recordMatching(keyPath: keyPath, key: key)
        record?.dirty = true
        if let sourcedID = record?.sourcedID {
            observation.invalidateValue(at: sourcedID)
        }
    }

    private func recordMatching<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> SourceRecord? {
        let id = makeValueID(keyPath: keyPath, key: key)
        if let record = sourceRecords[id] {
            return record
        }
        if let match = uniqueRecords.first(where: { record in
            record.key == key && Self.addressMatches(record.handle, keyPath: keyPath)
        }) {
            sourceRecords[id] = match
            match.sourcedID = id
            return match
        }
        _ = getValue(keyPath: keyPath)
        if let record = sourceRecords[id] {
            return record
        }
        return uniqueRecords.first { record in
            record.key == key && Self.addressMatches(record.handle, keyPath: keyPath)
        }
    }

    private static func addressMatches(_ handle: any AsyncStateHandle, keyPath: AnyKeyPath) -> Bool {
        handle.sourcedKeyPath == keyPath || handle.storageValueKeyPath == keyPath
    }

    private func notifySource(_ record: SourceRecord?) {
        guard let record else { return }
        if let sourcedID = record.sourcedID {
            observation.invalidateValue(at: sourcedID)
        }
        if let statusID = record.statusID {
            observation.invalidateValue(at: statusID)
        }
    }

    func dropAllRecords() {
        for record in uniqueRecords {
            endRecord(record)
        }
        sourceRecords.removeAll()
    }

    func dropRecords<Storage: StateContainer>(in type: Storage.Type) {
        var kept: [ValueID: SourceRecord] = [:]
        var ended: Set<ObjectIdentifier> = []
        for (id, record) in sourceRecords {
            if recordBelongs(record, to: type) {
                let token = ObjectIdentifier(record)
                if ended.insert(token).inserted {
                    endRecord(record)
                }
            } else {
                kept[id] = record
            }
        }
        sourceRecords = kept
    }

    private func recordBelongs<Storage: StateContainer>(
        _ record: SourceRecord,
        to type: Storage.Type
    ) -> Bool {
        record.handle.sourcedKeyPath is PartialKeyPath<Storage>
            || record.handle.statusKeyPath is PartialKeyPath<Storage>
            || record.handle.storageValueKeyPath is PartialKeyPath<Storage>
    }

    private func endRecord(_ record: SourceRecord) {
        let source = record.handle.resolveSource(in: self)
        record.handle.callDropped(source, key: record.key)
    }
}
