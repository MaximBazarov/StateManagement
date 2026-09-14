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
    private let timeout: Duration
    private var count: Int = 0
    struct Timeout: Error {}
    var continuation:  CheckedContinuation<Void, any Error>?
    var timeoutTask: Task<Void, Never>?

    /// - Parameters:
    ///   - expectedCount: How many `resume()` calls release the `wait()`.
    ///   - timeout: Deadline for the expected resumes to arrive. The default is deliberately
    ///     generous: a successful wait resumes the moment the last `resume()` lands, so the
    ///     deadline only bounds how long a genuinely broken run takes to fail. Under parallel
    ///     test execution on CI simulators the shared MainActor can lag by seconds, so a tight
    ///     deadline here reads scheduler backlog as a product failure. Tests that assert an
    ///     update must NOT arrive pass a short explicit timeout instead, since they always
    ///     wait out the full deadline.
    init(expectedCount: Int, timeout: Duration = .seconds(10)) {
        self.expectedCount = expectedCount
        self.timeout = timeout
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
                try? await Task.sleep(for: timeout)
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
