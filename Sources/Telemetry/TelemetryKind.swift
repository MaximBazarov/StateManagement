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

/// Categorizes a telemetry trace span.
///
/// Classification allows performance collectors and ingestion pipelines to segment user-facing application flows
/// from framework-level runtime operations.
public enum TelemetryKind {
    /// User-facing application flows, mutations, actions, and transactions.
    case user
    
    /// Low-level framework internal events (e.g. subscription dispatch, state invalidations).
    case `internal`
}
