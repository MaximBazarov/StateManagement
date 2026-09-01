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

#if canImport(SwiftUI)
import Foundation
import SwiftUI
import Combine

/// SwiftUI-side conformance: `SubscribingValueReader` itself is Combine-free (Foundation
/// only). `@StateObject` requires `ObservableObject`, so the conformance — and
/// the `objectWillChange` publisher it brings — lives here, in the SwiftUI layer.
/// `Watch.wired(_:)` forwards the reader's `onChange` to `objectWillChange`.
extension SubscribingValueReader: ObservableObject {}

extension ObservableObjectPublisher {
    /// SwiftUI forbids `send()` during a view update. Binding `set` and
    /// notify-from-body are view updates. Hop to the next main run-loop
    /// turn, including tracking (scroll / press).
    ///
    /// `RunLoop.perform` takes `@Sendable`. Combine's publisher is not
    /// Sendable. This hop is MainActor to the main run loop; the value
    /// does not leave that thread.
    func sendAfterViewUpdate() {
        nonisolated(unsafe) let publisher = self
        RunLoop.main.perform(inModes: [.common]) {
            publisher.send()
        }
    }
}

/// A SwiftUI property wrapper that observes a single piece of state — an atomic
/// value, one dictionary key, or a computed value — and invalidates the view's
/// body when that state changes.
///
/// `Watch` is a thin adapter: all of the observation logic lives in
/// `SubscribingValueReader` (which is SwiftUI-independent and therefore unit-testable
/// headlessly). `Watch` only supplies the `SharedEnvironment` from the SwiftUI
/// environment and keeps the reader alive in a `@StateObject`.
///
/// Output diffing is automatic: when `Value` is `Equatable`, an unchanged output
/// suppresses the re-render. Non-`Equatable` values always notify.
///
/// > Note: Subscriptions are one-shot. `Watch` re-reads in `body`, so it re-subscribes on every
/// render. See <doc:Observing-State>.
@propertyWrapper
@MainActor
public struct Watch<Storage: StateContainer, Value>: DynamicProperty {

    // Internal, not private: `Watch.refresh()` is an AsyncState counterpart and lives in that area.
    @Environment(\.sharedEnvironment) var environment

    /// SwiftUI friendly way to store the reader, that will not recreate for the same view.
    /// For SwiftUI code only we extend `SubscribingValueReader` with ObservableObject conformance and we connect the `onChange` in `watching` function.
    ///
    /// > Quote from Apple docs: SwiftUI creates a new instance of the model object only once during the lifetime of the container that declares the state object. For example, SwiftUI doesn’t create a new instance if a view’s inputs change, but does create a new instance if the identity of a view changes. When published properties of the observable object change, SwiftUI updates any view that depends on those properties, like the Text view in the above example.
    ///
    @StateObject private var reader: SubscribingValueReader<Storage, Value>

    public let file: String
    public let line: UInt

    var valueID: ValueID {
        reader.valueID
    }

    /// A value at a given state key path and, when appropriate, a key.
    public var wrappedValue: Value {
        reader.read(in: environment)
    }

    /// Self published to access functions like ``binding(mutation:)`` etc.
    public var projectedValue: Self {
        self
    }

