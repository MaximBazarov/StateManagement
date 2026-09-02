import Foundation
@testable import StateManagement
import Testing


final class OtherComputedState: StateContainer {
    var testKey: String = "0"
}

/// State under test.
final class ComputedState: StateContainer {

    // Triggering Updates
    var a: Int = 10
    var b: String = "B"
    var e: [String: String] = [
        "0": "E0",
        "1": "E1",
        "2": "E2",
    ]

    // Not triggering updates
    var c: [Int: String] = [0: "C0"]
    var d: Int = 0

    @Computed var computed_A_B_C0 = { env in
        let a = env.read(\ComputedState.a)
        let b = env.read(\ComputedState.b)
        let key = env.read(\OtherComputedState.testKey)
        let e0 = env.read(\ComputedState.e, key: key) ?? ""
        return "\(a)-\(b)-\(e0)"
    }

    @Computed<String, String> var keyedComputed = { env, key in
        let a = env.read(\ComputedState.a)
        let b = env.read(\ComputedState.b)
        let e0 = env.read(\ComputedState.e, key: "0") ?? ""
        return "\(a)-\(b)-\(e0)"
    }

    // A partial derivation: nothing in the Container decides readiness for an untracked id, so the
    // author declares `Output` Optional and answers `nil`. The framework never adds that Optional.
    var trackedIDs: Set<UUID> = []
    var readiness: [UUID: Bool] = [:]

    @Computed<UUID, Bool?> var isReady = { env, id in
        guard env.read(\ComputedState.trackedIDs).contains(id) else { return nil }
        return env.read(\ComputedState.readiness, key: id) ?? false
    }
}

/// Service that reads the computation value on `serve`
/// Also confirms the serve call and reports to the ``Waiter`` that serve has been called.
/// It's all needed due to asynchronous nature of the `serve` executions.
final class TracingService: EnvironmentService {
    var waiter: Waiter?
    var confirmation: Confirmation?
    var lastComputationValue: String = ""

    override func serve() async {
        if isSetup {

        }
        lastComputationValue = self.read(\ComputedState.$computed_A_B_C0)
        confirmation?.confirm()
        await waiter?.resume()
    }

    func awaitNextServe() async throws {
        try await waiter?.wait()
    }
}

/// Exactly the same as ``TracingService`` but needed for testing multiple state consumers and checking that both get the new value.
final class SecondTracingService: EnvironmentService {
    var waiter: Waiter?
    var confirmation: Confirmation?
    var lastComputationValue: String = ""

    override func serve() async {
        lastComputationValue = self.read(\ComputedState.$computed_A_B_C0)
        confirmation?.confirm()
        await waiter?.resume()
    }

    func awaitNextServe() async throws {
        try await waiter?.wait()
    }
}


/// Exactly the same as ``TracingService`` but needed for testing keyed computations
final class KeyedTracingService: EnvironmentService {
    var waiter: Waiter?
    var confirmation: Confirmation?
    var lastComputationValue: String = ""

    override func serve() async {
        lastComputationValue = self.read(\ComputedState.$keyedComputed, key: "myKey")
        confirmation?.confirm()
        await waiter?.resume()
    }

    func awaitNextServe() async throws {
        try await waiter?.wait()
    }
}

/// Exactly the same as ``KeyedTracingService`` but needed for testing multiple state consumers and checking that both get the new value.
final class SecondKeyedTracingService: EnvironmentService {
    var waiter: Waiter?
    var confirmation: Confirmation?
    var lastComputationValue: String = ""

    override func serve() async {
        lastComputationValue = self.read(\ComputedState.$keyedComputed, key: "myKey")
        confirmation?.confirm()
        await waiter?.resume()
    }

    func awaitNextServe() async throws {
        try await waiter?.wait()
    }
}


/// Mutates values that are used in the computation.
struct MutateValues: SyncOperation {
    let a: Int
    let b: String
    let e0: String

    func perform(in env: SyncOperationEnvironment) {
        env.write(\ComputedState.a, value: a)
        env.write(\ComputedState.b, value: b)
        env.write(\ComputedState.e, key: "0", value: e0)
    }
}


/// Mutates values that are not used in computations.
struct MutateUnrelated: SyncOperation {
    func perform(in env: StateManagement.SyncOperationEnvironment) {
        env.write(\ComputedState.c, key: 0, value: "AAA")
        /// Even tho E is read but the key that it reads is 0 not 1.
        /// So it should not trigger an update.
        env.write(\ComputedState.e, key: "1", value: "AAA")
        env.write(\ComputedState.d, value: 11)
    }
}

/// Brings an id under the derivation's rule, so `isReady` stops declining it.
struct TrackID: SyncOperation {
    let id: UUID

    func perform(in env: SyncOperationEnvironment) {
        var tracked = env.read(\ComputedState.trackedIDs)
        tracked.insert(id)
        env.write(\ComputedState.trackedIDs, value: tracked)
    }
}

struct SetReadiness: SyncOperation {
    let id: UUID
    let isReady: Bool

