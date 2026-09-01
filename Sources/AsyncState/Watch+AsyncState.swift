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

extension Watch {

    /// Marks the watched sourced Address Stale and calls `onRead` again.
    ///
    /// Synchronous. The status does not change until the strategy calls `apply` or `fail`, so the
    /// body keeps rendering the current Value while the reload runs. A keyed Watch refreshes its
    /// own key. No-op (logged) when the watched Address is not backed by an AsyncStrategy, or
    /// before the first body read.
    public func refresh() {
        environment.refreshAddress(valueID: valueID)
    }
}
#endif  // canImport(SwiftUI)
