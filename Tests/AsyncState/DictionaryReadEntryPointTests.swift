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

#if canImport(AppKit) || canImport(UIKit)
import SwiftUI
#endif

// MARK: - Containers

/// A sourced dictionary reached from every read entry point. The dictionary Address names a whole
/// fact, so no entry point may kick `onRead` through it; one entry of the same declaration does.
final class EntryPointBox: StateContainer {
    @AsyncState(MockStrategy.self) var flags: [String: Bool] = ["a": true]

    /// Entries that are not `Equatable`, so the always-notify overload is the one that resolves.
    var tallies: [String: FlagTally] = [:]

    @Computed var flagCount = { (env: ComputationEnvironment) -> Int in
        env.read(\EntryPointBox.flags).count
    }
}

/// Holds what an Operation saw, so the assertion does not have to go through more State.
@MainActor
final class DictionaryReadRecorder {
    var seen: [String: Bool]?
}

struct ReadFlagsSync: SyncOperation {
    let recorder: DictionaryReadRecorder

    func perform(in env: SyncOperationEnvironment) {
        recorder.seen = env.read(\EntryPointBox.flags)
    }
}

struct ReadFlagsAsync: AsyncOperation {
    let recorder: DictionaryReadRecorder
    var reentrancy: ReentrancyDecision { .runAll }

    func perform(in env: AsyncOperationEnvironment) async {
        recorder.seen = env.read(\EntryPointBox.flags)
    }
}

struct WriteFlag: SyncOperation {
    let key: String
    let value: Bool

    func perform(in env: SyncOperationEnvironment) {
        env.write(\EntryPointBox.flags, key: key, value: value)
    }
}

struct WriteTally: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write(\EntryPointBox.tallies, key: "a", value: FlagTally(count: 1))
    }
}

/// Reads the whole dictionary and subscribes to it, so a later entry write serves it again.
final class FlagsDictionaryService: EnvironmentService {
    var waiter: Waiter?
    var latest: [String: Bool] = [:]

    override func serve() async {
        latest = read(\EntryPointBox.flags)
        await waiter?.resume()
    }
}

// MARK: - Tests

/// ADR 0026 R38 splits the read path on a dictionary Value, and the split repeats at every read
/// entry point. Each of these pins one entry point: it returns the whole dictionary, and it
/// reaches the seam without kicking.
@Suite @MainActor
struct DictionaryReadEntryPointTests {

    @Test("A Sync operation reads the whole dictionary and does not kick")
    func syncOperationReadsTheDictionary() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let recorder = DictionaryReadRecorder()

        env.perform(ReadFlagsSync(recorder: recorder))

        #expect(recorder.seen == ["a": true])
        #expect(strategy.keyedOnReadCount == 0)
    }

    @Test("An Async operation reads the whole dictionary and does not kick")
    func asyncOperationReadsTheDictionary() async {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let recorder = DictionaryReadRecorder()

        await env.perform(ReadFlagsAsync(recorder: recorder))

        #expect(recorder.seen == ["a": true])
        #expect(strategy.keyedOnReadCount == 0)
    }

    @Test("A Computed reads the whole dictionary, does not kick, and recomputes on an entry write")
    func computedReadsTheDictionary() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let probe = ValueObserverProbe<EntryPointBox, Int>
            .watch(computed: \EntryPointBox.$flagCount, in: env)

        probe.expect(value: 1)
        #expect(strategy.keyedOnReadCount == 0)

        env.perform(WriteFlag(key: "b", value: false))

        probe.expect(updates: 1)
        probe.expect(value: 2)
    }

    @Test("A Service reads the whole dictionary, does not kick, and serves again on an entry write")
    func serviceReadsTheDictionary() async throws {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let service = await env.spawnService(FlagsDictionaryService.self)
        let waiter = Waiter(expectedCount: 1)
        service.waiter = waiter

        #expect(service.latest == ["a": true])
        #expect(strategy.keyedOnReadCount == 0)

        env.perform(WriteFlag(key: "b", value: false))
        try await waiter.wait()

        #expect(service.latest == ["a": true, "b": false])
    }

    @Test("A dictionary reader diffs Equatable entries and does not kick")
    func dictionaryReaderDiffs() {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        let probe = ValueObserverProbe<EntryPointBox, [String: Bool]>
            .watchDictionary(\EntryPointBox.flags, in: env)

        probe.expect(value: ["a": true])
        #expect(strategy.keyedOnReadCount == 0)

        env.perform(WriteFlag(key: "a", value: true))
        probe.expect(suppressed: true)

        env.perform(WriteFlag(key: "a", value: false))
        probe.expect(updates: 1)
    }

    /// The non-Equatable twin has nothing to compare, so the same rewrite that the Equatable
    /// reader suppresses re-renders here.
    @Test("A dictionary reader of non-Equatable entries always notifies")
    func dictionaryReaderWithoutDiffingAlwaysNotifies() {
        let env = SharedEnvironment()
        let probe = ValueObserverProbe<EntryPointBox, [String: FlagTally]>
            .watchDictionaryRaw(\EntryPointBox.tallies, in: env)

        env.perform(WriteTally())
        env.perform(WriteTally())

        probe.expect(updates: 2)
    }
}

#if canImport(AppKit) || canImport(UIKit)

private struct DictionaryWatchView: View {
    @Watch(\EntryPointBox.flags) var flags: [String: Bool]

    let onBody: (([String: Bool]) -> Void)?

    var body: some View {
        onBody?(flags)
        return Text("\(flags.count)")
    }
}

@Suite @MainActor
struct DictionaryWatchTests {

    @Test("A whole-dictionary Watch renders the dictionary and re-renders on an entry write")
    func watchOfAWholeDictionary() async {
        let env = SharedEnvironment()
        let strategy = env.strategyUnderTest(MockStrategy.self)
        var rendered: [[String: Bool]] = []

        let host = HostedView.mount(
            DictionaryWatchView(onBody: { rendered.append($0) })
                .sharedEnvironment(env)
        )
        defer { host.teardown() }

        #expect(await waitUntil { rendered.last == ["a": true] })
        #expect(strategy.keyedOnReadCount == 0)

        env.perform(WriteFlag(key: "b", value: false))

        #expect(await waitUntil { rendered.last == ["a": true, "b": false] })
    }
}

#endif