    func perform(in env: SyncOperationEnvironment) {
        env.write(\ComputedState.readiness, key: id, value: isReady)
    }
}

struct ComputedTests {

    /// 
    @Test @MainActor func computedRead() async throws {
        let env = SharedEnvironment()
        let waiter = Waiter(expectedCount: 2)
        let service = await env.spawnService(TracingService.self)
        let secondService = await env.spawnService(SecondTracingService.self)
        service.waiter = waiter
        secondService.waiter = waiter

        let originalValue = service.lastComputationValue
        let secondOriginalValue = secondService.lastComputationValue

        #expect(originalValue == "10-B-E0")
        #expect(secondOriginalValue == "10-B-E0")

        await confirmation("Both services served after update", expectedCount: 2) { confirmation in
            service.confirmation = confirmation
            secondService.confirmation = confirmation

            env.perform(MutateValues(a: 7, b: "seven", e0: "E-SEVEN"))

            do {
                try await service.awaitNextServe()
                try await secondService.awaitNextServe()
            }
            catch {
                Issue.record(error)
            }
        }

        let resultingValue = service.lastComputationValue
        let secondResultingValue = secondService.lastComputationValue

        #expect(resultingValue == "7-seven-E-SEVEN")
        #expect(secondResultingValue == "7-seven-E-SEVEN")
    }


    /// Testing that unrelated to computation changes do not trigger serve (re-compute).
    @Test @MainActor func computedUnrelatedMutations() async throws {
        let env = SharedEnvironment()
        let waiter = Waiter(expectedCount: 2)
        let service = await env.spawnService(TracingService.self)
        let secondService = await env.spawnService(SecondTracingService.self)
        service.waiter = waiter
        secondService.waiter = waiter

        let originalValue = service.lastComputationValue
        let secondOriginalValue = secondService.lastComputationValue

        #expect(originalValue == "10-B-E0")
        #expect(secondOriginalValue == "10-B-E0")

        await confirmation("Both services served after update", expectedCount: 0) { confirmation in
            service.confirmation = confirmation
            secondService.confirmation = confirmation

            env.perform(MutateUnrelated())

            do {
                try await service.awaitNextServe()
                try await secondService.awaitNextServe()
                Issue.record("Must never serve")
            }
            catch {
                _ = error
            }
        }

        let resultingValue = service.lastComputationValue
        let secondResultingValue = secondService.lastComputationValue

        #expect(resultingValue == originalValue)
        #expect(secondResultingValue == secondOriginalValue)
    }



    @Test @MainActor func keyedComputedRead() async throws {
        let env = SharedEnvironment()
        let waiter = Waiter(expectedCount: 1)
        let service = await env.spawnService(KeyedTracingService.self)
        service.waiter = waiter

        #expect(service.lastComputationValue == "10-B-E0")

        await confirmation("Keyed service served after update", expectedCount: 1) { confirmation in
            service.confirmation = confirmation
            env.perform(MutateValues(a: 7, b: "seven", e0: "E-SEVEN"))

            do {
                try await service.awaitNextServe()
            }
            catch {
                Issue.record(error)
            }
        }

        #expect(service.lastComputationValue == "7-seven-E-SEVEN")
    }

    @Test @MainActor func keyedComputedUnrelatedChanges() async throws {
        let env = SharedEnvironment()
        let waiter = Waiter(expectedCount: 1)
        let service = await env.spawnService(KeyedTracingService.self)
        service.waiter = waiter

        let initial = service.lastComputationValue
        #expect(initial == "10-B-E0")

        await confirmation("Keyed service should NOT serve for unrelated changes", expectedCount: 0) { confirmation in
            service.confirmation = confirmation
            env.perform(MutateUnrelated())

            do {
                try await service.awaitNextServe()
                Issue.record("Must never serve")
            }
            catch {
                _ = error
            }
        }

        #expect(service.lastComputationValue == initial)
    }

    // MARK: - Optional Output

    /// A keyed Computed read is never Optional, because a Computed always runs. Partiality is the
    /// author's to declare, so `nil` here is the closure's own answer and behaves like any other
    /// output: cached per key, invalidated by the input that decided it.
    @Test("A keyed Computed with Optional Output answers nil for a key it declines")
    @MainActor func optionalOutputKeyedComputedDeclinesAKey() {
        let env = SharedEnvironment()
        let tracked = UUID()
        let untracked = UUID()
        env.perform(TrackID(id: tracked))
        env.perform(SetReadiness(id: tracked, isReady: true))

        let declined = ValueObserverProbe<ComputedState, Bool?>
            .watch(computedKeyed: \.$isReady, key: untracked, in: env)
        let answered = ValueObserverProbe<ComputedState, Bool?>
            .watch(computedKeyed: \.$isReady, key: tracked, in: env)

        declined.expect(value: nil)
        answered.expect(value: true)

        // Tracking the declined id invalidates only its entry: the derivation reruns and now
        // answers, which is what proves the earlier `nil` was a real output rather than a miss.
        declined.perform(TrackID(id: untracked))
        declined.expect(updates: 1)
        declined.expect(value: false)
        answered.expect(value: true)
    }
}
