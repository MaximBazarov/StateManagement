# StateManagement

Shared application state for Swift. One Environment owns all State. State is sliced into Containers. Each addressable fact is a Value. An Operation is the only change.

This is the vocabulary of the package: the names to use in code, in docs, and in discussion. A word under `_Avoid_` is one we do not use for that concept.

## Language

### The approach

**Structured State Management**:
A way of building Swift applications: one Environment owns all State, change flows one way through Operations only, and every read is a declared dependency. StateManagement is its core, the package that enables it; a Satellite adds what the core refuses.
_Avoid_: abbreviating the name, using the name for this package alone, and structured concurrency (when you mean this)

### Ownership

**Environment**:
One isolated owner of all state. Production, a preview, and a test each have their own.
_Avoid_: store, warehouse, DI container, shared environment (as a second concept)

**Restricted Environment**:
The narrowed surface onto the Environment that non-view code holds: one each for a Sync operation, an Async operation, a Computed, and an AsyncStrategy, plus the base a Service inherits. It carries the identity of the caller, so every read has a known reader.
_Avoid_: proxy environment, child environment, sub-environment, using this for Watch, and treating every read through it as a subscription

**Container**:
A named slice of application state. An Environment owns exactly one instance of each type. Containers do not nest. Types may nest inside a Value.
_Avoid_: storage, warehouse, module, store, nested store, sub-container, child environment

**State**:
Everything one Environment owns.
_Avoid_: using this word for a single field or for a Container

**Seed**:
Starting Values placed into an Environment for a preview or a test. Not a production change.
_Avoid_: fixture, stub state, setup (when you mean this), Write (as a second noun)

### Values

**Value**:
One addressable fact inside a Container, named by an Address.
_Avoid_: property, field, state (when you mean one fact)

**Address**:
The name of a Value. Always into one Container. For an Atomic value, a key path. For a Keyed value, a key path plus a key.
_Avoid_: ValueID, and calling the key path alone the Address of a Keyed value

**`$` Address**:
The name of the AsyncStrategy seam for a Value declared with `@AsyncState`: the path to the `AsyncState` wrapper rather than to the Value, plus a key when Keyed. Kicks, inbound verbs, and the awaitable read take it. Watch and Operations take the Address.
_Avoid_: calling it a Value or a fourth shape, and using the Address on the strategy seam

**Atomic value**:
A Value that is the whole fact at one name in a Container.
_Avoid_: dictionary state

**Keyed value**:
A Value that is one entry in a dictionary inside a Container.
_Avoid_: collection observation, item state, dictionary state

**Computed**:
A Value derived from other Values. It is not stored State.
_Avoid_: derived state, selector, reducer

### AsyncStrategy

**AsyncStrategy**:
Owns read, write, and external side effects for Addresses declared with `@AsyncState`. The Environment owns one instance per type and always holds the Value. `onRead`, `onWrite`, and `onDrop` take the `$` Address and a Policy value.
_Avoid_: Source, ExternalSource, Bridge, inbound Service, using Service for this, one instance per Address, persist Service as the write path

**Policy**:
The way an Address is backed: a type declared on the AsyncStrategy that selects that strategy, and a per-Address value stored on `@AsyncState` and passed to `onRead`, `onWrite`, and `onDrop`.
_Avoid_: Bind, Binding, Parameters (when you mean this), using Policy as a second Address, Source update (when you mean this)

**Source status**:
Whether an Address backed by an AsyncStrategy holds an accepted Value. `$property.status`: pending (seed only), settled (applied or written), error (last `fail`). Not an Operation.
_Avoid_: wrapping the sourced Value in a status enum, fetchStatus, revalidation flag, AsyncStatus, `.value` (when you mean settled), treating `$property` as a Value, persist-out or Execution as this status

**Stale**:
A dirty mark on an Address backed by an AsyncStrategy. No Value write. The next read calls `onRead`.
_Avoid_: clear (when you mean this), reset, unbind, Source update, invalidate (when you mean this mark), Refresh (when you mean the mark and not the verb)

### Change

**Operation**:
The only way to change State. An Operation may also run work that writes no Values.
_Avoid_: action, mutation, effect, reducer, command, Perform (as a second noun), treating every Environment action as an Operation

**Observation round**:
The one notification every reader of a changed Value gets when the outermost Sync Operation unwinds. A nested Sync Operation, and strategy inbound on the same stack, join the round in flight rather than opening their own.
_Avoid_: transaction, batch, flush per perform, and treating nesting as observable

**Sync operation**:
An Operation that runs synchronously. It may write Values.
_Avoid_: requiring a Value write

**Async operation**:
An Operation that does async work and changes State only by performing a Sync operation.

**Execution**:
One in-flight performance of an async Operation, owned by the Environment.
_Avoid_: Run (when you mean this), Task (when you mean this), job, request

**AsyncOperation Identity**:
The grouping key for Executions of one async Operation type: a value key, or the whole Operation. At most one non-cancelled Execution per AsyncOperation Identity.
_Avoid_: Identity (unqualified), hash, predicate, and calling an Address an AsyncOperation Identity

**Join**:
An awaiter on an Execution that this caller did not start, same Operation type and AsyncOperation Identity.
_Avoid_: dropped awaiter, coalesce (as a second noun)

**Detach**:
Cancelling an awaiter does not cancel the Execution.
_Avoid_: shared cancellation, treating caller cancel as Execution cancel

**Cancel**:
A signal that an Execution should stop. It does not undo a committed Sync child.
_Avoid_: treating this as the Task stopping

**Reset**:
A Sync Operation verb that drops Containers from a long-lived Environment. `reset()` drops every Container, Service, and AsyncStrategy. `reset(_:)` drops one Container type.
_Avoid_: restoreSeed, unbind, teardown, using this for per-key remove

**Refresh**:
A Sync Operation verb that marks an Address backed by an AsyncStrategy Stale and calls `onRead` again. Source status does not change until the strategy applies or fails. Called as `refresh()` on `@AsyncState` or on a `Watch` projection.
_Avoid_: reload, invalidate, markStale (as the app-facing verb), restoreSeed, reset, treating this as awaiting the reload (that is `read` of the `$` Address)

### Read

**Watch**:
A SwiftUI view's declared dependency on a Value.
_Avoid_: observer, subscriber, binding, UIKit Watch

**Service**:
Long-lived non-view logic that reacts to Values it read, and causes a change only by performing an Operation. Data flows out, never in.
_Avoid_: observer, subscriber, reactor, using Service for inbound or persist-out (that is an AsyncStrategy), and a Service that writes State directly

### Around the library

**Satellite**:
A package that adds a capability the core refuses — persistence, sync, HTTP, a platform store — by shipping the AsyncStrategy for its area, while the core owns the seam and always holds the Value. An app package that only declares Containers, Operations, and Views is not a Satellite.
_Avoid_: plugin, extension, using Satellite for an app feature module, and saying State lives behind an AsyncStrategy

### Telemetry

**Telemetry**:
Logs and traces for this library. Part of StateManagement, not a Satellite.
_Avoid_: treating this as a separate product
