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
import SwiftUI
import Testing
@testable import StateManagement

/// Deliberately non-`Equatable`: drives the always-notify (no-diffing) path.
struct Box {
    var n: Int
}

final class TestWatchState: StateContainer {
    var value: String = "initial"
    var dict: [String: String] = ["A": "valA", "B": "valB"]

    // Non-Equatable fixture: forces the `areEqual == nil` always-notify branch.
    var box = Box(n: 0)

    // Output-diffing fixture: the computed output (`parity`) is coarser than its
    // dependency (`counter`), so some dependency changes leave the output unchanged.
    var counter: Int = 0
    @Computed var parity = { (env: ComputationEnvironment) -> String in
        env.read(\TestWatchState.counter) % 2 == 0 ? "even" : "odd"
    }

    // Per-row selection fixture: a keyed computed over a single scalar selection.
    var selection: Int? = nil
    @Computed var isSelected = { (env: ComputationEnvironment, id: Int) -> Bool in
        env.read(\TestWatchState.selection) == id
    }

    // Non-Equatable dict fixture
    var boxDict: [String: Box] = ["A": Box(n: 1)]

    // Non-Equatable computed fixture
    @Computed var boxComputed = { (env: ComputationEnvironment) -> Box in
        Box(n: env.read(\TestWatchState.counter))
    }

    // Non-Equatable keyed computed fixture
    @Computed var boxKeyedComputed = { (env: ComputationEnvironment, key: String) -> Box in
        Box(n: env.read(\TestWatchState.counter) + key.count)
    }
}

struct UpdateValue: SyncOperation {
    let newValue: String
    func perform(in env: SyncOperationEnvironment) {
        env.write(\TestWatchState.value, value: newValue)
    }
}

struct UpdateDictValue: SyncOperation {
    let key: String
    let newValue: String
    func perform(in env: SyncOperationEnvironment) {
        env.write(\TestWatchState.dict, key: key, value: newValue)
    }
}

struct SetCounter: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(\TestWatchState.counter, value: value)
    }
}

struct SetSelection: SyncOperation {
    let id: Int?
    func perform(in env: SyncOperationEnvironment) {
        env.write(\TestWatchState.selection, value: id)
    }
}

struct SetBox: SyncOperation {
    let n: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(\TestWatchState.box, value: Box(n: n))
    }
}

struct SetBoxDict: SyncOperation {
    let key: String; let n: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(\TestWatchState.boxDict, key: key, value: Box(n: n))
    }
}

// MARK: - SwiftUI integration fixtures (host-only)

#if canImport(AppKit) || canImport(UIKit)
/// Per-test render counter. A reference (not a global) so the integration test
/// owns its own state and stays safe under swift-testing's parallelism.
@MainActor
final class RenderCounter {
    var count = 0
}

@MainActor
struct TestView: View {
    let counter: RenderCounter
    @Watch(\TestWatchState.value) var value

    var body: some View {
        let _ = counter.count += 1
        Text(value)
    }
}

/// One view carrying each `@Watch` Address shape. Nothing here asserts behaviour: it fails by not
/// compiling, which is the only way a wrong Address in a documented example gets caught.
@MainActor
struct WatchShapesView: View {
    let counter: RenderCounter

    @Watch(\TestWatchState.value) var value
    @Watch(\TestWatchState.dict, key: "A") var dictValue
    @Watch(computed: \TestWatchState.$parity) var parity
    @Watch<TestWatchState, Bool> var isSelected: Bool

    /// A property-wrapper argument cannot reach `self`, so today a per-row key arrives through an
    /// init. Reaching the row off one wrapper instead is [#65](https://github.com/MaximBazarov/SSM-Development/issues/65).
    init(id: Int, counter: RenderCounter) {
        self.counter = counter
        self._isSelected = Watch(\TestWatchState.$isSelected, key: id)
    }

    var body: some View {
        let _ = counter.count += 1
        Text("\(value) \(dictValue ?? "") \(parity) \(isSelected)")
    }
}

/// Holds the `Watch.binding` so the test can `set` after the first body, the
/// same path a SwiftUI control uses.
@MainActor
final class WatchBindingHolder {
    var binding: Binding<String>?
}

@MainActor
struct BindingWriteView: View {
    let counter: RenderCounter
    let holder: WatchBindingHolder
    @Watch(\TestWatchState.value) var value

