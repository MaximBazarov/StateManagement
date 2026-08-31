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

extension EnvironmentService {

    // MARK: - wasUpdated

    /// Whether this computed was among the values changed in the update the service is serving.
    public func wasUpdated<Storage: StateContainer, Output>(
        _ valueKeyPath: KeyPath<Storage, Computed<NoKey, Output>>
    ) -> Bool {
        updatedValues.contains(ValueID(keyPath: valueKeyPath))
    }

    /// Whether any of these computeds was among the values changed in the update the service is serving.
    public func wasUpdated<Storage: StateContainer, Output>(
        _ valueKeyPaths: [KeyPath<Storage, Computed<NoKey, Output>>]
    ) -> Bool {
        valueKeyPaths.contains { keyPath in
            updatedValues.contains(ValueID(keyPath: keyPath))
        }
    }

    /// Whether this computed, for `key`, was among the values changed in the update the service is serving.
    public func wasUpdated<Storage: StateContainer, Key: Hashable, Output>(
        _ valueKeyPath: KeyPath<Storage, Computed<Key, Output>>,
        key: Key
    ) -> Bool {
        updatedValues.contains(ValueID(keyPath: valueKeyPath, key: key))
    }

    // MARK: - Read

    /// Reads an atomic ``Computed`` value at given path.
    public func read<Storage: StateContainer, Output>(
        _ keyPath: KeyPath<Storage, Computed<NoKey, Output>>
    ) -> Output {
        let valueID = ValueID(keyPath: keyPath)
        let computation = env.getValue(keyPath: keyPath)
        return computation.read(env: env, valueID: valueID, receiver: notificationReceiver, key: .noKey)
    }

    /// Reads a keyed ``Computed`` value at given path for `key`.
    public func read<
        Storage: StateContainer,
        Key: Hashable,
        Output
    >(
        _ keyPath: KeyPath<Storage, Computed<Key, Output>>,
        key: Key
    ) -> Output {
        let valueID = ValueID(keyPath: keyPath, key: key)
        let computation = env.getValue(keyPath: keyPath)
        return computation.read(env: env, valueID: valueID, receiver: notificationReceiver, key: key)
    }

}
