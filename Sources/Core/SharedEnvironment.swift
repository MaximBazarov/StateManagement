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

/// Shared among all components of the system environment.
/// Unless overridden in tests or previews, ``SharedEnvironment/shared`` is used.
@MainActor public final class SharedEnvironment {

    private typealias ServiceID = ObjectIdentifier
    
    // Production instance of the environment.
    public static let shared = SharedEnvironment()

    public init() {}

    /// Cache of the ``StateContainer`` that has been read.
    private var warehouse: [StorageID: StateContainer] = [:]

    private var serviceWarehouse: [ServiceID: EnvironmentService] = [:]

    /// Storage for observing the value changes, environment reports values that has been set.
    var observation = ObservationRegistry()

    /// Grouped Executions live here so Join and newestWins share one slot per Identity.
    private var identitySlots: [ExecutionGroup: IdentitySlot] = [:]

    /// Every in-flight Execution, including `runAll`. Reset Cancels this set.
    private var liveExecutions: [UUID: Execution] = [:]

    var sourceWarehouse: [ObjectIdentifier: any Source] = [:]
    var sourceBinds: [ValueID: SourceBinding] = [:]
    var pendingHandle: (any AsyncStateHandle)?

    private struct ExecutionGroup: Hashable {
        let operationType: ObjectIdentifier
        let identity: ReentrancyIdentity
    }

    @MainActor
    private final class IdentitySlot {
        var live: Execution
        var waiters: [(Result<Void, any Error>) -> Void] = []

        init(live: Execution) {
            self.live = live
        }

        func addWaiter(_ waiter: ((Result<Void, any Error>) -> Void)?) {
            if let waiter {
                waiters.append(waiter)
            }
        }

        func cancelLive() {
            live.isCancelled = true
            live.task?.cancel()
        }

        func resumeWaiters(error: (any Error)?) {
            let result: Result<Void, any Error> = if let error {
                .failure(error)
            } else {
                .success(())
            }
            let pending = waiters
            waiters = []
            for waiter in pending {
                waiter(result)
            }
        }
    }

    // MARK: - I/O -
    /// Provides the storage of a given type
    /// that conforms to ``EnvironmentStateStorage``
    private func getStorage<Storage: StateContainer>(_ storageType: Storage.Type) -> Storage {
        let id = StorageID(storageType)

        // Trying to get existing value
        if let storage = warehouse[id] {
            return unsafeDowncast(storage, to: Storage.self)
        }

        let storage = Storage()
        warehouse[id] = storage
        return storage
    }

    // MARK: - Atomic

