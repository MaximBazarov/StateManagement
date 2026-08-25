# StateManagement

Experimental. v0.9.2. The public API will break until 1.0.0.

StateManagement is a state library for Swift and SwiftUI. One Environment owns all State. State is sliced into Containers. You read a Value with `@Watch`. You change it only through an Operation. Observation is per Value, and per key in a dictionary. The Environment is not SwiftUI’s `@Environment`. It resolves Containers for you, in views and outside them, with no DI container.

```swift
import SwiftUI
import StateManagement

final class CounterContainer: StateContainer {
    var count: Int = 0
}

struct Increment: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        let count = env.read(keyPath: \CounterContainer.count)
        env.write(count + 1, keyPath: \CounterContainer.count)
    }
}

struct CounterView: View {
    @Watch(\CounterContainer.count) var count: Int
    @Perform var perform

    var body: some View {
        Button("\(count)") { perform(Increment()) }
    }
}

CounterView()
    .sharedEnvironment(SharedEnvironment())
```

A `Computed` derives a Value, a Service reacts, and persistence and HTTP live in a Satellite behind an AsyncStrategy.

Replace `@Published` with `@SMPublished` to keep leftover Combine call sites while the Environment owns the Value.

```swift
import Combine
import StateManagement

final class SettingsController: StateContainer, ObservableObject {
    @SMPublished var theme = "system"
}

let leftover = SettingsController()
leftover.theme = "dark"              // always SharedEnvironment.shared
leftover.$theme.sink { print($0) }   // Publisher<Value, Never>, not Published.Publisher
```

`@Watch` and Operations use the Environment they were given. Leftover Combine cannot. Tests that go through `instance.theme` use `.shared` plus `reset()`. `$` does not support `assign(to:)`.

## If you know TCA or Redux

- Isolated Operations, not one reducer tree.
- Flat Containers, not nested feature state.
- `async`/`await` in an Async operation, not an effect layer.
- `@Watch` / `@Perform`, not a ViewStore.

Tests perform Operations on a fresh Environment; link `StateManagementTestingSupport` from the test target.

## Requirements

- Swift 6.2+
- macOS 12+, iOS 17+

## Installation

Add the package with Swift Package Manager, then depend on the products you need:

- `StateManagement`: the library.
- `StateManagementTestingSupport`: testing helpers. Test target only.

```swift
.target(name: "MyFeature", dependencies: ["StateManagement"]),
.testTarget(name: "MyFeatureTests", dependencies: ["MyFeature", "StateManagementTestingSupport"]),
```

See [PHILOSOPHY.md](PHILOSOPHY.md) for what it will and will not do, and [CONTRIBUTING.md](CONTRIBUTING.md) to work on it.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
