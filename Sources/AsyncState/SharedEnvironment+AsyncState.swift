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

extension SharedEnvironment {

    /// Calls `onRead` for a sourced Address without a Watch. Same as first read.
    ///
    /// The `$` Address is the argument, so a keyed Address cannot bind this spelling.
    public func preheat<Storage: StateContainer, S: AsyncStrategy, Value>(
        _ address: KeyPath<Storage, AsyncState<S, NoKey, Value, Value>>
    ) {
        _ = asyncState.sourcedWrapper(keyPath: address, key: nil)
    }

    /// Calls `onRead` for these entries of a keyed sourced Address without a Watch.
    /// A keyless keyed call does not compile.
    public func preheat<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<S, Key, Entry, [Key: Entry]>>,
        keys: Set<Key>
    ) {
        for key in keys {
            _ = asyncState.sourcedWrapper(keyPath: address, key: AnyHashable(key))
        }
    }

    /// `Watch.$property.refresh()`, addressed by the ValueID the Watch reads.
    func refreshAddress(valueID: ValueID) {
        asyncState.refresh(at: valueID)
    }

    /// The standing Environment every strategy of this Environment is built with.
    func strategyEnvironment() -> AsyncStrategyEnvironment {
        asyncState.strategyEnvironment()
    }

    /// Seats a prebuilt strategy instance, so a test can hold the same object the seam calls.
    func install<S: AsyncStrategy>(_ strategy: S) {
        asyncState.install(strategy)
    }

    /// The one instance this Environment owns for `type`, built on first use.
    func strategyInstance<S: AsyncStrategy>(_ type: S.Type) -> S {
        asyncState.strategyInstance(type)
    }
}
