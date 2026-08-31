# Observing State

A subscription is one-shot. You stay subscribed by reading again.

Reading a Value registers the reader as a receiver for that Value's Address. When an Operation changes the Value, the Environment notifies every receiver of that Address once and drops them as it notifies. A receiver that wants the next change has to read again.

Nothing in the library keeps a standing subscription, and the three readers each re-subscribe on their own:

- ``Watch`` re-reads in the view's `body`, so it re-subscribes on every render.
- ``EnvironmentService`` re-registers on its inputs after every ``EnvironmentService/serve()`` run.
- ``Computed`` re-registers its dependencies when it recomputes. A cache hit changes nothing, because the previous registration still stands.

Read once and hold the result and you get one update, not a stream. That is the same trap under three names: a value stashed in a `@State`, a Service that reads only in its setup, a `read` called from a view body.

``SharedEnvironment/read(_:)`` never subscribes at all. It snapshots.

## What this buys

A reader is only ever subscribed to what it just read. A view that stops reading a Value stops being notified about it, with no unsubscribe call and no stale receiver holding the Value alive. The dependency is whatever the last read said it was.
