# StateManagement

StateManagement is a state tool for Swift and SwiftUI. You declare state in plain classes, read it from views with `@Watch`, and change it only through operations. Observation is tracked per value, and per dictionary key, so changing one item redraws only the views that read it, and nothing else.

It builds on the paradigms that already won. State is **declarative**, the same way SwiftUI is: a view declares which values it depends on, and the framework keeps it in sync. You never push updates by hand. And it is **simple on purpose**: plain types, one way to change state, nothing to register or wire up. No new mental model to adopt. Just the ones you already trust, made precise.

It is a foundational library: small, composable, and cheap to depend on. Reads and writes measure about 200 to 300 ns, even with 100,000 objects in the environment. That is on par with touching a plain property. See [PHILOSOPHY.md](PHILOSOPHY.md) for what it will and will not do.

## Principles

Three principles decide everything in this library. They run from the public API down to the engine.

- **Simplicity is king.** The API must be simple to write, read, and test. Complexity is a defect, not a feature. State is a plain class, a change is a plain struct, a view reads a value with one property wrapper. There is nothing to register, inject, or unsubscribe.
- **Composable, modular, atomic.** The library gives you small parts, not a finished framework. Containers stay flat and independent, operations are isolated structs, and views compose by watching different values side by side. You decide how the parts fit your app.
- **Efficient, with little overhead.** Everything depends on this library, so its cost matters. Observation is per value and per key, notifications are batched into one pass per operation, derived values are diffed, and tracing compiles away when off.

## Highlights

The three principles, made concrete.

**Declarative and simple**

- **Declarative reads.** A view declares the value it depends on with `@Watch`, and the framework keeps it in sync. You never push updates.
- **Precise, self-adjusting dependencies.** `@Watch` tracks exactly what the body read, the same way SwiftUI's own `@Observable` does, so there is no new model to learn. Skip a branch and you do not depend on its values, changing them redraws nothing. When a value you did read changes, the body re-runs and the dependency set re-forms itself, so a branch that now reads different state subscribes to exactly that. Fine-grained and automatic.
- **Plain Swift operations.** Sync writes are synchronous. Async work uses structured concurrency. No effect layer, no cancellation system to learn.
- **Self-managing subscriptions.** Subscriptions are one-shot and re-made on read, so the registry only ever holds the watchers currently on screen. Nothing to unsubscribe, nothing to leak.

**Composable and modular**

- **No dependency injection.** Code reaches state through the environment, which resolves containers for you. Production needs no wiring. Previews and tests inject a temporary environment in one line.
- **Works outside views.** Unlike SwiftUI's `@Environment`, the environment is not tied to the view tree. Operations, services, network layers, and reusable packages all use it directly.
- **Logic in its own package.** State, operations, and computed values import only `StateManagement`, not SwiftUI. Lift them into a reusable package and test them with no UI.
- **Flat, independent state.** Containers live flat in the environment, and a change is an isolated struct. Add a feature by adding a file, not by editing a reducer tree.
- **Compose by watching.** Views read from several containers side by side, and operations write to several in one pass.

**Efficient, with little overhead**

- **Per-value, per-key observation.** A view that watches one dictionary key is notified only when *that* key changes. No collection wrappers, no list diffing.
- **One write pass, one notification.** An operation can change fifty values, and watchers are notified once, after it finishes, never mid-flight.
- **Output diffing for derived state.** A `Computed` value that ends up unchanged suppresses the redraw, even if its inputs changed.
- **Built-in tracing and a transaction log, zero cost when off.** Every operation is a span that records what it changed, to what value, and from where, with trace IDs that follow work across `await`. Read it as a transaction log when chasing a bug, or profile in Instruments through `os_signpost`. Compiled away when disabled.
- **MainActor by design.** Everything runs on the main actor, so there are no locks and no data races to reason about.

## Requirements

- Swift 6.2+
- macOS 12+, iOS 17+

## Installation

Add the package with Swift Package Manager:

```swift
.package(url: "https://github.com/<owner>/StateManagement.git", from: "0.1.0")
```

Then depend on the products you need:

- `StateManagement`: the library.
- `StateManagementTestingSupport`: testing helpers. Link it from your test target only.

