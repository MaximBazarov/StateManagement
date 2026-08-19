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

final class SingleFlightState: StateContainer {
    var value = 0
}

struct SetSingleFlightValue: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: \SingleFlightState.value)
    }
}

// MARK: - Services

/// A test service that models a real service doing slow async work inside `serve()`.
///
/// A real reactive service does something slow when it serves: a network call, a disk write. More
/// changes can land while that work is still in flight. What the reactor does then depends on timing,
/// what overlaps, what coalesces, what a follow-up run reads. This service makes the slow work take a
/// controllable amount of time, so a test can land changes mid-work and check what the reactor did.
///
/// How a test drives it:
/// 1. Set ``workBlocksUntilFinished`` to true, then fire a change. That change starts a run, which begins working.
/// 2. `await` ``waitUntilWorking()``. The test resumes once a run is mid-work.
/// 3. Fire more changes. The reactor coalesces them, because the one run is still in flight.
/// 4. Call ``finishWork()`` to let the working run complete. Set ``workBlocksUntilFinished`` to false first if
///    the follow-up run should complete on its own.
/// 5. `await` ``completed`` for the runs to finish, then read ``runCount``, ``startedValues``,
///    ``finishedValues``, and ``maxConcurrent``.
///
/// The work is a continuation the test resumes, not a real sleep, so timing is exact and the test
/// never waits longer than it must. A second continuation, ``workStartedSignal``, tells the test the
/// work is in flight. It fires only after the work continuation is in place, in the same synchronous
/// step, so a test can never finish work that has not started yet.
@MainActor
final class SlowWorkService: EnvironmentService {

    /// Runs of `serve()` started, including the initial setup run.
    private(set) var runCount = 0
    /// Highest number of runs in flight at the same time. Single-flight keeps this at 1.
    private(set) var maxConcurrent = 0
    private var concurrent = 0

    /// The value each run read when it began working, in run order. Shows what the reactor served.
    private(set) var startedValues: [Int] = []
    /// The value of each run that finished its work. A cancelled or torn run is absent, so this proves
    /// finish-then-follow: the working run's value is here even when a newer run also ran.
    private(set) var finishedValues: [Int] = []

    /// When true, the work in `serve()` blocks until a test calls ``finishWork()``. When false,
    /// `serve()` does no blocking work and completes on its own.
    var workBlocksUntilFinished = false
    /// Set while a run is mid-work. Resuming it completes that run's work.
    private var workInProgress: CheckedContinuation<Void, Never>?
    /// A test parks here in ``waitUntilWorking()`` until a run is mid-work.
    private var workStartedSignal: CheckedContinuation<Void, Never>?

    /// Counts down as runs finish. A test sets its expected count, then waits for the runs it expects.
    var completed = Waiter(expectedCount: 1)

    override func serve() async {
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        runCount += 1

        let value = getValue(\SingleFlightState.value)
        startedValues.append(value)

        if workBlocksUntilFinished {
            // Stand in for slow async work, a network call or a disk write. The test ends it.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.workInProgress = continuation
                // The work is in place now, so signalling here cannot race a finish.
                if let workStartedSignal = self.workStartedSignal {
                    self.workStartedSignal = nil
                    workStartedSignal.resume()
                }
            }
        }

        // Work done. A cancelled or torn run would never reach this.
        finishedValues.append(value)
        concurrent -= 1
        await completed.resume()
    }

    /// Suspends the caller until a run is mid-work.
    func waitUntilWorking() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if workInProgress != nil {
                continuation.resume()
            } else {
                workStartedSignal = continuation
            }
        }
    }

    /// Completes the in-flight run's work, letting it finish.
    func finishWork() {
        let workInProgress = self.workInProgress
        self.workInProgress = nil
        workInProgress?.resume()
    }
}

/// Writes `value + 1` on any non-setup run. The write is its own, so it must not
/// drive another run.
@MainActor
final class SingleFlightSelfWriteService: EnvironmentService {
    private(set) var runCount = 0
    var waiter = Waiter(expectedCount: 1)

    override func serve() async {
        let current = getValue(\SingleFlightState.value)
        runCount += 1
        await waiter.resume()
        if !isSetup {
            setValue(current + 1, keyPath: \SingleFlightState.value)
        }
    }
}

