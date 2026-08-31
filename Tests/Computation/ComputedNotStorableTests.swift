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

final class NotStorableState: StateContainer {
    var registry: [String: Computed<NoKey, Int>] = [:]
    var slot = Computed<NoKey, Int> { _ in 1 }
    var plain: [String: Int] = [:]
}

/// Writes through a type parameter, so the call resolves to the generic `write` rather than to
/// the deprecated Computed twin. Only the runtime marker can catch this one.
struct WriteThroughGeneric<Value>: SyncOperation {
    let value: Value
    let address: WritableKeyPath<NotStorableState, Value>

    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: address)
    }
}

@Suite("A Computed is not storable") @MainActor
struct ComputedNotStorableTests {

    #if os(macOS)
    /// The generic path is the one a compile-time refusal cannot reach, so the marker has to.
    @Test("Writing a Computed through a generic Value traps")
    func genericWriteOfComputedTraps() async {
        let result = await #expect(
            processExitsWith: .failure,
            observing: [\.standardErrorContent]
        ) {
            await MainActor.run {
                let env = SharedEnvironment()
                env.perform(
                    WriteThroughGeneric(
                        value: Computed<NoKey, Int> { _ in 9 },
                        address: \NotStorableState.slot
                    )
                )
            }
        }
        let text = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        #expect(text.contains("A Computed is derived, not stored"))
    }

    /// The marker rides through a container, so a registry keyed by id is refused too — the
    /// shape that made a stored Computed unevaluable in the first place.
    @Test("Writing a dictionary of Computeds through a generic Value traps")
    func genericWriteOfComputedDictionaryTraps() async {
        let result = await #expect(
            processExitsWith: .failure,
            observing: [\.standardErrorContent]
        ) {
            await MainActor.run {
                let env = SharedEnvironment()
                env.perform(
                    WriteThroughGeneric(
                        value: ["slot": Computed<NoKey, Int> { _ in 9 }],
                        address: \NotStorableState.registry
                    )
                )
            }
        }
        let text = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        #expect(text.contains("A Computed is derived, not stored"))
    }

    #endif

    /// An ordinary Value still writes: the marker refuses Computeds, not every container.
    @Test("Writing an ordinary Value through a generic Value still succeeds")
    func genericWriteOfPlainValueSucceeds() {
        let env = SharedEnvironment()
        env.perform(WriteThroughGeneric(value: ["a": 1], address: \NotStorableState.plain))
        #expect(env.read(\NotStorableState.plain) == ["a": 1])
    }
}
