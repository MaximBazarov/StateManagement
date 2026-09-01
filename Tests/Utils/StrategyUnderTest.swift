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

@testable import StateManagement

extension SharedEnvironment {

    /// Seats a strategy instance and hands it back, so a test holds the same object the seam
    /// calls and can count its kicks.
    @MainActor
    func strategyUnderTest<S: AsyncStrategy>(_ type: S.Type) -> S {
        let created = S(env: strategyEnvironment())
        install(created)
        return created
    }
}
