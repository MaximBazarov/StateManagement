# Concurrency and offloading

Everything in the library is on the main actor. Heavy work leaves through one seam.

Containers, Operations, ``Computed``, Services, and ``SharedEnvironment`` are all `@MainActor`. That is what makes a read plus a write plus a notification one uninterrupted step. It also means an Operation that decodes a large payload or resizes an image blocks the main actor until it returns, so that work has to go somewhere else.

The seam is a free `async` function marked `nonisolated`, taking `Sendable` data in and returning `Sendable` data out, holding on to nothing:

```swift
nonisolated func decode(_ data: Data) async throws -> [Item] {
    try JSONDecoder().decode([Item].self, from: data)
}

struct LoadItems: AsyncOperation {
    let data: Data
    var reentrancy: ReentrancyDecision { .firstWins(.wholeOperation) }

    func perform(in env: AsyncOperationEnvironment) async {
        guard let items = try? await decode(data) else { return }
        env.perform(SetItems(items: items))   // back on the main actor
    }
}
```

> Warning: Write `nonisolated` explicitly. A plain `async func` is nonisolated only while your app target leaves `defaultIsolation` alone. Set `defaultIsolation(MainActor.self)` — ordinary for a Swift 6.2 target — and the same function runs entirely on the main actor, offloading nothing, with no error and no warning.

## What stays out

The Environment is not `Sendable` and never crosses an isolation boundary. Do not capture it, a Container, or a Value that is not `Sendable` in the offloaded function. Pass data in, get data out, and write the result through an Operation once you are back.

An actor of your own, a `nonisolated` escape from an Environment type, and `Task.detached` are all out for the same reason: each one leaks state into work the Environment does not own, which puts a change outside the one-way path through Operations.

An ``AsyncStrategy`` follows the same rule. Its kicks are synchronous and return immediately, so off-main work goes through `perform` with an ``AsyncOperation``, not a bare `Task`.
