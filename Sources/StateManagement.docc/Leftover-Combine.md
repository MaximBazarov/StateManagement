# Leftover Combine

Replace `@Published` with ``SMPublished``. The class is a ``StateContainer`` and `ObservableObject`. The Environment owns the Value. Combine call sites stay `instance.thisValue` and `$thisValue`.

```swift
import Combine
import StateManagement

final class SettingsController: StateContainer, ObservableObject {
    @SMPublished var theme = "system"
    @SMPublished var flags: [String: Bool] = [:]
    var windowTitle = ""
}
```

A plain `var` on the same class stays per-instance. Only `@SMPublished` is Environment state. The class must use the default `ObservableObjectPublisher`.

## Two paths

Leftover `instance.theme` and `$theme` always use ``SharedEnvironment/shared``. ``Watch``, ``Computed``, Operations, and Services use the Environment they were given. Overriding the Environment for leftover Combine is unsupported.

```swift
let leftover = SettingsController()
leftover.theme = "dark"                 // writes .shared
leftover.$theme.sink { print($0) }      // follows Operations on .shared

struct SetTheme: SyncOperation {
    func perform(in env: SyncOperationEnvironment) {
        env.write("light", keyPath: \SettingsController.theme)
    }
}
```

`@Watch(\SettingsController.theme)` uses the view’s Environment. A test `SharedEnvironment()` stays isolated from leftover Combine.

Tests that go through leftover Combine use `.shared` plus `reset()`. Tests that Watch or perform Operations use a fresh Environment.

``SharedEnvironment/read(_:)`` still snapshots. It does not subscribe.

## `$` and `objectWillChange`

`$theme` is `Publisher<Value, Never>`, not `Published.Publisher`. `assign(to: &$theme)` is out.

Leftover `$` follows Operations on `.shared`. `objectWillChange` fires on leftover set and when leftover `$` follows those Operations.

Keyed leftover `$flags` is the whole dictionary. A leftover whole-dict write updates per-key Watchers for keys that changed. A keyed Operation also updates `$flags`.