    var body: some View {
        let _ = counter.count += 1
        let _ = holder.binding = $value.binding { newValue, env in
            env.write(\TestWatchState.value, value: newValue)
        }
        Text(value)
    }
}
#endif

@Suite
@MainActor
struct WatchTests {

    // MARK: - Real SwiftUI Integration Smoke Test

    #if canImport(AppKit) || canImport(UIKit)
    /// The one test that spins up an actual SwiftUI host (`NSHostingController` on
    /// macOS, `UIHostingController` on iOS): it proves the `@Watch` struct wires
    /// `@Environment` + `@StateObject` to the `SubscribingValueReader` and that a mutation
    /// re-evaluates `body`. All behavioural assertions live in the headless
    /// `ValueObserverProbe` tests. Deterministic via `waitUntil` — no sleeps.
    @Test func watchSwiftUIIntegration() async throws {
        let env = SharedEnvironment()
        let counter = RenderCounter()

        let host = HostedView.mount(TestView(counter: counter).sharedEnvironment(env))
        defer { host.teardown() }

        #expect(counter.count >= 1) // initial render happened

        let before = counter.count
        env.perform(UpdateValue(newValue: "updated"))
        host.relayout()

        let rendered = await waitUntil { counter.count > before }
        #expect(rendered, "body did not re-evaluate after state change")
    }

    /// Guards the Address spelling of each `@Watch` shape. A Computed is reached through
    /// `\C.$name`, because `wrappedValue` is the computation closure, so dropping the `$` binds the
    /// wrong overload or none at all — which is how the ``StateContainer`` DocC went stale.
    @Test("Every Watch Address shape resolves against a real Container")
    func watchAddressShapes() async throws {
        let env = SharedEnvironment()
        let counter = RenderCounter()

        let host = HostedView.mount(
            WatchShapesView(id: 1, counter: counter).sharedEnvironment(env)
        )
        defer { host.teardown() }

        #expect(counter.count >= 1)

        let before = counter.count
        env.perform(SetSelection(id: 1))
        host.relayout()

        let rendered = await waitUntil { counter.count > before }
        #expect(rendered, "keyed computed Watch did not re-evaluate body")
    }

    /// Binding `set` is a view update. `Watch` must still re-render after that
    /// write once `objectWillChange` hops off the current update.
    @Test("Watch.binding set re-evaluates body")
    func watchBindingSetRerenders() async throws {
        let env = SharedEnvironment()
        let counter = RenderCounter()
        let holder = WatchBindingHolder()

        let host = HostedView.mount(
            BindingWriteView(counter: counter, holder: holder).sharedEnvironment(env)
        )
        defer { host.teardown() }

        #expect(counter.count >= 1)
        let published = await waitUntil { holder.binding != nil }
        #expect(published, "body did not publish a Binding")

        let before = counter.count
        holder.binding?.wrappedValue = "from-binding"
        host.relayout()

        let rendered = await waitUntil { counter.count > before }
        #expect(rendered, "body did not re-evaluate after Watch.binding set")
        #expect(holder.binding?.wrappedValue == "from-binding")
    }
    #endif

    // MARK: - Atomic Value Observation

    @Test func atomicValue_changeTriggersRender() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, String>.watch(\.value, in: env)

        #expect(sim.renderCount == 1)
        #expect(sim.lastValue == "initial")

        env.perform(UpdateValue(newValue: "updated"))

