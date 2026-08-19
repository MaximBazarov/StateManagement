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

// MARK: - State

final class IsoState: StateContainer {
    var x = 0
}

final class IsoOther: StateContainer {
    var y = 100
}

// MARK: - Operations

struct IsoSetX: SyncOperation {
    let value: Int
    func perform(in env: SyncOperationEnvironment) {
        env.write(value, keyPath: \IsoState.x)
    }
}

// MARK: - Tests

/// Every test builds its own ``SharedEnvironment``, so isolation between
/// instances is the assumption the whole suite rests on. These tests make that
/// assumption explicit, and cover lazy container creation.
@Suite @MainActor
struct EnvironmentIsolationTests {

    /// Two environments do not share state. A write to one leaves the other at
    /// its default.
    @Test func separateEnvironmentsAreIsolated() {
        let a = SharedEnvironment()
        let b = SharedEnvironment()

        a.perform(IsoSetX(value: 5))

        #expect(a.getValue(keyPath: \IsoState.x) == 5)
        #expect(b.getValue(keyPath: \IsoState.x) == 0)
    }

    /// A container is created lazily on first read and returns the stored-property
    /// default, no operation required.
    @Test func lazyContainerReturnsDefault() {
        let env = SharedEnvironment()
        #expect(env.getValue(keyPath: \IsoState.x) == 0)
        #expect(env.getValue(keyPath: \IsoOther.y) == 100)
    }

    /// Distinct container types live side by side without cross-type pollution.
    @Test func distinctContainerTypesCoexist() {
        let env = SharedEnvironment()

        env.perform(IsoSetX(value: 5))

        #expect(env.getValue(keyPath: \IsoState.x) == 5)
        #expect(env.getValue(keyPath: \IsoOther.y) == 100)
    }
}
