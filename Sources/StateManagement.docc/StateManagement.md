# ``StateManagement``

Shared application state for Swift and SwiftUI. One Environment owns all State.

Design Containers and Values. Read them. Change them only through an Operation. Give a view an Environment with `sharedEnvironment(_:)`.

## Topics

### Containers and Values

- ``StateContainer``

### Environment

- ``SharedEnvironment``

### Reading

- ``Watch``
- ``SharedEnvironment/read(_:)``
- ``SharedEnvironment/read(_:key:)``

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

An AsyncStrategy owns read, write, and external side effects for `@AsyncState`. Strategy kicks and inbound verbs take the `$` Address. Watch and Operations keep the Value Address. Policy on ``AsyncState`` is how that Address is backed; it is not a second Address.

- ``AsyncState``
- ``AsyncStrategy``
- ``SourceStatus``
- ``AsyncStrategyEnvironment``
- ``SharedEnvironment/preheat(_:)``
- ``SharedEnvironment/preheat(_:key:)``

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
