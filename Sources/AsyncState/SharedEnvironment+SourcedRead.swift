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

private let sourcedLogger = Logger(
    subsystem: "StateManagement",
    category: "AsyncState"
)

/// Why a waiter on a sourced Address woke up.
enum SourcedResume {
    /// `apply`, `fail`, or an app write landed. Consult the status.
    case inbound
    /// `reset` or Cancel let the waiter go. Return the current Value, never throw.
    case released
}

extension SharedEnvironment {

    /// Awaits the sourced Value at a `$` Address. `.settled` returns, `.error` throws,
    /// `.pending` or Stale waits for `apply` / `fail`.
    ///
    /// `subscribe` receives the notified ``ValueID`` before the wait, so a Service can stay
    /// subscribed while it awaits. An Operation passes `nil` and leaves no receiver behind.
    func awaitSourced<Storage: StateContainer, S: AsyncStrategy, Value>(
        _ address: KeyPath<Storage, AsyncState<S, NoKey, Value, Value>>,
        subscribe: ((ValueID) -> Void)?
    ) async throws(S.Failure) -> Value {
        let wrapper = asyncState.sourcedWrapper(keyPath: address, key: nil)
        let record = asyncState.record(at: ValueID(keyPath: address))
        subscribe?(record?.sourcedID ?? ValueID(keyPath: address))

        while true {
            let dirty = record?.dirty ?? false
            switch wrapper.statusStorage[.noKey] ?? .pending {
            case .settled where !dirty:
                return wrapper.storage
            case .error(let failure) where !dirty:
                throw failure
            default:
                break
            }
            guard let record else {
                // No record means the Address is not backed by a strategy after all.
                sourcedLogger.debug("Awaitable read of an unbound Address returns the current Value")
                return wrapper.storage
            }
            if await waitForInbound(record) == .released {
                return wrapper.storage
            }
        }
    }

    /// Awaits one entry of a keyed sourced Address. A waiter on one key is not resumed by
    /// another key's `apply`.
    func awaitSourced<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Entry>(
        _ address: KeyPath<Storage, AsyncState<S, Key, Entry, [Key: Entry]>>,
        key: Key,
        subscribe: ((ValueID) -> Void)?
    ) async throws(S.Failure) -> Entry? {
        let anyKey = AnyHashable(key)
        let wrapper = asyncState.sourcedWrapper(keyPath: address, key: anyKey)
        let record = asyncState.record(at: ValueID(keyPath: address, key: anyKey))
        subscribe?(record?.sourcedID ?? ValueID(keyPath: address, key: anyKey))

        while true {
            let dirty = record?.dirty ?? false
            switch wrapper.statusStorage[key] {
            case .settled where !dirty:
                return wrapper.storage[key]
            case .error(let failure) where !dirty:
                throw failure
            default:
                break
            }
            guard let record else {
                sourcedLogger.debug("Awaitable read of an unbound Address returns the current Value")
                return wrapper.storage[key]
            }
            if await waitForInbound(record) == .released {
                return wrapper.storage[key]
            }
        }
    }

    /// Suspends until this Address gets inbound State, or until `reset` / Cancel releases it.
    private func waitForInbound(_ record: StrategyRecord) async -> SourcedResume {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SourcedResume, Never>) in
                record.addWaiter(token) { resume in
                    continuation.resume(returning: resume)
                }
            }
        } onCancel: {
            // The handler runs off the main actor; hop back to release this one waiter.
            Task { @MainActor in
                record.resumeWaiter(token, with: .released)
            }
        }
    }
}
