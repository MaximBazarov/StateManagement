# Contributing

Thank you for helping. StateManagement is a foundational library, so the bar is high and the goal is to keep it small. The most useful contributions often remove or simplify, not add. This guide shows how to work with that.

## Before you start

Read [PHILOSOPHY.md](PHILOSOPHY.md) first. Every change is judged against its four pillars: simplicity, composition, low overhead, and single source of truth. If a change adds to the API, it has to earn its place.

The library is pre-1.0. The public API is still in discussion and can change between versions. Expect that.

## When you need an ADR first

A change that touches the public API or the scope needs an ADR before the code. Open an issue with a proposal. Discuss it on this repo. After the issue is accepted, the library developer writes the ADR in [`docs/adr/`](docs/adr/). Then code.

The review decides the shape before the code exists. That saves you from building something we then turn down on a pillar.

Small changes do not need an ADR. Bug fixes, tests, doc comments, and typo fixes can go straight to a pull request.

## Build and test

You need Swift 6.2 or later, and Xcode (not Command Line Tools alone).

- Build: `swift build`
- Test (macOS / host): `swift test`
- Test (iOS Simulator): `xcodebuild test -scheme StateManagement-Package -destination 'platform=iOS Simulator,name=iPhone 17'`

CI runs the suite on a macOS **and** an iOS Simulator on every pull request (matrix in `.github/workflows/ci.yml`), so run both locally before opening one. The iOS leg mainly catches platform-only API leaks early. Cycle-guard trap tests use Swift Testing exit tests (a subprocess); that API is unavailable on iOS, so those three compile out there and the rest of the target still runs.

Most tests are headless: they drive `ValueObserver` directly through `ValueObserverProbe`, so they run anywhere `swift test` runs and carry the behavioural coverage. One test (`watchSwiftUIIntegration`) mounts a real SwiftUI host — `NSHostingController` on macOS, `UIHostingController` on iOS — to prove the `@Watch` wiring. It needs a host, so it compiles out where neither AppKit nor UIKit exists. It is deterministic via `waitUntil` (polls for the re-render, no sleeps); a timeout there means the `@Watch` wiring genuinely failed to re-render, not flake.

Swift Package Index only *builds* the package (for the compatibility matrix) and generates DocC docs — it does not run tests. Keep everything compiling on every declared platform; test execution stays in CI.

## Project layout

- `CONTEXT.md` the glossary. Use those names; a word under `_Avoid_` is one we do not use for that concept.
- `Sources/` the library.
- `Tests/` the tests.
- `TestingSupport/` helpers we ship so users can test their own code against the library.
- `docs/adr/` accepted contributor decisions. A README until a proposal is accepted.

## Code style

- Document every public symbol with a `///` doc comment. These show up in Xcode while people write code, so they are part of the API, not an extra. If a symbol is hard to describe in one simple sentence, that is a sign to redesign it, not to write a longer comment.
- Match the style of the code around you.
- Keep prose simple and short: simple words, short sentences, the main point first.
- Start every new source file with the standard header:

```swift
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
```

- When linking an overloaded symbol, carry the full signature (``onRead(_:policy:current:)``). When two overloads differ only by type — DocC gives a readable disambiguator (``write(_:value:)-(_,Value)``) — use it. When overloads differ only by an `async`/`throws` effect (same erased parameter types), DocC's only disambiguator is an opaque hash (`-710qe`) — don't embed one; drop to a plain unlinked ``name`` instead. A hash breaks silently the next time the declaration changes and DocC recomputes it.

## Pull requests

- Branch off `main`.
- Keep each pull request small and about one thing. Small is easier to review and to reason about, and it lands faster.
- Link the issue. Link the ADR once the library developer has written it.
- Make sure the build and tests pass.
- In the description, say why, not just what.

## Reporting bugs and ideas

Open an issue. For a bug, include the smallest code that shows it, what you expected, and what happened instead. For an idea, expect the three pillars: say what it buys the user, and why composing the parts we already have is not enough.

## Be kind

Be respectful and assume good intent. We are all here to make a small, sharp library.
