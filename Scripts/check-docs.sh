#!/bin/bash
#===----------------------------------------------------------------------===#
#
# This source file is part of the StateManagement package open source project
#
# Copyright (c) 2025-2035 Maxim Bazarov and the StateManagement package
# open source project authors
# Licensed under MIT
#
# See LICENSE.txt for license information
#
# SPDX-License-Identifier: MIT
#
#===----------------------------------------------------------------------===#
#
# Guards the two facts README.md copies from somewhere else. Nothing in the
# build reads README.md, so both rot silently: the version line sat two
# releases behind, and the quick-start example kept a signature that had been
# gone since 0.9.3.
#
#   1. the version line     — owned by the newest released CHANGELOG heading
#   2. each Swift example   — owned by the compiled snippet in Snippets/
#
# A README block opts in with `<!-- snippet: Name -->` on the line above its
# fence; the snippet owning it is Snippets/Name.swift, between its
# `// README:begin` and `// README:end` markers.

set -euo pipefail

cd "$(dirname "$0")/.."

status=0
fail() {
    echo "::error::$*"
    status=1
}

# 1. Version -----------------------------------------------------------------

readme_version=$(sed -n 's/^Experimental\. v\([0-9][0-9A-Za-z.-]*\)\..*$/\1/p' README.md | head -1)
# `## [Unreleased]` carries no digit, so the digit class skips it.
changelog_version=$(sed -n 's/^## \[\([0-9][0-9A-Za-z.-]*\)\].*$/\1/p' CHANGELOG.md | head -1)

if [ -z "$readme_version" ]; then
    fail "README.md has no 'Experimental. v<x.y.z>.' line to check"
elif [ -z "$changelog_version" ]; then
    fail "CHANGELOG.md has no released '## [x.y.z]' heading to check against"
elif [ "$readme_version" != "$changelog_version" ]; then
    fail "README.md says v$readme_version, newest CHANGELOG.md release is $changelog_version"
else
    echo "version: README v$readme_version matches CHANGELOG $changelog_version"
fi

# 2. Examples ----------------------------------------------------------------

readme_block() {
    awk -v name="$1" '
        $0 == "<!-- snippet: " name " -->" { want = 1; next }
        want && $0 == "```swift" { inside = 1; want = 0; next }
        inside && $0 == "```" { exit }
        inside { print }
    ' README.md
}

snippet_block() {
    awk '
        $0 == "// README:begin" { inside = 1; next }
        $0 == "// README:end" { exit }
        inside { print }
    ' "$1"
}

referenced=""
while IFS= read -r name; do
    [ -n "$name" ] || continue
    referenced="$referenced $name"
    snippet="Snippets/$name.swift"
    if [ ! -f "$snippet" ]; then
        fail "README.md references snippet '$name', but $snippet does not exist"
        continue
    fi
    if ! diff -u --label "$snippet" --label "README.md ($name)" \
        <(snippet_block "$snippet") <(readme_block "$name"); then
        fail "README.md block '$name' has drifted from $snippet"
    else
        echo "example: README block '$name' matches $snippet"
    fi
done < <(sed -n 's/^<!-- snippet: \(.*\) -->$/\1/p' README.md)

# An unreferenced snippet compiles but guards nothing, which reads as coverage
# it does not have.
for snippet in Snippets/*.swift; do
    [ -e "$snippet" ] || continue
    name=$(basename "$snippet" .swift)
    case " $referenced " in
        *" $name "*) ;;
        *) fail "$snippet is not referenced by any '<!-- snippet: $name -->' in README.md" ;;
    esac
done

exit $status
