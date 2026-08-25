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
    category: "AsyncStrategy"
)

/// Why a waiter on a sourced Address woke up.
enum SourcedResume {
    /// `apply`, `fail`, or an app write landed. Consult the status.
    case inbound
    /// `reset` or Cancel let the waiter go. Return the current Value, never throw.
    case released
}

extension SharedEnvironment {

    // MARK: - Awaitable read of the `$` Address

    /// Awaits the sourced Value at a `$` Address. `.settled` returns, `.error` throws,
    /// `.pending` or dirty waits for `apply` / `fail`.
    ///
    /// `subscribe` receives the notified ``ValueID`` before the wait, so a Service can stay
    /// subscribed while it awaits. An Operation passes `nil` and leaves no receiver behind.
    func awaitSourced<Storage: StateContainer, S: AsyncStrategy, Value>(
        _ keyPath: KeyPath<Storage, AsyncState<S, Value, SourceStatus<S.Failure>>>,
        subscribe: ((ValueID) -> Void)?
    ) async throws(S.Failure) -> Value {
        let wrapper = getSourcedWrapper(keyPath: keyPath, key: nil)
        let record = strategyRecords[ValueID(keyPath: keyPath)]
        subscribe?(record?.sourcedID ?? ValueID(keyPath: keyPath))

        while true {
            let dirty = record?.dirty ?? false
            switch wrapper.statusStorage {
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

    /// Awaits one key of a keyed sourced Address. A waiter on one key is not resumed by
    /// another key's `apply`.
    func awaitSourced<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Output>(
        _ keyPath: KeyPath<Storage, AsyncState<S, [Key: Output], [Key: SourceStatus<S.Failure>]>>,
        key: Key,
        subscribe: ((ValueID) -> Void)?
    ) async throws(S.Failure) -> Output? {
        let anyKey = AnyHashable(key)
        let wrapper = getSourcedWrapper(keyPath: keyPath, key: anyKey)
        let record = strategyRecords[ValueID(keyPath: keyPath, key: anyKey)]
        subscribe?(record?.sourcedID ?? ValueID(keyPath: keyPath, key: anyKey))

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

    // MARK: - Refresh

    /// `AsyncState.refresh()`: dirty plus kick `onRead`. Status is unchanged until `apply` / `fail`.
    func refreshHandle(_ handle: any AsyncStateHandle, key: AnyHashable?) {
        if handle.isKeyed, key == nil {
            sourcedLogger.debug("refresh() on a keyed Address needs a key: no-op")
            return
        }
        guard let record = boundRecord(for: handle, key: key) else {
            sourcedLogger.debug("refresh() before the Address was read: no-op")
            return
        }
        kickRefresh(record)
    }

    /// `Watch.$property.refresh()`: same Operation, addressed by the ValueID the Watch reads.
    func refreshAddress(valueID: ValueID) {
        guard let record = strategyRecords[valueID] else {
            sourcedLogger.debug("refresh() of an Address with no AsyncStrategy: no-op")
            return
        }
        kickRefresh(record)
    }

    private func boundRecord(
        for handle: any AsyncStateHandle,
        key: AnyHashable?
    ) -> StrategyRecord? {
        strategyRecords.values.first { record in
            ObjectIdentifier(record.handle) == ObjectIdentifier(handle) && record.key == key
        }
    }

    /// One Sync Operation: dirty, then kick. No Value and no status change, so nothing to notify.
    private func kickRefresh(_ record: StrategyRecord) {
        perform(StrategyWrite { env in
            record.dirty = true
            env.callOnRead(record)
        })
    }
}
