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
actor Waiter {
    private let expectedCount: Int
    private var count: Int = 0
    struct Timeout: Error {}
    var continuation:  CheckedContinuation<Void, any Error>?
    var timeoutTask: Task<Void, Never>?

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func wait() async throws {
        if count >= expectedCount {
            return
        }

        guard continuation == nil
        else {
            return
        }

        // Actual waiting for someone to call `continuation.resume()`
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task {
                try? await Task.sleep(for: .seconds(1))
                if count < expectedCount {
                    continuation.resume(throwing: Timeout())
                    self.continuation = nil
                }
            }            
        }
    }

    func resume() {
        count += 1
        if count >= expectedCount {
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation?.resume()
            continuation = nil
        }
    }
}
