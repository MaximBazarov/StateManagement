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
/// A unique identifier for values stored in a ``StateContainer``.
///
/// > **Implementation Detail**: Uses `AnyKeyPath` instead of `ObjectIdentifier(keyPath)` to ensure
/// > stable value-based keypath equality and hashing. In Swift, `ObjectIdentifier` compares reference identity
/// > of keypath objects, which can vary across compiler contexts, modules, and dynamic instances, causing
/// > subscriptions to miss updates. `AnyKeyPath` provides reliable structural comparison.
@_documentation(visibility: private)
public struct ValueID: Hashable, CustomDebugStringConvertible {
    /// The keypath referencing the state value. Conforms to `Hashable` and `Equatable` using value-based equality.
    let valueKeyPathID: AnyKeyPath

    // Used only for collections like dictionary, array etc.
    // For atomic values always nil.
    let id: AnyHashable?

    public var debugDescription: String {
        if let id {
            return "[" + String(describing: valueKeyPathID) + ": \(id)]"
        }
        else {
            return String(describing: valueKeyPathID)
        }
    }

    init<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>
    ) {
        self.valueKeyPathID = keyPath
        self.id = nil
    }

    init<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable
    ) {
        self.valueKeyPathID = keyPath
        self.id = key
    }

    init<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: WritableKeyPath<Storage, [Key: Value]>,
        key: AnyHashable
    ) {
        self.valueKeyPathID = keyPath
        self.id = key
    }

    init<Storage: StateContainer, Key: Hashable, Value>(
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: AnyHashable
    ) {
        self.valueKeyPathID = keyPath
        self.id = key
    }

    // MARK: - Hashable & Equatable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(valueKeyPathID)
        hasher.combine(id)
    }

    public static func == (lhs: ValueID, rhs: ValueID) -> Bool {
        lhs.valueKeyPathID == rhs.valueKeyPathID && lhs.id == rhs.id
    }
}
