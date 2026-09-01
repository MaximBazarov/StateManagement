# ``StateManagement``

Shared application state for Swift and SwiftUI. One Environment owns all State.

Design Containers and Values. Read them. Change them only through an Operation. Give a view an Environment with `sharedEnvironment(_:)`.

## Topics

### Containers and Values

- ``StateContainer``

### Environment

- ``SharedEnvironment``

### Reading

- <doc:Observing-State>
- ``Watch``
- ``EnvironmentService/read(_:)-(KeyPath<Storage,Value>)``
- ``EnvironmentService/read(_:key:)->Value?``

### Concurrency

- <doc:Concurrency-and-Offloading>

### Changing

- ``SyncOperation``
- ``SyncOperationEnvironment``
- ``Perform``
- ``InlineValueMutation``

### Operations in full

- ``ThrowingSyncOperation``
- ``AsyncOperation``
- ``ThrowingAsyncOperation``
- ``AsyncOperationEnvironment``
- ``ReentrancyDecision``
- ``ReentrancyIdentity``
- ``SyncOperationEnvironment/reset()``
- ``SyncOperationEnvironment/reset(_:)``

### Computed

- ``Computed``
- ``ComputationEnvironment``
- ``NoKey``

### Service

- ``EnvironmentService``
- ``SharedEnvironment/getService(_:)``
- ``SharedEnvironment/spawnService(_:)``

### AsyncStrategy

An AsyncStrategy owns read, write, and external side effects for `@AsyncState`. Strategy kicks, inbound verbs, and `preheat` take the `$` Address. Watch and Operations keep the Value Address. A dictionary Value is the Keyed case, one Address per entry. Policy on ``AsyncState`` is how that Address is backed; it is not a second Address.

- ``AsyncState``
- ``AsyncStrategy``
- ``AsyncStateStatus``
- ``AsyncStrategyEnvironment``
- ``SharedEnvironment/preheat(_:)``
- ``SharedEnvironment/preheat(_:keys:)``

### Combine

- <doc:Leftover-Combine>
- ``SMPublished``

### Previews

- ``SharedEnvironment/seeded(_:)``
- ``SharedEnvironment/seed(_:)``
- ``Write``
- ``SeedOperationsBuilder``

### Telemetry

- ``TraceContext``
- ``TelemetryEvent``
- ``TelemetryKind``
- ``Span``
- ``SpanID``
- ``TraceID``
- ``OSLogTelemetryLogger``