```swift
.target(name: "MyFeature", dependencies: ["StateManagement"]),
.testTarget(name: "MyFeatureTests", dependencies: ["MyFeature", "StateManagementTestingSupport"]),
```

## Core concepts

The data flow is one-way. Four parts cover most apps:

1. **`StateContainer`**: a class that holds state, as atomic values or as keyed dictionaries.
2. **`SyncOperation`**: the only way to change state. Reads and writes run synchronously inside a safe environment.
3. **`AsyncOperation`**: runs async work (`Task`, `await`) and applies changes by performing sync operations.
4. **`@Watch` / `@Perform`**: SwiftUI property wrappers to read one value and to dispatch operations.

Two more parts cover the rest:

- **`Computed`**: a value derived from other state, cached and invalidated automatically — recomputed only when an input it read changes.
- **`EnvironmentService`**: long-lived logic that reacts to state changes, like a database layer, a network layer, or a sync engine.

Containers are created lazily on first access and cached in the environment. There is nothing to register and nothing to wire up. When you read `\TodoContainer.todo`, the environment makes the `TodoContainer` for you.

## No dependency injection

State is reached through the environment, and the environment resolves containers on demand. So in production code you inject nothing: a view watches `\TodoContainer.todo`, an operation reads and writes it, and the right container is there. There are no initializers to thread dependencies through and no container to configure. A DI framework is an explicit [non-goal](PHILOSOPHY.md): the aim is to make injection unnecessary, not to provide it.

Two things make this practical:

- **It is the same everywhere, with a default.** A process-wide `SharedEnvironment.shared` backs everything by default, so unconfigured code just works. Need a different one? Set it. For a view subtree use `.sharedEnvironment(_:)`. For other code, hold the instance you `perform` on.
- **It is not tied to views.** SwiftUI's `@Environment` only resolves inside a `View`. Here the environment is a plain object that operations, services, network layers, and other packages use directly. It is the same state, reachable from anywhere in the app, no view in sight.

That makes previews and tests a one-liner: build a fresh `SharedEnvironment`, seed it, and hand it over. Nothing in the production types changes.

DEBUG builds can use the seed builder (`Write`, any `SyncOperation`, one notify):

```swift
#Preview {
    TodoListView()
        .seedEnvironment {
            Write(\TodoContainer.title, "Buy milk")
            AddTodo(title: "Buy milk", details: "")
        }
}
```

Headless tests use the same builder:

```swift
let env = SharedEnvironment.seeded {
    Write(\TodoContainer.title, "Buy milk")
}
```

Release-safe pattern (works in every build): create the env, `perform` a named op, inject:

```swift
#Preview {
    let env = SharedEnvironment()
    env.perform(AddTodo(title: "Buy milk", details: ""))
    return TodoListView()
        .sharedEnvironment(env)
}
```

