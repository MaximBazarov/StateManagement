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

/// Identifier of the instance of the Storage.
/// We use ObjectIdentifier of the type
public struct StorageID: Hashable, Equatable {
    let id: ObjectIdentifier

    init<Storage: StateContainer>(_ storageType: Storage.Type) {
        self.id = ObjectIdentifier(storageType)
    }
}
