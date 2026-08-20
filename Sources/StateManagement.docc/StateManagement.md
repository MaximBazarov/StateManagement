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

### Source

A Source produces inbound Values. Address names the Value. Policy on ``AsyncState`` is how that Address is sourced; it is not a second Address.

- ``AsyncState``
- ``Source``
- ``SourceStatus``
- ``SourceUpdate``
- ``SourceEnvironment``
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
