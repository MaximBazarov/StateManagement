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

// The quick-start example in README.md. `swift build` compiles it, so a change
// to a public signature breaks the build instead of rotting the README.
// The region between the markers is compared byte for byte against the README
// block by `Scripts/check-docs.sh`; edit the two together.

// README:begin
import SwiftUI
import StateManagement

final class CounterContainer: StateContainer {
    var count: Int = 0
}

struct Increment: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        let count = env.read(\CounterContainer.count)
        env.write(\CounterContainer.count, value: count + 1)
    }
}

struct CounterView: View {
    @Watch(\CounterContainer.count) var count: Int
    @Perform var perform

    var body: some View {
        Button("\(count)") { perform(Increment()) }
    }
}

let root = CounterView()
    .sharedEnvironment(SharedEnvironment())
// README:end
