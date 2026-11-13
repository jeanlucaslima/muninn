#!/bin/sh
# Builds and tests with the module dependency rules enforced (design §4.1):
# a target may import only what Package.swift declares as its dependencies.
# Uses its own build directory, so every file it compiles is checked.
set -eu
cd "$(dirname "$0")/.."
swift build --build-tests --scratch-path .build/check --explicit-target-dependency-import-check error
swift test --skip-build --scratch-path .build/check
