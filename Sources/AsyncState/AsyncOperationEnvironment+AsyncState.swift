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

extension AsyncOperationEnvironment {

    /// Awaits the sourced Value at a `$` Address.
    ///
    /// `.settled` returns the Value with no kick. `.pending` or Stale kicks `onRead`, or Joins the
    /// kick already in flight, and waits for `apply` / `fail`. `.error` throws the stored `Failure`.
    ///
    /// A one-shot wait: it leaves no receiver behind. A strategy whose `onRead` returns without
    /// `apply` or `fail` leaves this call suspended; `reset` and Cancel release it with the
    /// current Value.
    public func read<Storage: StateContainer, S: AsyncStrategy, Value>(
        _ address: KeyPath<Storage, AsyncState<S, NoKey, Value, Value>>
    ) async throws(S.Failure) -> Value {
        try await environment.awaitSourced(address, subscribe: nil)
    }

    /// Awaits one entry of a keyed sourced Address. Another key's `apply` does not resume this wait.
    public func read<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<S, Key, Entry, [Key: Entry]>>,
        key: Key
    ) async throws(S.Failure) -> Entry? {
        try await environment.awaitSourced(address, key: key, subscribe: nil)
    }
}