    /// Snapshots the Value at `keyPath`. Does not subscribe. First read of a sourced Address binds.
    public func read<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>
    ) -> Value {
        getValue(keyPath: keyPath)
    }

    /// Returns the value at the given key path from shared storage.
    func getValue<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>
    ) -> Value {
        let storage = getStorage(Storage.self)
        return accessSourced(storage, keyPath: keyPath, key: nil)
    }

    /// Sets a value at the given key path and reports a change for observation.
    func setValue<Storage: StateContainer, Value>(
        _ newValue: Value,
        keyPath: WritableKeyPath<Storage, Value>
    ) {
        var storage = getStorage(Storage.self)
        storage[keyPath: keyPath] = newValue
        let valueID = ValueID(
            keyPath: keyPath
        )
        #if STATE_MANAGEMENT_TELEMETRY_INTERNAL
        TraceContext.withSpan(
            "Set: \(valueID.debugDescription)",
            kind: .internal,
            valueDescription: String(describing: newValue)
        ) {
            observation.invalidateValue(at: valueID)
        }
        #else
        observation.invalidateValue(at: valueID)
        #endif
    }

    // MARK: - Dictionary

    /// Snapshots the keyed Value at `keyPath` and `key`. Does not subscribe. First read of a sourced Address binds.
    public func read<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) -> Value? {
        getValue(keyPath: keyPath, key: key)
    }

    /// Returns a value in a dictionary stored at the given key path.
    func getValue<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) -> Value? {
        let storage = getStorage(Storage.self)
        _ = accessSourced(storage, keyPath: keyPath, key: AnyHashable(key))
        return storage[keyPath: keyPath][key]
    }

    /// Sets a dictionary value for the given key and reports a change for observation.
    func setValue<Storage: StateContainer, Key: Hashable, Value>(
        _ newValue: Value,
        keyPath: WritableKeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        var storage = getStorage(Storage.self)
        storage[keyPath: keyPath][key] = newValue
        let valueID = ValueID(keyPath: keyPath, key: AnyHashable(key))
        #if STATE_MANAGEMENT_TELEMETRY_INTERNAL
        TraceContext.withSpan(
            "Set: \(valueID.debugDescription)",
            kind: .internal,
            valueDescription: String(describing: newValue)
        ) {
            observation.invalidateValue(at: valueID)
        }
        #else
        observation.invalidateValue(at: valueID)
        #endif
    }

    /// Removes a dictionary value for the given key and reports a change for observation.
    ///
    /// Unlike rewriting the whole dictionary at its base key path, this invalidates the *keyed*
    /// ``ValueID`` so receivers watching that specific key are notified (and flushed), and any
    /// computation depending on the key is re-evaluated.
    func removeValue<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: WritableKeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        var storage = getStorage(Storage.self)
        storage[keyPath: keyPath][key] = nil
        let valueID = ValueID(keyPath: keyPath, key: AnyHashable(key))
        #if STATE_MANAGEMENT_TELEMETRY_INTERNAL
        TraceContext.withSpan("Remove: \(valueID.debugDescription)", kind: .internal) {
            observation.invalidateValue(at: valueID)
        }
        #else
        observation.invalidateValue(at: valueID)
        #endif
    }

    // MARK: - Sync Operations

    public func perform<Op: ThrowingSyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) throws(Op.Failure) {
        try TraceContext.withSpan("Operation: \(String(describing: type(of: operation)))", kind: .user, file: file, line: Int(line)) { () throws(Op.Failure) in
            let environment = SyncOperationEnvironment(self)
            defer { observation.notifyAll() }
            do throws(Op.Failure) {
                try operation.perform(in: environment)
            } catch {
                TraceContext.log("failed")
                throw error
            }
        }
    }

    // MARK: - Async Operations

    public func perform<Op: ThrowingAsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) async throws(Op.Failure) {
        switch operation.reentrancy.kind {
        case .runAll:
            try await execute(operation, file: file, line: line)
        case .firstWins(let identity):
            try await joinIdentity(
                operation,
                identity: identity,
                replaces: false,
                file: file,
                line: line
            )
        case .newestWins(let identity):
            try await joinIdentity(
                operation,
                identity: identity,
                replaces: true,
                file: file,
                line: line
            )
        }
    }

    public func perform<Op: AsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) async {
        switch operation.reentrancy.kind {
        case .runAll:
            await execute(operation, file: file, line: line)
        case .firstWins(let identity):
            await joinIdentity(
                operation,
                identity: identity,
                replaces: false,
                file: file,
                line: line
            )
        case .newestWins(let identity):
            await joinIdentity(
                operation,
                identity: identity,
                replaces: true,
                file: file,
                line: line
            )
        }
    }

    public func perform<Op: AsyncOperation>(
        _ operation: Op,
        file: String = #fileID,
        line: UInt = #line
    ) {
        switch operation.reentrancy.kind {
        case .runAll:
            Task { @MainActor in
                await self.execute(operation, file: file, line: line)
            }
        case .firstWins(let identity):
            applyIdentity(
                operationType: ObjectIdentifier(type(of: operation)),
                identity: identity,
                replaces: false,
                waiter: nil
            ) { group in
                self.startIdentityExecution(operation, group: group, file: file, line: line)
            }
        case .newestWins(let identity):
            applyIdentity(
                operationType: ObjectIdentifier(type(of: operation)),
                identity: identity,
                replaces: true,
                waiter: nil
            ) { group in
                self.startIdentityExecution(operation, group: group, file: file, line: line)
            }
        }
    }

    private func joinIdentity<Op: ThrowingAsyncOperation>(
        _ operation: Op,
        identity: ReentrancyIdentity,
        replaces: Bool,
        file: String,
        line: UInt
    ) async throws(Op.Failure) {
        try await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Op.Failure>, Never>) in
            applyIdentity(
                operationType: ObjectIdentifier(type(of: operation)),
                identity: identity,
                replaces: replaces,
                waiter: typedWaiter(continuation)
            ) { group in
                self.startIdentityExecution(operation, group: group, file: file, line: line)
            }
        }.get()
    }

    private func joinIdentity<Op: AsyncOperation>(
        _ operation: Op,
        identity: ReentrancyIdentity,
        replaces: Bool,
        file: String,
        line: UInt
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            applyIdentity(
                operationType: ObjectIdentifier(type(of: operation)),
                identity: identity,
                replaces: replaces,
                waiter: { _ in continuation.resume() }
            ) { group in
                self.startIdentityExecution(operation, group: group, file: file, line: line)
            }
        }
    }

    /// IdentitySlot stores `any Error`. The live Execution only throws `Op.Failure`.
    private func typedWaiter<E: Error>(
        _ continuation: CheckedContinuation<Result<Void, E>, Never>
    ) -> (Result<Void, any Error>) -> Void {
        { erased in
            switch erased {
            case .success:
                continuation.resume(returning: .success(()))
            case .failure(let error):
                guard let typed = error as? E else {
                    preconditionFailure("Execution threw \(type(of: error)), expected \(E.self)")
                }
                continuation.resume(returning: .failure(typed))
            }
        }
    }

    private func applyIdentity(
        operationType: ObjectIdentifier,
        identity: ReentrancyIdentity,
        replaces: Bool,
        waiter: ((Result<Void, any Error>) -> Void)?,
        start: (ExecutionGroup) -> Execution
    ) {
        let group = ExecutionGroup(
            operationType: operationType,
            identity: identity
        )

        if let slot = identitySlots[group] {
            if replaces {
                slot.cancelLive()
                slot.live = start(group)
            }
            slot.addWaiter(waiter)
            return
        }

        let execution = start(group)
        let slot = IdentitySlot(live: execution)
        identitySlots[group] = slot
        slot.addWaiter(waiter)
    }

    private func startIdentityExecution<Op: ThrowingAsyncOperation>(
        _ operation: Op,
        group: ExecutionGroup,
        file: String,
        line: UInt
    ) -> Execution {
        let execution = Execution()
        liveExecutions[execution.id] = execution
        let task = Task { @MainActor in
            do throws(Op.Failure) {
                try await self.execute(operation, execution: execution, file: file, line: line)
                self.finishIdentity(execution, group: group, error: nil)
            } catch {
                self.finishIdentity(execution, group: group, error: error)
            }
        }
        execution.task = task
        return execution
    }

    private func startIdentityExecution<Op: AsyncOperation>(
        _ operation: Op,
        group: ExecutionGroup,
        file: String,
        line: UInt
    ) -> Execution {
        let execution = Execution()
        liveExecutions[execution.id] = execution
        let task = Task { @MainActor in
            await self.execute(operation, execution: execution, file: file, line: line)
            self.finishIdentity(execution, group: group, error: nil)
        }
        execution.task = task
        return execution
    }

    private func finishIdentity(_ execution: Execution, group: ExecutionGroup, error: (any Error)?) {
        liveExecutions[execution.id] = nil
        guard let slot = identitySlots[group], slot.live.id == execution.id else {
            return
        }
        slot.resumeWaiters(error: error)
        identitySlots[group] = nil
    }

    private func execute<Op: ThrowingAsyncOperation>(
        _ operation: Op,
        execution: Execution? = nil,
        file: String,
        line: UInt
    ) async throws(Op.Failure) {
        let live = execution ?? beginRunAllExecution()
        defer { if execution == nil { liveExecutions[live.id] = nil } }
        try await TraceContext.withSpan(
            "Operation: \(String(describing: type(of: operation)))",
            kind: .user,
            file: file,
            line: Int(line)
        ) { () async throws(Op.Failure) in
            do throws(Op.Failure) {
                let environment = AsyncOperationEnvironment(self, execution: live)
                try await operation.perform(in: environment)
            } catch {
                TraceContext.log("failed")
                throw error
            }
        }
    }

    private func execute<Op: AsyncOperation>(
        _ operation: Op,
        execution: Execution? = nil,
        file: String,
        line: UInt
    ) async {
        let live = execution ?? beginRunAllExecution()
        defer { if execution == nil { liveExecutions[live.id] = nil } }
        await TraceContext.withSpan(
            "Operation: \(String(describing: type(of: operation)))",
            kind: .user,
            file: file,
            line: Int(line)
        ) {
            let environment = AsyncOperationEnvironment(self, execution: live)
            await operation.perform(in: environment)
        }
    }

    private func beginRunAllExecution() -> Execution {
        let execution = Execution()
        liveExecutions[execution.id] = execution
        return execution
    }

    // MARK: - Service -
    public func getService<Service: EnvironmentService>(_ type: Service.Type) async -> Service {
        return await spawnService(type)
    }

    @discardableResult
    public func spawnService<Service: EnvironmentService>(_ type: Service.Type) async -> Service {
        let (service, created) = serviceInstance(type)
        if created {
            await service.serve()
        }
        return service
    }

    /// Shared with Source spawn so both paths own one instance per type.
    func spawnServiceAndKick<Service: EnvironmentService>(_ type: Service.Type) {
        let (service, created) = serviceInstance(type)
        if created {
            service.startServing()
        }
    }

    private func serviceInstance<Service: EnvironmentService>(_ type: Service.Type) -> (Service, created: Bool) {
        let id = Service.id()
        if let existing = serviceWarehouse[id] {
            return (unsafeDowncast(existing, to: Service.self), false)
        }
        let service = Service(env: self)
        serviceWarehouse[id] = service
        return (service, true)
    }

    // MARK: - Reset -

    func resetAll() {
        cancelAllExecutions()
        dropAllServices()
        dropAllBinds()
        sourceWarehouse.removeAll()
        observation.invalidateSubscribed()
        warehouse.removeAll()
    }

    func resetContainer<Storage: StateContainer>(_ type: Storage.Type) {
        cancelAllExecutions()
        dropBinds(in: type)
        observation.invalidateSubscribed(in: type)
        warehouse.removeValue(forKey: StorageID(type))
    }

    private func cancelAllExecutions() {
        for execution in liveExecutions.values {
            execution.isCancelled = true
            execution.task?.cancel()
        }
    }

    private func dropAllServices() {
        for service in serviceWarehouse.values {
            service.isDropped = true
        }
        serviceWarehouse.removeAll()
    }
}

/// One Environment-owned in-flight async Operation. The Environment Cancels it.
@MainActor
final class Execution {
    let id = UUID()
    var isCancelled = false
    var task: Task<Void, Never>?
}
