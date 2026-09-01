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

/// The Atomic half of `@AsyncState`: one whole fact at one name.
///
/// The kicks and the two enclosing-instance subscripts live here rather than in the class body,
/// because only under `Key == NoKey, Value == Entry` is the Atomic half of the strategy's verb
/// table the one that binds.
extension AsyncState where Key == NoKey, Value == Entry {

    /// Companion status at `$property.status`.
    public var status: AsyncStateStatus<S.Failure> {
        AsyncStateRuntime.noteHandleRead(self)
        return statusStorage[.noKey] ?? .pending
    }

    /// Marks this Address Stale and calls `onRead` again.
    ///
    /// Synchronous. `status` does not change until the strategy calls `apply` or `fail`, so a
    /// `.settled` Address keeps serving its Value while the reload runs. To await the reload,
    /// `read` the `$` Address from an Operation or a Service.
    ///
    /// No-op (logged) before the Address has been read.
    public func refresh() {
        guard let environment = boundEnvironment else {
            asyncStateLogger.debug("refresh() before the Address was read: no-op")
            return
        }
        environment.asyncState.refresh(handle: self, keys: [nil])
    }

    // MARK: - Kicks

    func installKicks<Storage: StateContainer>(
        dollar: KeyPath<Storage, AsyncState<S, NoKey, Value, Value>>
    ) {
        let policy = self.policy
        onReadKick = { [weak self] strategy, _ in
            guard let self else { return }
            strategy.onRead(dollar, policy: policy, current: self.storage)
        }
        onWriteKick = { [weak self] strategy, _ in
            guard let self else { return }
            strategy.onWrite(dollar, policy: policy, value: self.storage)
        }
        onDropKick = { strategy, _ in
            strategy.onDrop(dollar, policy: policy)
        }
    }

    // MARK: - Inbound

    func applyInbound(_ value: Value) {
        storage = value
        statusStorage[.noKey] = .settled
    }

    func failInbound(_ error: S.Failure) {
        statusStorage[.noKey] = .error(error)
    }
}
