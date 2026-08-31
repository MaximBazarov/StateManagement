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
@testable import StateManagement

final class ServicePerformBox: StateContainer {
    var count = 0
}

struct ServiceIncrement: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        let current = env.read(\ServicePerformBox.count)
        env.write(\ServicePerformBox.count, value: current + 1)
    }
}

enum ServicePerformFailure: Error, Equatable {
    case boom
}

struct ServiceThrowingSync: ThrowingSyncOperation {
    func perform(in env: SyncOperationEnvironment) throws(ServicePerformFailure) {
        throw .boom
    }
}

@MainActor
final class PerformingService: EnvironmentService {}

@MainActor
final class SpawnProbeService: EnvironmentService {
    static var last: SpawnProbeService?

    private(set) var serveCount = 0
    let served = Waiter(expectedCount: 1)

    required init(env: SharedEnvironment) {
        super.init(env: env)
        Self.last = self
    }

    override func serve() async {
        serveCount += 1
        await served.resume()
    }
}

@Suite("Service perform and spawn", .serialized)
@MainActor
struct ServicePerformAndSpawnTests {

    @Test("A Service perform(SyncOperation) writes through that Operation")
    func servicePerformWritesThroughOperation() async {
        let env = SharedEnvironment()
        let service = await env.spawnService(PerformingService.self)

        service.perform(ServiceIncrement())

        #expect(env.read(\ServicePerformBox.count) == 1)
    }

    @Test("A Service try perform(ThrowingSyncOperation) surfaces the error")
    func servicePerformSurfacesThrow() async {
        let env = SharedEnvironment()
        let service = await env.spawnService(PerformingService.self)

        #expect(throws: ServicePerformFailure.boom) {
            try service.perform(ServiceThrowingSync())
        }
    }

    @Test("SharedEnvironment.spawnService still awaits first serve()")
    func sharedSpawnAwaitsFirstServe() async {
        SpawnProbeService.last = nil
        let env = SharedEnvironment()
        let service = await env.spawnService(SpawnProbeService.self)

        #expect(service.serveCount == 1)
    }
}