// MARK: - Tests

/// The reactor is single-flight, latest-wins, finish-then-follow. These tests
/// drive the production path with a service that does slow work inside `serve()`.
@Suite("EnvironmentService single-flight reactor", .serialized) @MainActor
struct ServiceSingleFlightTests {

    @Test("A burst during one in-flight run coalesces into one follow-up that reads the last value")
    func coalescesToLatest() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(SlowWorkService.self)
        #expect(service.startedValues == [0]) // initial run read 0

        service.workBlocksUntilFinished = true
        env.perform(SetSingleFlightValue(value: 1))
        await service.waitUntilWorking() // a run is now mid-work, having read 1

        // Fire a burst while the run works. Each coalesces, none starts a run.
        env.perform(SetSingleFlightValue(value: 2))
        env.perform(SetSingleFlightValue(value: 3))
        env.perform(SetSingleFlightValue(value: 4))

        // Let the follow-up run complete on its own: the working run finishes, then one follow-up.
        service.workBlocksUntilFinished = false
        service.completed = Waiter(expectedCount: 2)
        service.finishWork()
        try await service.completed.wait()

        #expect(service.runCount == 3)                 // setup, working run, one follow-up
        #expect(service.startedValues == [0, 1, 4])    // follow-up read the last value
        #expect(service.maxConcurrent == 1)
    }

    @Test("Changes during an in-flight run never start a second concurrent run")
    func noOverlappingRuns() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(SlowWorkService.self)

        service.workBlocksUntilFinished = true
        env.perform(SetSingleFlightValue(value: 1))
        await service.waitUntilWorking()

        env.perform(SetSingleFlightValue(value: 2))
        env.perform(SetSingleFlightValue(value: 3))

        // Still working. The burst coalesced, so only setup and the working run started.
        #expect(service.runCount == 2)
        #expect(service.maxConcurrent == 1)

        service.workBlocksUntilFinished = false
        service.completed = Waiter(expectedCount: 2)
        service.finishWork()
        try await service.completed.wait()
        #expect(service.maxConcurrent == 1)
    }

    /// This is the lost-change bug, now fixed.
    @Test("A change arriving while a run is in flight still drives a follow-up that reads it")
    func finalChangeIsNeverLost() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(SlowWorkService.self)

        service.workBlocksUntilFinished = true
        env.perform(SetSingleFlightValue(value: 1))
        await service.waitUntilWorking()

        // The change lands while the run is in flight.
        env.perform(SetSingleFlightValue(value: 99))

        service.workBlocksUntilFinished = false
        service.completed = Waiter(expectedCount: 2)
        service.finishWork()
        try await service.completed.wait()

        #expect(service.startedValues == [0, 1, 99]) // follow-up read the change
    }

    @Test("A run completes its work even when a newer change arrives mid-run, never cancelled")
    func finishesThenFollowsNeverCancels() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(SlowWorkService.self)

        service.workBlocksUntilFinished = true
        env.perform(SetSingleFlightValue(value: 1))
        await service.waitUntilWorking() // the working run started at value 1

        // A newer change arrives mid-run.
        env.perform(SetSingleFlightValue(value: 2))

        service.workBlocksUntilFinished = false
        service.completed = Waiter(expectedCount: 2)
        service.finishWork()
        try await service.completed.wait()

        // The working run finished its work, it was not torn.
        #expect(service.finishedValues.contains(1))
        // Then it followed the latest.
        #expect(service.startedValues.last == 2)
    }

    @Test("A service writing a value it reads settles under single-flight, no loop")
    func selfWriteSettlesUnderSingleFlight() async throws {
        let env = SharedEnvironment()
        let service = await env.spawnService(SingleFlightSelfWriteService.self)
        #expect(service.runCount == 1) // setup, no write

        service.waiter = Waiter(expectedCount: 1)
        env.perform(SetSingleFlightValue(value: 10))
        try await service.waiter.wait()

        try await Task.sleep(for: .milliseconds(100))
        let settled = service.runCount
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.runCount == settled, "serve() is still looping")

        let reader = await env.spawnService(StateReader.self)
        #expect(reader.read(\SingleFlightState.value) == 11)
    }
}
