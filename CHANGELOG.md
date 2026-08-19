# Changelog

All notable changes to StateManagement are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Pre-1.0, expect breaking changes between minor versions.

## [0.9.0] - 2026-08-19

First tagged pre-release. Experimental: the public API may still break before `1.0.0`. In-repo DocC only, no Swift Package Index docs until `1.0.0`.

This record is the whole library. One Environment owns all State, sliced into Containers; every Value has an Address. An Operation is the only change, and an async Operation declares its `reentrancy` (ADR 0002). Computed derives Values from other Values. Watch reads from SwiftUI, Service reacts outside it, a Source produces inbound Values, and Combine and `@SMPublished` bridge legacy call sites. Telemetry is off by default and compiles away unless the `Telemetry` or `TelemetryInternal` trait is on (ADR 0012). In-repo DocC catalogs for `StateManagement` and `StateManagementTestingSupport` walk the public API.
