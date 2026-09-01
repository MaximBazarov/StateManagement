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

#if DEBUG
import Foundation
import Testing

@testable import StateManagement

final class SeedTestState: StateContainer {
    var counter: Int = 0
    var label: String = ""
    var items: [String: Int] = [:]
}

struct SeedBumpCounter: SyncOperation {
    let by: Int
    func perform(in env: SyncOperationEnvironment) {
        let current = env.read(\SeedTestState.counter)
        env.write(\SeedTestState.counter, value: current + by)
    }
}

@Suite
@MainActor
struct SeedEnvironmentTests {

    @Test("seeded applies multiple whole-value Writes")
    func seededAppliesMultipleWrites() {
        let env = SharedEnvironment.seeded {
            Write(\SeedTestState.counter, 3)
            Write(\SeedTestState.label, "hi")
        }

        #expect(env.read(\SeedTestState.counter) == 3)
        #expect(env.read(\SeedTestState.label) == "hi")
    }

    @Test("seeded keyed Write updates one dictionary entry")
    func seededKeyedWrite() {
        let env = SharedEnvironment.seeded {
            Write(\SeedTestState.items, key: "a", 2)
            Write(\SeedTestState.items, key: "b", 5)
        }

        #expect(env.read(\SeedTestState.items, key: "a") == 2)
        #expect(env.read(\SeedTestState.items, key: "b") == 5)
        #expect(env.read(\SeedTestState.items, key: "c") == nil)
    }

    @Test("seeded mixes Write with a named SyncOperation")
    func seededMixesNamedOperation() {
        let env = SharedEnvironment.seeded {
            Write(\SeedTestState.counter, 10)
            SeedBumpCounter(by: 2)
        }

        #expect(env.read(\SeedTestState.counter) == 12)
    }

    @Test("seed batch notifies once for multiple Writes")
    func seedBatchNotifiesOnce() {
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(\SeedTestState.counter, in: env)

        env.perform(
            SeedBatch(operations: [
                Write(\SeedTestState.counter, 1),
                Write(\SeedTestState.label, "x"),
            ])
        )

        #expect(probe.updates == 1)
        #expect(probe.lastValue == 1)
    }

    @Test("empty seeded builder returns a usable fresh environment")
    func emptySeededBuilder() {
        let env = SharedEnvironment.seeded {}
        #expect(env.read(\SeedTestState.counter) == 0)
        #expect(env !== SharedEnvironment.shared)
    }

    @Test("Write works via env.perform alone")
    func writeViaPerform() {
        let env = SharedEnvironment()
        env.perform(Write(\SeedTestState.counter, 7))
        env.perform(Write(\SeedTestState.items, key: "z", 9))

        #expect(env.read(\SeedTestState.counter) == 7)
        #expect(env.read(\SeedTestState.items, key: "z") == 9)
    }

    @Test("seed applies the batch to an existing Environment")
    func seedAppliesToExisting() {
        let env = SharedEnvironment()
        env.seed {
            Write(\SeedTestState.counter, 3)
            Write(\SeedTestState.label, "hi")
        }

        #expect(env.read(\SeedTestState.counter) == 3)
        #expect(env.read(\SeedTestState.label) == "hi")
    }

    @Test("seed notifies once for multiple Writes")
    func seedNotifiesOnce() {
        let env = SharedEnvironment()
        let probe = ValueObserverProbe.watch(\SeedTestState.counter, in: env)

        env.seed {
            Write(\SeedTestState.counter, 1)
            Write(\SeedTestState.label, "x")
        }

        #expect(probe.updates == 1)
        #expect(probe.lastValue == 1)
    }

    @Test("empty seed leaves the Environment unchanged")
    func emptySeedIsNoop() {
        let env = SharedEnvironment()
        env.seed {}
        #expect(env.read(\SeedTestState.counter) == 0)
    }
}
#endif
