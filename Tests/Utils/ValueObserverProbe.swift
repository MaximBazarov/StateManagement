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

/// A headless stand-in for SwiftUI's runtime around a single ``SubscribingValueReader``.
///
/// It drives the real ``SubscribingValueReader`` — the exact code path `@Watch` uses —
/// without an `NSHostingController`, a render loop, or `Task.sleep`. The probe
/// models the two halves of SwiftUI's contract:
///
/// * `render()` evaluates the "body": it reads the value (which subscribes and,
///   for computeds, registers dependencies) and records what was produced.
/// * the observer's `onChange` triggers a re-`render()` when `autoRerender` is
///   on — exactly as SwiftUI invalidates and re-evaluates a body when an
///   observed object changes.
///
/// The re-render-on-change loop is the probe's real job: the subscription is
/// one-shot (removed by `ObservationRegistry.notifyAll()`), so re-reading on each
/// notification is what keeps the observer live. Counting is incidental.
///
/// Because suppression (an unchanged output) never fires `onChange`, it never
/// triggers a re-render — so `renderCount` is a faithful proxy for "how many
/// times would SwiftUI have re-evaluated this view".
@MainActor
final class ValueObserverProbe<Storage: StateContainer, Value> {

    let environment: SharedEnvironment
    let observer: SubscribingValueReader<Storage, Value>

    /// Number of times the "body" has been evaluated (initial render + each
    /// change-driven re-render).
    private(set) var renderCount = 0

    /// Re-renders driven by a state change, excluding the initial render.
    var updates: Int { renderCount - 1 }

    /// Value produced by the most recent render.
    private(set) var lastValue: Value?

    /// When true, the observer's `onChange` triggers a re-render, mirroring
    /// SwiftUI re-evaluating `body`. Turn off to drive renders by hand.
    var autoRerender: Bool

    init(
        _ environment: SharedEnvironment,
        observer: SubscribingValueReader<Storage, Value>,
        autoRerender: Bool = true
    ) {
        self.environment = environment
        self.observer = observer
        self.autoRerender = autoRerender
        observer.onChange = { [weak self] in
            guard let self, self.autoRerender else { return }
            self.render()
        }
    }

    /// Models SwiftUI evaluating `body`: reads the value (subscribing /
    /// registering dependencies), bumps the render count, records the value.
    @discardableResult
    func render() -> Value {
        renderCount += 1
        let value = observer.read(in: environment)
        lastValue = value
        return value
    }

    /// Run a sync operation against the shared environment. Chainable.
    @discardableResult
    func perform<Op: SyncOperation>(_ operation: Op) -> Self {
        environment.perform(operation)
        return self
    }
}

// MARK: - Expectations

extension ValueObserverProbe {

    /// Assert the number of change-driven re-renders since the initial render.
    func expect(updates expected: Int, _ sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(updates == expected, "expected \(expected) updates, got \(updates)", sourceLocation: sourceLocation)
    }

    /// Assert no re-render happened after the previous operation (output suppressed).
    func expect(suppressed: Bool = true, _ sourceLocation: SourceLocation = #_sourceLocation) {
        #expect((updates == 0) == suppressed, sourceLocation: sourceLocation)
    }
}

extension ValueObserverProbe where Value: Equatable {

    /// Assert the most recently rendered value.
    func expect(value expected: Value, _ sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(lastValue == expected, "expected \(expected), got \(String(describing: lastValue))", sourceLocation: sourceLocation)
    }
}

// MARK: - Factories mirroring @Watch's initializers

extension ValueObserverProbe {

    /// Simulates `@Watch(statePath)` and performs the initial render.
    static func watch(
        _ statePath: KeyPath<Storage, Value>,
        in environment: SharedEnvironment = SharedEnvironment()
    ) -> ValueObserverProbe where Value: Equatable {
        let probe = ValueObserverProbe(environment, observer: .observingValue(statePath))
        probe.render()
        return probe
    }

    /// Simulates `@Watch(statePath)` for a non-`Equatable` value. Unconstrained,
    /// so `.observingValue` resolves to the always-notify (no-diffing) factory —
    /// the only way to drive the `areEqual == nil` branch from a test.
    static func watchRaw(
        _ statePath: KeyPath<Storage, Value>,
        in environment: SharedEnvironment = SharedEnvironment()
    ) -> ValueObserverProbe {
        let probe = ValueObserverProbe(environment, observer: .observingValue(statePath))
        probe.render()
        return probe
    }

    /// Simulates `@Watch(computed:)` and renders once.
    static func watch(
        computed statePath: KeyPath<Storage, Computed<NoKey, Value>>,
        in environment: SharedEnvironment = SharedEnvironment()
    ) -> ValueObserverProbe where Value: Equatable {
        let probe = ValueObserverProbe(environment, observer: .observingComputed(statePath))
        probe.render()
        return probe
    }

    /// Simulates keyed `@Watch(computedPath, key:)` and renders once.
    static func watch<Key: Hashable>(
        computedKeyed statePath: KeyPath<Storage, Computed<Key, Value>>,
        key: Key,
        in environment: SharedEnvironment = SharedEnvironment()
    ) -> ValueObserverProbe where Value: Equatable {
        let probe = ValueObserverProbe(environment, observer: .observingComputedKeyed(statePath, key: key))
        probe.render()
        return probe
    }
}

extension ValueObserverProbe {

    /// Simulates keyed `@Watch(dictPath, key:)` and renders once.
    static func watchKeyed<Key: Hashable, Output: Equatable>(
        _ statePath: KeyPath<Storage, [Key: Output]>,
        key: Key,
        in environment: SharedEnvironment = SharedEnvironment()
    ) -> ValueObserverProbe where Value == Output? {
        let probe = ValueObserverProbe(environment, observer: .buildKeyedValueReader(statePath, key: key))
        probe.render()
        return probe
    }
}

// MARK: - Non-Equatable factories (always-notify overloads)

extension ValueObserverProbe {

    /// Non-Equatable keyed dictionary: always notify.
    static func watchKeyedRaw<Key: Hashable, Output>(
        _ statePath: KeyPath<Storage, [Key: Output]>,
        key: Key,
        in environment: SharedEnvironment = SharedEnvironment()
    ) -> ValueObserverProbe where Value == Output? {
        let probe = ValueObserverProbe(environment, observer: .buildKeyedValueReader(statePath, key: key))
        probe.render()
        return probe
    }

    /// Non-Equatable computed: always notify.
    static func watchComputedRaw(
        _ statePath: KeyPath<Storage, Computed<NoKey, Value>>,
        in environment: SharedEnvironment = SharedEnvironment()
    ) -> ValueObserverProbe {
        let probe = ValueObserverProbe(environment, observer: .observingComputed(statePath))
        probe.render()
        return probe
    }

    /// Non-Equatable keyed computed: always notify.
    static func watchComputedKeyedRaw<Key: Hashable>(
        _ statePath: KeyPath<Storage, Computed<Key, Value>>,
        key: Key,
        in environment: SharedEnvironment = SharedEnvironment()
    ) -> ValueObserverProbe {
        let probe = ValueObserverProbe(environment, observer: .observingComputedKeyed(statePath, key: key))
        probe.render()
        return probe
    }
}
