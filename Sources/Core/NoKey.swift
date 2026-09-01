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

/// The Key of an Atomic Address, where the declaration names a whole fact rather than one entry.
///
/// You never write this yourself: `@Computed` infers it from a single-argument closure, and
/// `@AsyncState` from a non-dictionary Value. It only shows up in the inferred types
/// `Computed<NoKey, Output>` and `AsyncState<S, NoKey, Value, Value>`, and in diagnostics.
public enum NoKey: Hashable {
    case noKey
}
