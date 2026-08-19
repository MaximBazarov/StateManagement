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
        let current = env.read(keyPath: \ServicePerformBox.count)
        env.write(current + 1, keyPath: \ServicePerformBox.count)
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

@MainActor
final class SpawningSource: Source {
    typealias Failure = Never
    let sourceUpdate = SourceUpdate.write
    private(set) var lastEnvironment: SourceEnvironment?

    init() {}

    func provide<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        in env: SourceEnvironment
    ) {
        lastEnvironment = env
        env.spawnService(SpawnProbeService.self)
    }
}

final class SpawnFromProvideBox: StateContainer {
    @AsyncState(SpawningSource.self) var theme: String = "system"
}

@Suite("Service perform and Source spawn", .serialized)
@MainActor
struct ServicePerformAndSourceSpawnTests {

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

    @Test("SourceEnvironment.spawnService creates if missing and does not await serve()")
    func sourceSpawnCreatesWithoutAwaitingServe() async throws {
        SpawnProbeService.last = nil
        let env = SharedEnvironment()
        let source = SpawningSource()
        env.install(source)
        env.preheat(\SpawnFromProvideBox.theme)

        let created = SpawnProbeService.last
        #expect(created != nil)
        #expect(created?.serveCount == 0)

        source.lastEnvironment?.spawnService(SpawnProbeService.self)
        #expect(SpawnProbeService.last === created)

        try await created?.served.wait()
        #expect(created?.serveCount == 1)
    }

    @Test("SourceEnvironment still cannot perform an arbitrary Operation")
    func sourceCannotPerformArbitraryOperation() async throws {
        SpawnProbeService.last = nil
        let env = SharedEnvironment()
        let source = SpawningSource()
        env.install(source)
        env.preheat(\SpawnFromProvideBox.theme)
        try await SpawnProbeService.last?.served.wait()

        #expect(env.read(\ServicePerformBox.count) == 0)
        source.lastEnvironment?.spawnService(PerformingService.self)
        #expect(env.read(\ServicePerformBox.count) == 0)
    }

    @Test("SharedEnvironment.spawnService still awaits first serve()")
    func sharedSpawnAwaitsFirstServe() async {
        SpawnProbeService.last = nil
        let env = SharedEnvironment()
        let service = await env.spawnService(SpawnProbeService.self)

        #expect(service.serveCount == 1)
    }
}