Tests do the same without any view. See [Testing](#testing).

## Split logic from UI

Put all your state, operations, and computed values in a plain Swift package, and keep the app as a thin UI shell that owns no state. This works because the logic never imports SwiftUI. Only `@Watch` and `@Perform` do, and those live in views.

Why this is worth doing:

- The logic package tests in milliseconds, with no view to host and nothing to mock.
- The same package feeds a macOS app today and an iOS or watchOS app later, with no change.
- The app layer stays small: views and layout, nothing else.

The `SSMTodoList` example is built this way. `TodoKit` is a standalone package that holds every container, operation, value type, and computed property, and imports only `StateManagement`. `SSMTodoList` is the SwiftUI app on top: it reads with `@Watch`, dispatches with `@Perform`, and owns zero business logic.

## Ownership and access control

State ownership is just Swift's access control. A container is a class in a module, so the same `internal`, `public`, and `private(set)` you already use decide who can touch its state. There is no separate permission system to learn, and the compiler enforces it.

This works because reads and writes need different key paths. `read` takes a `KeyPath`, while `write` and `remove` take a `WritableKeyPath`. So hiding a setter does not just discourage outside writes, it makes them fail to compile.

Say a `Payments` module owns the balance:

```swift
import StateManagement

public final class PaymentsContainer: StateContainer {
    // Read by anyone, written only inside Payments.
    public internal(set) var balance: Decimal = 0
}
```

What each level gives you, for free:

- **`var balance` (internal, the default):** only code in `Payments` can read or write it. Outside the module the key path `\PaymentsContainer.balance` does not exist, so there is nothing to police.
- **`public internal(set) var balance`:** any module can read and `@Watch` the balance, but only `Payments` can write it. An outside `write` cannot form the `WritableKeyPath`, so it fails at compile time, not at run time.
- **`public var balance`:** fully open, your call.

The effect is that writes funnel through the operations a team chooses to expose. If the setter is not public, the only way another module changes the balance is by performing a public operation like `Deposit`, which `Payments` owns and controls. Ownership is as granular as Swift itself: per property, per type, per module, per package.

### Operations as enforced gates

Because the setter is hidden and writes go through an operation, that operation becomes a gate the rest of the app cannot get around. Encapsulation here enforces invariants and policy, it does not just hide state. Put the rule in the one operation that owns the write:

```swift
public struct AdjustBalance: SyncOperation {
    let amount: Decimal
    public func perform(in env: SyncOperationEnvironment) {
        guard env.read(keyPath: \Session.isAdmin) else { return }   // the gate
        let current = env.read(keyPath: \PaymentsContainer.balance)
        env.write(current + amount, keyPath: \PaymentsContainer.balance)
    }
}
```

No other module can form the `WritableKeyPath` for `balance`, so `AdjustBalance` is the only way to change it. The admin check cannot be bypassed, and a new feature cannot forget it, because there is no other write path to forget it on. Code that needs to move the balance performs `AdjustBalance` and composes it, rather than re-deriving the rule. So you get a guaranteed enforcement point with no interceptor layer and no coupling: the rule lives with the state it guards, owned by the module that owns the concern.

One limit today: the gate can enforce but not report. The `else { return }` applies no change and tells the caller nothing, so a denial is silent. Giving operations a failure channel, so the gate can `throw PaymentsError.notAuthorized` and the caller can handle it, is proposed in [ADR 0006](docs/adr/0006-Throwing-Operations.md).

One caveat: this is the boundary you build with modules, not one the library adds. Put everything in one app target with the default `internal` and it is all mutually visible inside that target. Split state into packages and each one owns its own, enforced by the compiler. See [Split logic from UI](#split-logic-from-ui).

## Usage

The examples use a small todo app.

### 1. Declare state in a container

Conform a class to `StateContainer`. It only needs a parameterless `init`. Keep values atomic, or key them inside a dictionary.

```swift
import StateManagement

final class TodoContainer: StateContainer {
    /// Each todo, keyed by id.
    var todo: [UUID: TodoItem] = [:]
}

final class CompletionContainer: StateContainer {
    /// Completion flag per todo id.
    var completion: [UUID: Bool] = [:]
}

final class ListContainer: StateContainer {
    /// Ordered list of todo ids.
    var index: [UUID] = []
}

struct TodoItem: Hashable, Identifiable {
    var id = UUID()
    var title: String
    var details: String = ""
}
```

### 2. Change state with a `SyncOperation`

Every write goes through an operation. The environment gives you `read`, `write`, and `remove`. A keyed write invalidates only that key, so only the views watching it redraw. All the writes below land as a single notification when the operation returns.

```swift
import StateManagement

struct AddTodo: SyncOperation {
    let title: String
    let details: String

    func perform(in env: SyncOperationEnvironment) {
        let item = TodoItem(title: title, details: details)

        // Keyed writes invalidate only their key.
        env.write(item, keyPath: \TodoContainer.todo, key: item.id)
        env.write(false, keyPath: \CompletionContainer.completion, key: item.id)

        // Atomic write to the ordered list.
        let list = env.read(keyPath: \ListContainer.index)
        env.write(list + [item.id], keyPath: \ListContainer.index)
    }
}

struct RemoveTodo: SyncOperation {
    let id: UUID

    func perform(in env: SyncOperationEnvironment) {
        // `remove` notifies per-key watchers. Prefer it over rewriting the dictionary.
        env.remove(keyPath: \TodoContainer.todo, key: id)
        env.remove(keyPath: \CompletionContainer.completion, key: id)

        let list = env.read(keyPath: \ListContainer.index)
        env.write(list.filter { $0 != id }, keyPath: \ListContainer.index)
    }
}
```

### 3. Run async work with an `AsyncOperation`

An `AsyncOperation` runs async code and reads state, but it does not write directly. It applies changes by performing sync operations, which keeps every mutation in one synchronous place. Use normal control flow: `guard`, `return`, task cancellation. There is no special effect type. When you need a long-lived helper (player, I/O), resolve it with `getService` and call methods on it; still mutate state only through sync ops.

```swift
import StateManagement

struct LoadTodos: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }

    func perform(in env: AsyncOperationEnvironment) async {
        let items = await TodoAPI.fetchAll()   // your own async call

        for item in items {
            // Mutate by performing a sync operation.
            env.perform(AddTodo(title: item.title, details: item.details))
        }
    }
}

struct PlayClip: AsyncOperation {
    var reentrancy: ReentrancyDecision { .runAll }

    func perform(in env: AsyncOperationEnvironment) async {
        let player = await env.getService(AudioPlayerService.self)
        await player.play(glyph: "あ")
    }
}
```

### 4. Read and dispatch in SwiftUI

Inject the environment with `.sharedEnvironment(_:)`. Use `@Watch` to read one value and `@Perform` to dispatch operations. `@Perform` can run sync operations, fire-and-forget async operations, or `await` an async operation.

```swift
import SwiftUI
import StateManagement

struct TaskRowView: View {
    let todoID: UUID

    // Keyed watch: redraws only when this todo changes.
    @Watch<TodoContainer, TodoItem?> var item: TodoItem?
    // Keyed watch: drives the checkbox.
    @Watch<CompletionContainer, Bool?> var isCompleted: Bool?

    @Perform private var perform

    init(todoID: UUID) {
        self.todoID = todoID
        self._item = Watch(\TodoContainer.todo, key: todoID)
        self._isCompleted = Watch(\CompletionContainer.completion, key: todoID)
    }

    var body: some View {
        if let item {
            HStack {
                Button {
                    perform(ToggleTodoCompletion(id: todoID))
                } label: {
                    Image(systemName: (isCompleted ?? false) ? "checkmark.circle" : "circle")
                }
                Text(item.title)
            }
        }
    }
}
```

Set the environment once, near the root:

```swift
ContentView()
    .sharedEnvironment(SharedEnvironment())
```

### 5. Two-way bindings

`@Watch` projects a `binding(mutation:)` helper. The closure runs like a tiny `SyncOperation`. Each binding edit is its own operation, so when several values must change together, write a named `SyncOperation` instead.

```swift
final class DraftContainer: StateContainer {
    var newTodoTitle: String = ""
}

struct NewTodoField: View {
    @Watch(\DraftContainer.newTodoTitle) var title: String

    var body: some View {
        TextField("New todo", text: $title.binding { newValue, env in
            env.write(newValue, keyPath: \DraftContainer.newTodoTitle)
        })
    }
}
```

### 6. Derive values with `Computed`

A `Computed` property reads other state, and its output is **cached**: it runs once and reuses the result until one of the inputs it read changes, then recomputes on the next read. It subscribes to exactly the values it touches, so it stays correct as those inputs change. If its output is unchanged, watchers are not redrawn. Watch it with `Watch(computed:)`. Caching makes an expensive pure function of state fine here; reach for an `EnvironmentService` only when you need disk, async, or a lifetime beyond the current state.

```swift
final class ListContainer: StateContainer {
    var index: [UUID] = []

    @Computed var count = { env in
        env.getValue(\ListContainer.index).count
    }
}

struct CountView: View {
    @Watch(computed: \ListContainer.$count) var count: Int
    var body: some View { Text("\(count) items") }
}
```

### 7. React to state with an `EnvironmentService`

A service is long-lived logic that runs when the state it reads changes, like a database writer, a network sync, or a cache. Subclass `EnvironmentService` and override `serve()`. Read with `getValue`, which subscribes you, and write with `setValue`. The environment ignores changes the service made itself, so it does not loop. A service re-subscribes itself after each run, so it keeps reacting to the latest state without re-reading. Runs are single-flight: one `serve()` at a time, and changes during a run coalesce into one follow-up that reads the latest.

```swift
import StateManagement

final class PersistenceService: EnvironmentService {
    override func serve() async {
        let todos = getValue(\TodoContainer.todo)   // subscribes to changes
        await Database.save(todos)
    }
}

// Start it once:
await environment.spawnService(PersistenceService.self)
```

## How it works under the hood

This is how the *efficient, with little overhead* principle is delivered without giving up the simple, declarative surface above. The whole engine rests on one idea: **every piece of state has a stable identity, and observation is tracked against that identity.**

### Value identity

Each value is addressed by a `ValueID`: its key path, plus an optional dictionary key. Identity is *value-based*, it hashes the `AnyKeyPath` rather than a reference, so `\TodoContainer.todo` means the same thing across modules, compiler contexts, and instances. That stability is what lets a subscription made in one place reliably match a change reported in another.

### Batched, targeted notification

Writes do not notify anyone right away. During an operation each write calls `invalidateValue`, which just collects the changed `ValueID`s. When the operation returns, the environment calls `notifyAll()` **once**: it looks up the receivers for each changed `ValueID`, an O(1) dictionary hit per id, and calls them with the full set of what changed. So an operation that touches one key wakes one watcher. An operation that touches fifty values still fires one combined pass. Watchers never see a half-applied state.

### One-shot subscriptions (the auto-subscription model)

Subscriptions are short-lived on purpose. When `notifyAll()` delivers a change, it **removes** the notified receivers from the registry in the same step. A `@Watch` re-subscribes automatically the next time SwiftUI evaluates its body and reads the value. This has three nice results:

- A view that did not change is never in the changed set, so it is never woken, and it stays subscribed.
- A view that did change is notified, dropped, and re-subscribes on its next read. Off-screen and discarded views simply stop re-subscribing and fall out of the registry.
- There is nothing to unsubscribe by hand and no observer lifecycle to manage. The set of live subscriptions is always exactly the set of views currently reading state.

### Output diffing for derived state

For a `Computed` value, the watcher does more than relay the change. It re-evaluates and compares the new output against the last one. If they are equal, the notification is **suppressed**, so there is no redraw, while the watcher quietly re-subscribes so it stays live. A computed that maps an input that changes often to a stable output, say "is the list empty", only redraws when the answer actually flips.

### Self-rebuilding dependency graph

A `Computed` value tracks its inputs by *reading* them. Each read through the computation environment registers the computed as dependent on that input. When an input is invalidated, the environment marks every computed that depends on it as changed too — and clears that computed's cached output. Because the graph is rebuilt on each recompute, a computed only ever depends on what it actually read this time; branches you did not take cost nothing. A cached read (no input changed since) reuses the output and the existing edges, so the cache is only ever valid when its dependency edges still hold.

### Services without feedback loops

An `EnvironmentService` reads with `getValue`, which subscribes it, and reacts in `serve()`. A service that writes a value it also reads would loop. To stop that, the environment records the IDs a service mutated and skips notifying the service about its own writes. A service re-subscribes itself after every run, so it stays live across updates. Runs are single-flight, finish-then-follow: one `serve()` at a time, changes during a run coalesce into one follow-up that reads the latest state, and a run always completes rather than being cancelled.

### Non-reentrant by construction

A change is one pass: `perform`, then `notifyAll`, then the callbacks, then done. The callbacks never re-enter that pass. A `@Watch` callback calls `objectWillChange`, which hands off to SwiftUI's next update, and a service callback spawns a `Task` that runs later. So `notifyAll` is never nested inside another `notifyAll`, no watcher ever sees a half-applied operation, and there are no recursive notification storms.

The only thing left to design around is a loop, not a reentrance. Because the sole way to change state is to dispatch an operation, a service that reacts by dispatching an operation that re-triggers it forms a cycle of separate passes. That is a logical concern, not a stack one, and the obvious case is already handled: a service ignores notifications for the values it wrote itself, so it cannot self-loop. A cycle that spans two services, or a service and an operation, is the one case to keep in mind.

### Built-in tracing

Every operation runs inside a telemetry span with a 128-bit trace ID and a span ID, carried across `await` through a `@TaskLocal` context. So an async operation and the sync operations it performs share one trace. Spans feed `os_signpost`, so you can profile operations directly in Instruments, and `OSLogTelemetryLogger.enable()` prints a readable span tree.

Telemetry is off by default and costs nothing when off: every call site compiles away (ADR 0012). Turn it on with a SwiftPM package trait. `Telemetry` covers user spans (operations), `TelemetryInternal` covers state mutation, which runs on every set.

```swift
.package(url: "...", traits: ["Telemetry"])
```

In Xcode 26.4 and later, toggle the trait in the Package Dependencies view. On older Xcode, proxy through a thin local wrapper `Package.swift` that enables the trait. To consume the stream, call `OSLogTelemetryLogger.enable()`.

Inside an operation, record a note against the current span with `TraceContext.log("checkpoint")`. It renders as a child line under that span. Outside a span it does nothing.

The trace carries identity and timing, never the value. A `Set` span names the key path only, so no state value leaks to any consumer. Read top to bottom, that span tree is a transaction log: each operation records what it changed, from where, and in what order, and an async operation shares one trace with the sync operations it performs:

```
AddTodo  [AddTaskBar.swift:63]
  - [\TodoContainer.todo: 57CC…] changed
  - [\CompletionContainer.completion: 57CC…] changed
  - \ListContainer.index changed
ToggleTodoCompletion  [TodoDetailView.swift:83]
  - [\CompletionContainer.completion: 57CC…] changed
```

When a bug appears, the last operations show exactly what mutated and in what order. The same per-operation record is what an assertable test transcript would expose, so a test can check the writes an operation made and their order, not just the final value.

### Main actor by design

State lives on the main actor, and that is a performance choice, not just a safety one. Your UI reads state on the main actor, and a SwiftUI view body cannot `await`. When the state is on the same actor, a read or write is a plain synchronous access: no actor hop, no suspension, no `Sendable` copy across a boundary. That is why a read or write stays in the 200 to 300 nanosecond range. Put the same state on a background actor and every UI read would pay a hop and a copy, which is slower for the path that runs most often.

This is also where Swift itself is heading. Swift 6.2 lets a whole target default to main-actor isolation (SE-0466, Approachable Concurrency), so single-actor app code is the recommended default and you reach for other actors only where you need them. StateManagement takes that default for state, and removes locks and data races as a result.

Heavy work still moves off the main actor when it should. An async `EnvironmentService` can `await` work on a background actor or a detached task, then apply the result through a sync operation. So the expensive part runs elsewhere, while the state and the final write stay on the main actor where the UI reads them.

## StateManagement vs. Redux and TCA

If you know Redux or The Composable Architecture (TCA), here is how this differs.

- **Isolated operations, not one giant reducer.** Each change is its own struct, like `AddTodo`. Adding a feature touches one file, so there are no reducer-switch merge conflicts.
- **Flat containers, not deep trees.** Nesting features in Redux or TCA means a parent declares child state, imports child modules, and routes child actions. Here containers stay flat and views compose by watching different keys.
- **Plain async, not an effect layer.** Pure reducers cannot run side effects, so those libraries add effect and cancellation systems. Here you write `async`/`await` directly in an `AsyncOperation`.
- **Direct dispatch, not action bubbling.** Operations run on the environment directly. There is no child-to-parent action forwarding to break.
- **Native SwiftUI, not ViewStore overlays.** `@Watch` and `@Perform` are plain property wrappers. There is no store wrapper or observer DSL.
- **O(1) keyed observation, not collection wrappers.** No `IdentifiedArray` needed. Observation is tracked per key, and unchanged derived values are diffed out.

## Testing

Operations and state are plain values, so tests are direct: build a `SharedEnvironment`, perform operations, and read back with `StateReader` from `StateManagementTestingSupport`. No view hosting, no mocks.

```swift
import Testing
import StateManagement
import StateManagementTestingSupport

@Suite
struct TodoTests {
    @Test @MainActor
    func addTodo_appendsToList() async {
        let environment = SharedEnvironment()
        let reader = await environment.spawnService(StateReader.self)

        environment.perform(AddTodo(title: "Buy milk", details: ""))

        #expect(reader.read(\ListContainer.index).count == 1)
    }
}
```

`StateReader` reads atomic values, keyed values, and computed values:

```swift
let title  = reader.read(\TodoContainer.todo, key: id)?.title
let count  = reader.read(computed: \ListContainer.$count)
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
