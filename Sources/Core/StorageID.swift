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

// Tests and other modules name this type. The user catalog does not start here.
/// Identifier of the instance of the Storage.
/// We use ObjectIdentifier of the type
@_documentation(visibility: private)
public struct StorageID: Hashable, Equatable {
    let id: ObjectIdentifier

    init<Storage: StateContainer>(_ storageType: Storage.Type) {
        self.id = ObjectIdentifier(storageType)
    }
}
