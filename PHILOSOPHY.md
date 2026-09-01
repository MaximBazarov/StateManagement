# Philosophy

StateManagement is a foundational library: other code is built on top of it. This document keeps it small, simple, and cheap to depend on. It says what the library values, what it will not do, and the bar every addition must pass. When in doubt, this document wins.

## The four pillars

### 1. Simplicity is king

The API must be as simple as possible to write, read, and test. Complexity is a defect, not a feature. When something gets complex, we do not document it and move on. We break it down and find the right shape. If we cannot make it simple, we are not done designing it.

The same rule applies to the docs. They must be simple to read: plain words, short sentences, the main point first. If a thing needs many words to explain, that is a sign the thing is too complex, not that the docs need to be longer.

### 2. Composable, modular, atomic

The library gives you small parts, not finished solutions. Each part is independent and combines freely with the others. We give you the tools to compose, we do not force one way to do it. You decide how the parts fit your app, so the library bends to your design instead of bending your design to it. If something can be built by combining the parts we already have, it stays out of the core. It belongs in your code or in a separate package on top.

### 3. Efficient, with little overhead

Everything else depends on this library, so its cost matters. We check every part for the cost it adds: at run time, at compile time, and in how much you have to keep in your head. The goal is to add as little as possible, so the library scales from one view to a large app without becoming the slow part. We decide the cost up front, not after the fact.

### 4. Single source of truth

Every piece of state lives in exactly one place. There is one owner and one value to read. No copies that drift, no second store holding the same fact. Many operations may change it, but they all change the one source, not their own copy. The same rule binds the design itself: each type, method, and parameter has one clear job and one meaning. If you cannot tell what something does or where a value comes from, that is a defect, not a detail to leave to the reader.

Docs hold the same line. Every name and every sentence must have one reading. Ambiguity is not allowed. If a thing can be read two ways, we rename it or rewrite it until it reads one way.

## The bar for adding anything

Every addition, whether a type, a method, a parameter, or a protocol requirement, must pass all four gates first:

1. **Simplicity.** Does it keep the API simple to write, read, and test? If it adds complexity, can we break that complexity down first?
2. **Composition.** Can you already do this by combining parts we have? If yes, it stays out of the core by default.
3. **Overhead.** What does it cost at run time, at compile time, and in your head? Is that cost worth it for a library everything depends on?
4. **Single source of truth.** Is there one owner and one value to read, with no drifting copies? Does the name and behavior have exactly one meaning, or can it be read two ways?

A fail on any one gate means no. We record the no as a Non-Goal below, so we do not argue the same point twice, and the scope stays clear over time.

## Non-Goals

These are out of scope on purpose. They are useful. They just do not belong inside a foundational state core. Each one builds on top of the library instead. Networking and persistence build as a [Satellite](CONTEXT.md).

- **Networking and HTTP.** State can come from a network layer. The library does not provide one.
- **Persistence and databases.** Saving and loading state happens outside the library.
- **A dependency injection container.** The library aims to make dependency injection unnecessary, not to provide it. The environment resolves state containers when you need them, so there is nothing to wire up and inject. We are not building a general DI framework, and we will not grow into one.
- **Machinery to work around our own constraints.** Operations are plain Swift with structured concurrency and normal control flow. We do not add a rule and then build a separate layer to win back what the rule took away. If a rule leaves a real gap, we drop the rule instead of building around it.
- **Feature bundles.** Anything you can build by combining the parts we have is left to you or to a separate package.
- **Convenience that hides cost.** No API whose overhead we have not measured, or whose behavior is hard to reason about, even if it saves a few keystrokes.

This list will grow as we turn proposals down. Adding to it is a good sign, not a failure.

## Decisions

The pillars are the values. The concrete choices that follow from them live as ADRs in `docs/adr/` so the scope stays predictable. That folder is an accepted log: a proposal we turn down gets no ADR, it becomes a Non-Goal above that names the pillar it failed.

ADRs are for the people building the library, not its users. They sit apart from the user docs (DocC). DocC shows you how to use the library. This charter and the ADRs explain why it has the shape it has, and what it will not become.
