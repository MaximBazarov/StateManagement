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
import Testing
import StateManagementTestingSupport

@testable import StateManagement

// MARK: - State

final class LifecycleCounter: StateContainer {
    var x = 0
}

struct SetLifecycleX: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: \LifecycleCounter.x)
    }
}

// MARK: - Services

/// Records `isSetup` on every serve and re-reads `x` each time to stay subscribed.
@MainActor
final class SetupProbeService: EnvironmentService {
    var isSetupLog: [Bool] = []
    var waiter = Waiter(expectedCount: 1)

    override func serve() async {
        isSetupLog.append(isSetup)
        _ = getValue(\LifecycleCounter.x)
        await waiter.resume()
    }
}

/// Reads `x` only during setup. After that it stops re-reading. The service
/// re-subscribes itself each run, so it keeps serving anyway.
@MainActor
final class ReadOnceService: EnvironmentService {
    var serveCount = 0
    var waiter = Waiter(expectedCount: 1)

    override func serve() async {
        if isSetup {
            _ = getValue(\LifecycleCounter.x)
        }
        serveCount += 1
        await waiter.resume()
    }
}

/// Reads `x`, then on any non-setup serve writes `x + 1` once. The write is the
/// service's own, so it must not trigger another serve.
@MainActor
final class SelfWriteService: EnvironmentService {
    var serveCount = 0
    var waiter = Waiter(expectedCount: 1)

    override func serve() async {
        let current = getValue(\LifecycleCounter.x)
        serveCount += 1
        await waiter.resume()
        if !isSetup {
            setValue(current + 1, keyPath: \LifecycleCounter.x)
        }
    }
}

// MARK: - Tests

@Suite("EnvironmentService lifecycle", .serialized) @MainActor
struct EnvironmentServiceLifecycleTests {

    @Test("isSetup is true on the first serve, false when a later serve is driven by an update")
    func isSetupTrueOnFirstServeFalseAfterUpdate() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(SetupProbeService.self)

        #expect(service.isSetupLog == [true])

        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetLifecycleX(value: 1))
        try await service.waiter.wait()

        #expect(service.isSetupLog == [true, false])
    }

    @Test("A service that stops re-reading still keeps serving, it re-subscribes itself each run")
    func keepsServingWithoutReReading() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(ReadOnceService.self)
        #expect(service.serveCount == 1) // initial serve subscribed once

        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetLifecycleX(value: 1))
        try await service.waiter.wait()
        #expect(service.serveCount == 2)

        // No re-read on the update serve, but the service re-subscribed itself,
        // so this mutation still drives a run.
        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetLifecycleX(value: 2))
        try await service.waiter.wait()
        #expect(service.serveCount == 3)
    }

    /// The self-write may drive one benign reentrant serve, but that serve sees
    /// no pending updates (`isSetup` is true again) and writes nothing, so the
    /// counter converges to a single increment. This is the "prevents infinite
    /// recursion" guarantee.
    @Test("A service writing a value it observes settles instead of looping forever")
    func selfWriteSettlesWithoutLooping() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(SelfWriteService.self)
        #expect(service.serveCount == 1) // setup, no write

        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetLifecycleX(value: 10))
        try await service.waiter.wait()

        // Let any reentrant serving drain, then confirm it has stopped growing.
        try await Task.sleep(for: .milliseconds(100))
        let settledCount = service.serveCount
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.serveCount == settledCount, "serve() is still looping")

        // Exactly one increment landed: 10 -> 11, no runaway.
        let reader = await env.spawnService(StateReader.self)
        #expect(reader.read(\LifecycleCounter.x) == 11)
    }
}
