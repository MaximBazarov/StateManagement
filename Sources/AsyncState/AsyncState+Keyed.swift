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

/// The Keyed half of `@AsyncState`: a dictionary Value, one Address per entry.
///
/// The dictionary at the Value Address stays readable and Watchable and is never a seam Address.
/// A read of it binds the handle and kicks nothing; a read of an entry kicks.
extension AsyncState where Value == [Key: Entry] {

    /// Companion status at `$property.status`, one entry per key.
    public var status: [Key: AsyncStateStatus<S.Failure>] {
        AsyncStateRuntime.noteHandleRead(self)
        return statusStorage
    }

    /// Marks these entries Stale and calls `onRead` again for each, in one Operation.
    ///
    /// Synchronous. A key's status does not change until the strategy calls `apply` or `fail`, so
    /// a `.settled` entry keeps serving its Value while the reload runs.
    ///
    /// No-op (logged) before the Address has been read.
    public func refresh(keys: Set<Key>) {
        guard let environment = boundEnvironment else {
            asyncStateLogger.debug("refresh(keys:) before the Address was read: no-op")
            return
        }
        environment.asyncState.refresh(handle: self, keys: keys.map { AnyHashable($0) })
    }

    // MARK: - Kicks

    func installKicks<Storage: StateContainer>(
        dollar: KeyPath<Storage, AsyncState<S, Key, Entry, [Key: Entry]>>
    ) {
        let policy = self.policy
        onReadKick = { [weak self] strategy, key in
            guard let self, let typed = self.resolveKey(key) else { return }
            strategy.onRead(dollar, key: typed, policy: policy, current: self.storage[typed])
        }
        onWriteKick = { [weak self] strategy, key in
            guard let self, let typed = self.resolveKey(key) else { return }
            guard let entry = self.storage[typed] else { return }
            strategy.onWrite(dollar, key: typed, policy: policy, value: entry)
        }
        onDropKick = { [weak self] strategy, key in
            guard let self, let typed = self.resolveKey(key) else { return }
            strategy.onDrop(dollar, key: typed, policy: policy)
        }
    }

    // MARK: - Inbound

    /// `nil` settles a key the strategy found missing upstream, without inventing an entry.
    func applyInbound(_ value: Entry?, key: Key) {
        if let value {
            storage[key] = value
        }
        statusStorage[key] = .settled
    }

    func failInbound(_ error: S.Failure, key: Key) {
        statusStorage[key] = .error(error)
    }
}