    /// Create a `SwiftUI.Binding<Value>` binding that mutates the value, by performing a generic sync operation - ``InlineValueMutation``.
    ///
    /// - Parameter mutation: A closure like a `perform(in:)`
    /// - Returns: SwiftUI Binding (`SwiftUI.Binding<Value>`).
    public func binding(
        mutation: @escaping (Value, SyncOperationEnvironment) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { newValue in
                let operation = InlineValueMutation(
                    value: newValue,
                    mutation: mutation
                )
                environment.perform(
                    operation,
                    file: self.file,
                    line: self.line
                )
            }
        )
    }

    // MARK: - Internals

    /// Builds the reader (`SubscribingValueReader`) and sends `objectWillChange` on its `onChange`.
    private static func watching(
        reader: SubscribingValueReader<Storage, Value>
    ) -> SubscribingValueReader<Storage, Value> {
        // SubscribingValueReader is Combine-free; bridge its `onChange` to SwiftUI here by
        // poking `objectWillChange` so a state change re-renders the view. Weak
        // capture: the reader owns this closure, so a strong ref would cycle.
        reader.onChange = { [weak reader] in
            reader?.objectWillChange.sendAfterViewUpdate()
        }
        return reader
    }

    // MARK: - Initialisers -

    /// Watches an Atomic Value. Equatable, so an unchanged Value does not re-render.
    public init(
        _ statePath: KeyPath<Storage, Value>,
        file: String = #fileID,
        line: UInt = #line
    )
    where Value: Equatable {
        self.file = file
        self.line = line
        self._reader = StateObject(
            wrappedValue: Self.watching(reader: .observingValue(statePath))
        )
    }

    /// Watches an Atomic Value that cannot be diffed, so every notification re-renders.
    public init(
        _ statePath: KeyPath<Storage, Value>,
        file: String = #fileID,
        line: UInt = #line
    ) {
        self.file = file
        self.line = line
        self._reader = StateObject(
            wrappedValue: Self.watching(reader: .observingValue(statePath))
        )
    }

    /// Watches a whole dictionary Value. The Address names the dictionary, not an entry, so a
    /// sourced dictionary does not kick `onRead` here. Equatable entries, so the dictionary diffs.
    public init<Key: Hashable, Entry: Equatable>(
        _ statePath: KeyPath<Storage, [Key: Entry]>,
        file: String = #fileID,
        line: UInt = #line
    ) where Value == [Key: Entry] {
        self.file = file
        self.line = line
        self._reader = StateObject(
            wrappedValue: Self.watching(reader: .observingDictionary(statePath))
        )
    }

    /// Watches a whole dictionary Value whose entries cannot be diffed, so every notification
    /// re-renders. Like its Equatable twin, naming the dictionary kicks nothing.
    public init<Key: Hashable, Entry>(
        _ statePath: KeyPath<Storage, [Key: Entry]>,
        file: String = #fileID,
        line: UInt = #line
    ) where Value == [Key: Entry] {
        self.file = file
        self.line = line
        self._reader = StateObject(
            wrappedValue: Self.watching(reader: .observingDictionary(statePath))
        )
    }

    /// Watches one entry of a dictionary Value. Equatable, so an unchanged entry does not
    /// re-render. `nil` while the key is absent.
    public init<Key: Hashable, Output: Equatable>(
        _ statePath: KeyPath<Storage, [Key: Output]>,
        key: Key,
        file: String = #fileID,
        line: UInt = #line
    ) where Value == Output? {
        self.file = file
        self.line = line
        self._reader = StateObject(
            wrappedValue: Self.watching(reader: .buildKeyedValueReader(statePath, key: key))
        )
    }

    /// Watches one entry of a dictionary Value that cannot be diffed, so every notification
    /// re-renders.
    public init<Key: Hashable, Output>(
        _ statePath: KeyPath<Storage, [Key: Output]>,
        key: Key,
        file: String = #fileID,
        line: UInt = #line
    ) where Value == Output? {
        self.file = file
        self.line = line
        self._reader = StateObject(
            wrappedValue: Self.watching(reader: .buildKeyedValueReader(statePath, key: key))
        )
    }

    /// Watches an Atomic ``Computed``. Equatable, so an unchanged output does not re-render.
    public init(
        computed statePath: KeyPath<Storage, Computed<NoKey, Value>>,
        file: String = #fileID,
        line: UInt = #line
    ) where Value: Equatable {
        self.file = file
        self.line = line
        self._reader = StateObject(
            wrappedValue: Self.watching(reader: .observingComputed(statePath))
        )
    }

    /// Watches an Atomic ``Computed`` whose output cannot be diffed, so every recompute
    /// re-renders.
    public init(
        computed statePath: KeyPath<Storage, Computed<NoKey, Value>>,
        file: String = #fileID,
        line: UInt = #line
    ) {
        self.file = file
        self.line = line
        self._reader = StateObject(
            wrappedValue: Self.watching(reader: .observingComputed(statePath))
        )
    }

    /// Watches one key of a Keyed ``Computed``. Equatable, so an unchanged output does not
    /// re-render.
    public init<Key: Hashable>(
        _ statePath: KeyPath<Storage, Computed<Key, Value>>,
        key: Key,
        file: String = #fileID,
        line: UInt = #line
    ) where Value: Equatable {
        self.file = file
        self.line = line
        self._reader = StateObject(
            wrappedValue: Self.watching(reader: .observingComputedKeyed(statePath, key: key)
            )
        )
    }

    /// Watches one key of a Keyed ``Computed`` whose output cannot be diffed, so every recompute
    /// re-renders.
    public init<Key: Hashable>(
        _ statePath: KeyPath<Storage, Computed<Key, Value>>,
        key: Key,
        file: String = #fileID,
        line: UInt = #line
    ) {
        self.file = file
        self.line = line
        self._reader = StateObject(
            wrappedValue: Self.watching(reader: .observingComputedKeyed(statePath, key: key))
        )
    }
}
#endif  // canImport(SwiftUI)
