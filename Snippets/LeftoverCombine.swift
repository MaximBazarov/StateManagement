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

// The leftover-Combine example in README.md. `swift build` compiles it, so a
// change to a public signature breaks the build instead of rotting the README.
// The region between the markers is compared byte for byte against the README
// block by `Scripts/check-docs.sh`; edit the two together.

// README:begin
import Combine
import StateManagement

final class SettingsController: StateContainer, ObservableObject {
    @SMPublished var theme = "system"
}

let leftover = SettingsController()
leftover.theme = "dark"                       // always SharedEnvironment.shared
let sub = leftover.$theme.sink { print($0) }  // Publisher<Value, Never>, not Published.Publisher
// README:end
