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
import StateManagement
import StateManagementTestingSupport
import Testing

final class Counter: StateContainer {
    var x: Int = 7
}

/// Increments value of `\Counter.x` by 1 every time `\Counter.x` changes.
/// IMPORTANT: this usually would cause an endless loop, but the way `.serve()` works,
/// ignoring updates caused by itself, automatically prevents this.
final class UpdatesCounterService: EnvironmentService {
    var waiter: Waiter?
    var confirmation: Confirmation?
    var latestXValue: Int = -1

    override func serve() async {
        latestXValue = getValue(\Counter.x)
        confirmation?.confirm()
        await waiter?.resume()
        
        if !isSetup {
            setValue(latestXValue + 1, keyPath: \Counter.x)
        }
    }

    func awaitNextServe() async throws {
        try await waiter?.wait()
    }
}

struct UpdateCounterX: SyncOperation {
    let newValue: Int

    func perform(in env: SyncOperationEnvironment) {
        env.write(newValue, keyPath: \Counter.x)
    }
}

@Suite("EnvironmentService")
struct ServiceTests {

    @Test("Same service type resolves to one instance and serves after a state change")
    @MainActor func test_SameServiceSameID() async throws {
        let environment = SharedEnvironment()
        let waiter = Waiter(expectedCount: 1)
        
        let service = await environment.spawnService(UpdatesCounterService.self)
        service.waiter = waiter
        
        // Use our custom StateReader from StateManagementTestingSupport to read state
        let reader = await environment.spawnService(StateReader.self)
        
        let initialValue = reader.read(\Counter.x)
        #expect(initialValue == 7)

        await confirmation("Service served after state change", expectedCount: 1) { confirmation in
            service.confirmation = confirmation
            environment.perform(UpdateCounterX(newValue: initialValue))
            
            do {
                try await service.awaitNextServe()
            } catch {
                Issue.record(error)
            }
        }

        let finalValue = reader.read(\Counter.x)
        #expect(finalValue == 8)
    }
}
