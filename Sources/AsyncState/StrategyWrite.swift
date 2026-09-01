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

/// Hidden Sync operation for AsyncStrategy inbound verbs. Apps do not perform it.
///
/// One called on the caller's stack joins that caller's observation round instead of flushing its
/// own; with no Operation in flight it is itself the original.
struct StrategyWrite: SyncOperation {
    let apply: (AsyncStateRuntime) -> Void

    func perform(in env: SyncOperationEnvironment) {
        apply(env.environment.asyncState)
    }
}
