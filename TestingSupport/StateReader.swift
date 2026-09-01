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
import StateManagement

/// The sanctioned read for a test or a preview: a concrete `StateManagement.EnvironmentService`, and therefore a
/// Restricted Environment, so its reads carry a known reader.
///
/// It adds nothing. `read` for atomic, keyed, and computed Values is inherited, which is the point:
/// out-of-package callers get the reads without the core exposing an identity-free one and without
/// a Satellite reaching for `@testable` (ADR 0023).
///
/// Its reads subscribe, like any Service. Overriding `StateManagement.EnvironmentService.serve()` is not required; a reader that
/// never reacts simply leaves the subscription unused.
@MainActor public final class StateReader: EnvironmentService {}