        #expect(sim.renderCount == 2)
        #expect(sim.lastValue == "updated")
    }

    /// New uniform diffing: an Equatable atomic value set to an equal value
    /// suppresses the re-render, same as computeds.
    @Test func atomicValue_equalWriteIsSuppressed() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, String>.watch(\.value, in: env)
        sim.expect(value: "initial")

        sim.perform(UpdateValue(newValue: "initial")) // same value
        sim.expect(suppressed: true)
        sim.expect(updates: 0)

        sim.perform(UpdateValue(newValue: "changed"))
        sim.expect(updates: 1)
        sim.expect(value: "changed")
    }

    /// Regression mirror of the computed case: a suppressed atomic update must
    /// not drop the subscription. Routing atomic through diffing means the
    /// receiver re-subscribes via `getValue`; the next real change must arrive.
    @Test func atomicValue_suppressionDoesNotDropSubscription() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, String>.watch(\.value, in: env)

        sim.perform(UpdateValue(newValue: "initial")) // suppressed, no re-render
        sim.expect(updates: 0)

        sim.perform(UpdateValue(newValue: "next"))    // must still arrive
        sim.expect(updates: 1)
        sim.expect(value: "next")
    }

    // MARK: - Keyed Dictionary Isolation

    @Test func keyedDictionary_onlyMatchingKeyRenders() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, String?>.watchKeyed(\.dict, key: "A", in: env)

        #expect(sim.renderCount == 1)
        #expect(sim.lastValue == "valA")

        // Mutating key "B" must NOT re-render the "A" watcher.
        env.perform(UpdateDictValue(key: "B", newValue: "newB"))
        #expect(sim.renderCount == 1)

        // Mutating key "A" MUST re-render it.
        env.perform(UpdateDictValue(key: "A", newValue: "newA"))
        #expect(sim.renderCount == 2)
        #expect(sim.lastValue == "newA")
    }

    /// New uniform diffing: writing an equal value to a watched key suppresses.
    @Test func keyedDictionary_equalWriteIsSuppressed() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, String?>.watchKeyed(\.dict, key: "A", in: env)
        sim.expect(value: "valA")

        sim.perform(UpdateDictValue(key: "A", newValue: "valA")) // same value
        sim.expect(updates: 0)

        sim.perform(UpdateDictValue(key: "A", newValue: "newA"))
        sim.expect(updates: 1)
        sim.expect(value: "newA")
    }

    // MARK: - Computed Output-Diffing

    @Test func computed_unchangedOutputIsSuppressed() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, String>.watch(computed: \.$parity, in: env)

        #expect(sim.renderCount == 1)
        #expect(sim.lastValue == "even")

        // counter 0 -> 2: dependency changes, but parity stays "even" -> suppressed.
        env.perform(SetCounter(value: 2))
        #expect(sim.renderCount == 1)
        #expect(sim.lastValue == "even")

        // counter 2 -> 1: parity flips to "odd" -> renders.
        env.perform(SetCounter(value: 1))
        #expect(sim.renderCount == 2)
        #expect(sim.lastValue == "odd")
    }

    /// Regression: a suppressed (unchanged-output) notification must NOT silently
    /// drop the subscription. After a suppression, a genuinely-changing update —
    /// with no intervening manual re-subscribe / layout pass — must still render.
    /// This guards the load-bearing invariant that the diffing re-evaluation
    /// re-subscribes the receiver.
    @Test func computed_suppressionDoesNotDropSubscription() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, String>.watch(computed: \.$parity, in: env)
        #expect(sim.renderCount == 1)

        // Suppressed: 0 -> 4 keeps parity "even". No re-render, no layout pass.
        env.perform(SetCounter(value: 4))
        #expect(sim.renderCount == 1)

        // The very next real change must still arrive.
        env.perform(SetCounter(value: 3))
        #expect(sim.renderCount == 2)
        #expect(sim.lastValue == "odd")
    }

    // MARK: - Keyed Computed (Per-Row Selection)

    /// Moving a single scalar selection must re-render only the rows whose
    /// selected-ness actually flips, not every keyed watcher of the computed.
    @Test func keyedComputed_selectionWakesOnlyAffectedRows() {
        let env = SharedEnvironment()
        let row5 = ValueObserverProbe<TestWatchState, Bool>.watch(computedKeyed: \.$isSelected, key: 5, in: env)
        let row7 = ValueObserverProbe<TestWatchState, Bool>.watch(computedKeyed: \.$isSelected, key: 7, in: env)

        #expect(row5.lastValue == false)
        #expect(row7.lastValue == false)
        #expect(row5.renderCount == 1)
        #expect(row7.renderCount == 1)

        // Select 5: row 5 flips false -> true; row 7 stays false (suppressed).
        env.perform(SetSelection(id: 5))
        #expect(row5.renderCount == 2)
        #expect(row5.lastValue == true)
        #expect(row7.renderCount == 1)

        // Move selection 5 -> 7: both flip, both render.
        env.perform(SetSelection(id: 7))
        #expect(row5.renderCount == 3)
        #expect(row5.lastValue == false)
        #expect(row7.renderCount == 2)
        #expect(row7.lastValue == true)
    }

    /// A suppressed keyed-computed notification must not drop the subscription.
    @Test func keyedComputed_suppressionDoesNotDropSubscription() {
        let env = SharedEnvironment()
        let row5 = ValueObserverProbe<TestWatchState, Bool>.watch(computedKeyed: \.$isSelected, key: 5, in: env)

        env.perform(SetSelection(id: 7)) // row 5 stays false -> suppressed
        row5.expect(updates: 0)

        env.perform(SetSelection(id: 5)) // row 5 flips -> must render
        row5.expect(updates: 1)
        #expect(row5.lastValue == true)
    }

    // MARK: - Non-Equatable (always notify)

    /// Non-`Equatable` values have no diffing: every dependency change re-renders,
    /// even when the written value is "equal", because there is no `==` to compare.
    @Test func nonEquatable_alwaysNotifiesEvenOnEqualWrite() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, Box>.watchRaw(\.box, in: env)
        #expect(sim.renderCount == 1)

        env.perform(SetBox(n: 0)) // same n, but non-Equatable -> no suppression
        sim.expect(updates: 1)

        env.perform(SetBox(n: 0)) // again -> renders again
        sim.expect(updates: 2)
    }

    // MARK: - Keyed Dictionary edge cases

    /// A suppressed keyed-dictionary notification must not drop the subscription.
    @Test func keyedDictionary_suppressionDoesNotDropSubscription() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, String?>.watchKeyed(\.dict, key: "A", in: env)

        env.perform(UpdateDictValue(key: "A", newValue: "valA")) // equal -> suppressed
        sim.expect(updates: 0)

        env.perform(UpdateDictValue(key: "A", newValue: "newA")) // changed -> renders
        sim.expect(updates: 1)
        sim.expect(value: "newA")
    }

    /// Watching an absent key starts at `nil`; inserting it must render.
    @Test func keyedDictionary_absentKeyInsertionRenders() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, String?>.watchKeyed(\.dict, key: "Z", in: env)
        sim.expect(value: nil) // absent

        env.perform(UpdateDictValue(key: "Z", newValue: "valZ"))
        sim.expect(updates: 1)
        sim.expect(value: "valZ")
    }

    // MARK: - Multiple observers

    /// Two observers of the same `ValueID` each render with their own baseline.
    @Test func twoObservers_sameValueID_bothRender() {
        let env = SharedEnvironment()
        let a = ValueObserverProbe<TestWatchState, String>.watch(\.value, in: env)
        let b = ValueObserverProbe<TestWatchState, String>.watch(\.value, in: env)

        env.perform(UpdateValue(newValue: "x"))
        a.expect(updates: 1)
        a.expect(value: "x")
        b.expect(updates: 1)
        b.expect(value: "x")
    }

    // MARK: - Non-Equatable keyed, computed, keyed-computed

    /// Non-Equatable keyed dictionary always notifies (no diffing).
    @Test func nonEquatable_keyedAlwaysNotifies() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, Box?>.watchKeyedRaw(\.boxDict, key: "A", in: env)
        #expect(sim.renderCount == 1)

        env.perform(SetBoxDict(key: "A", n: 1)) // same n, but no Equatable -> re-renders
        sim.expect(updates: 1)

        env.perform(SetBoxDict(key: "A", n: 1)) // again -> re-renders again
        sim.expect(updates: 2)
    }

    /// Non-Equatable computed always notifies (no diffing).
    @Test func nonEquatable_computedAlwaysNotifies() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, Box>.watchComputedRaw(\.$boxComputed, in: env)
        #expect(sim.renderCount == 1)

        env.perform(SetCounter(value: 0)) // same counter=0, but non-Equatable -> re-renders
        sim.expect(updates: 1)
    }

    /// Non-Equatable keyed computed always notifies (no diffing).
    @Test func nonEquatable_keyedComputedAlwaysNotifies() {
        let env = SharedEnvironment()
        let sim = ValueObserverProbe<TestWatchState, Box>.watchComputedKeyedRaw(\.$boxKeyedComputed, key: "x", in: env)
        #expect(sim.renderCount == 1)

        env.perform(SetCounter(value: 0)) // same counter, non-Equatable -> re-renders
        sim.expect(updates: 1)
    }
}
