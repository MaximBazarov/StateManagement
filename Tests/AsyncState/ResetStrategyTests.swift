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

final class ResetSourcedBox: StateContainer {
    @AsyncState(ResetStrategy.self) var theme: String = "system"
}

@MainActor
final class ResetStrategy: AsyncStrategy {
    typealias Failure = Never
    private(set) var onDropCount = 0

    init(env _: AsyncStrategyEnvironment) {}

    func onDrop<Storage: StateContainer, Value>(
        _ address: KeyPath<Storage, AsyncState<ResetStrategy, NoKey, Value, Value>>,
        policy _: Void
    ) {
        onDropCount += 1
    }
}

struct ResetSourced: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.reset(ResetSourcedBox.self)
    }
}

@Suite @MainActor
struct ResetStrategyTests {

    @Test("reset(_:) calls onDrop on the sourced Address and keeps the strategy")
    func targetedResetCallsOnDrop() {
        let env = SharedEnvironment()
        let strategy = ResetStrategy(env: env.strategyEnvironment())
        env.install(strategy)
        env.preheat(\ResetSourcedBox.$theme)
        #expect(strategy.onDropCount == 0)

        env.perform(ResetSourced())

        #expect(strategy.onDropCount == 1)
        #expect(env.strategyInstance(ResetStrategy.self) === strategy)
    }

    @Test("reset() calls onDrop and drops the strategy instance")
    func fullResetDropsStrategyInstance() {
        let env = SharedEnvironment()
        let strategy = ResetStrategy(env: env.strategyEnvironment())
        env.install(strategy)
        env.preheat(\ResetSourcedBox.$theme)

        env.perform(ResetAll())

        #expect(strategy.onDropCount == 1)
        #expect(env.strategyInstance(ResetStrategy.self) !== strategy)
    }
}
