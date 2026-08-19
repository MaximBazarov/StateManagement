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

/// Hidden Sync operation for Source verbs. Apps do not perform it.
struct SourceWrite: SyncOperation {
    let apply: (SharedEnvironment) -> Void

    func perform(in env: SyncOperationEnvironment) {
        apply(env.environment)
    }
}
