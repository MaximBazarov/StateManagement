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
@testable import StateManagement
import StateManagementTestingSupport
import Testing

// MARK: - State

final class SvcTestState: StateContainer {
    var count: Int = 0
    var dict: [String: String] = [:]

    @Computed var scaled = { (env: ComputationEnvironment) -> Int in
        env.read(\SvcTestState.count) * 10
    }

    @Computed var keyed = { (env: ComputationEnvironment, key: String) -> Int in
        env.read(\SvcTestState.count) + key.count
    }
}

// MARK: - Operations

struct SetCount: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(\SvcTestState.count, value: value)
    }
}

struct SetDictEntry: SyncOperation {
    let key: String
    let value: String
    func perform(in env: SyncOperationEnvironment) {
        env.write(\SvcTestState.dict, key: key, value: value)
    }
}

// MARK: - Service

/// Records everything inside serve() so assertions can run after the waiter resumes.
@MainActor
final class TrackingService: EnvironmentService {
    var serveCount = 0
    var waiter = Waiter(expectedCount: 1)

    // Latest reads
    var lastCount: Int = -1
    var lastDictValue: String?
    var lastComputed: Int = -1
    var lastKeyedComputed: Int = -1

    // wasUpdated snapshots captured inside serve()
    var countUpdated = false
    var countArrayUpdated = false
    var computedUpdated = false
    var computedArrayUpdated = false
    var keyedComputedUpdated = false

    override func serve() async {
        // Read values (subscribes the service to changes)
        lastCount = read(\SvcTestState.count)
        lastDictValue = read(\SvcTestState.dict, key: "a")
        lastComputed = read(\SvcTestState.$scaled)
        lastKeyedComputed = read(\SvcTestState.$keyed, key: "myKey")

        // Capture wasUpdated results before they are cleared
        countUpdated = wasUpdated(\SvcTestState.count)
        countArrayUpdated = wasUpdated([\SvcTestState.count])
        computedUpdated = wasUpdated(\SvcTestState.$scaled)
        computedArrayUpdated = wasUpdated([\SvcTestState.$scaled])
        keyedComputedUpdated = wasUpdated(\SvcTestState.$keyed, key: "myKey")

        serveCount += 1
        await waiter.resume()
    }
}

// MARK: - Tests

/// Subscriptions are one-shot, but a service re-subscribes itself after every
/// run, so it keeps serving across external mutations without re-reading. These
/// tests drive that path plus the read, write, and computed surface a service
/// touches inside serve().
@Suite("EnvironmentService auto-subscribe") @MainActor
struct ServiceAutoSubscribeTests {

    @Test("Auto-subscribe keeps the service subscribed across repeated mutations")
    func autoSubscribeKeepsReceivingUpdates() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(TrackingService.self)
        #expect(service.serveCount == 1) // initial serve

        // First mutation
        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetCount(value: 1))
        try await service.waiter.wait()
        #expect(service.serveCount == 2)

        // Second mutation — still subscribed because of auto-resubscribe
        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetCount(value: 2))
        try await service.waiter.wait()
        #expect(service.serveCount == 3)
        #expect(service.lastCount == 2)
    }

    @Test("wasUpdated reports the changed value inside serve()")
    func serviceSeesWhichValuesChanged() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(TrackingService.self)

        // On initial serve, updatedValues is empty so nothing is marked updated.
        #expect(service.countUpdated == false)
        #expect(service.countArrayUpdated == false)

        // Mutate count
        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetCount(value: 42))
        try await service.waiter.wait()

        #expect(service.countUpdated == true)
        #expect(service.countArrayUpdated == true)
        #expect(service.lastCount == 42)
    }

    @Test("Service reads and writes keyed dictionary state")
    func serviceReadsWritesKeyedState() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(TrackingService.self)

        // Initial dict is empty, so the read returns nil.
        #expect(service.lastDictValue == nil)

        // Write via SyncOperation
        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetDictEntry(key: "a", value: "hello"))
        try await service.waiter.wait()
        #expect(service.lastDictValue == "hello")

        // Write from the service itself, which it can only do by performing an Operation.
        service.waiter = Waiter(expectedCount: 1)
        service.perform(SetDictEntry(key: "a", value: "world"))
        try await service.waiter.wait()

        // The Service hears the change it caused, like any other reader, and the value landed.
        let reader = await env.spawnService(StateReader.self)
        let stored = reader.read(\SvcTestState.dict, key: "a")
        #expect(stored == "world")
    }

    @Test("Service observes atomic and keyed computed values")
    func serviceObservesComputedValues() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(TrackingService.self)

        // Initial: count=0, scaled = 0*10 = 0, keyed("myKey") = 0 + 5 = 5
        #expect(service.lastComputed == 0)
        #expect(service.lastKeyedComputed == 5)

        // Mutate count to trigger recomputation
        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetCount(value: 3))
        try await service.waiter.wait()

        #expect(service.lastComputed == 30)           // 3 * 10
        #expect(service.lastKeyedComputed == 8)        // 3 + 5

        // wasUpdated for count (the dependency of both computeds) fires
        #expect(service.countUpdated == true)
    }

    @Test("getService returns the cached instance, not a new one")
    func getServiceReturnsSameInstance() async throws {
        let env = SharedEnvironment()
        let a = await env.spawnService(TrackingService.self)
        let b = await env.getService(TrackingService.self)
        #expect(a === b)
    }

    @Test("StateReader reads atomic and keyed computed values")
    func stateReaderComputedReads() async throws {
        let env = SharedEnvironment()

        // Seed count so computed produces a visible value
        env.perform(SetCount(value: 5))

        let reader = await env.spawnService(StateReader.self)

        let atomicComputed: Int = reader.read(\SvcTestState.$scaled)
        #expect(atomicComputed == 50) // 5 * 10

        let keyedComputed: Int = reader.read(\SvcTestState.$keyed, key: "hi")
        #expect(keyedComputed == 7) // 5 + len("hi") = 5 + 2
    }
}
