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
/// An object that is notified by ``ObservationRegistry`` when ``ValueID`` changes.
/// Receives a set of all values' IDs changed within the operation that notified.
/// To subscribe to the changes of the value use ``ObservationRegistry/subscribe(receiver:valueID:)``.
@_documentation(visibility: private)
@MainActor public final class NotificationReceiver: @MainActor Hashable {

    var id: String {
        ObjectIdentifier(self)
            .debugDescription
            .replacingOccurrences(of: "ObjectIdentifier(", with: "(")
    }

    let callback: (Set<ValueID>) -> Void

    /// Register a closure to call when notification is received.
    /// - Parameter callback: called when notification is received with a set of IDs of changed values.
    public init(callback: @escaping (Set<ValueID>) -> Void) {
        self.callback = callback
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func == (lhs: NotificationReceiver, rhs: NotificationReceiver) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}
