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

extension EnvironmentService {

    /// Awaits the sourced Value at a `$` Address, subscribing the way a plain `read` does.
    ///
    /// `.settled` returns the Value with no kick. `.pending` or Stale kicks `onRead`, or Joins the
    /// kick already in flight, and waits for `apply` / `fail`. `.error` throws the stored `Failure`.
    ///
    /// The subscription outlives the wait, so the inbound `apply` that resumes this call also
    /// schedules the next ``EnvironmentService/serve()``. A strategy whose `onRead` returns without
    /// `apply` or `fail` leaves this call suspended; `reset` releases it with the current Value.
    public func read<Storage: StateContainer, S: AsyncStrategy, Value>(
        _ address: KeyPath<Storage, AsyncState<S, NoKey, Value, Value>>
    ) async throws(S.Failure) -> Value {
        // A dropped Service must not recreate a Container by reading, and must not wait.
        guard !isDropped else { return Storage()[keyPath: address].storage }
        return try await env.awaitSourced(address) { [weak self] valueID in
            guard let self else { return }
            self.env.observation.subscribe(receiver: self.notificationReceiver, valueID: valueID)
        }
    }

    /// Awaits one entry of a keyed sourced Address, subscribing to that key.
    public func read<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<S, Key, Entry, [Key: Entry]>>,
        key: Key
    ) async throws(S.Failure) -> Entry? {
        guard !isDropped else { return Storage()[keyPath: address].storage[key] }
        return try await env.awaitSourced(address, key: key) { [weak self] valueID in
            guard let self else { return }
            self.env.observation.subscribe(receiver: self.notificationReceiver, valueID: valueID)
        }
    }
}
