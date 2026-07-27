#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
export LC_ALL=C

if grep -ERn --include='*.swift' \
    '(^|[^A-Za-z])(Process|NSTask)[[:space:]]*\(' Sources
then
    echo "production targets must not launch subprocesses" >&2
    exit 1
fi

if grep -ERn --include='*.swift' \
    '^(import|@_exported import)[[:space:]]+(Flow|Mirage|Echo|AppKit|SwiftUI)$' \
    Sources
then
    echo "production target boundary violation" >&2
    exit 1
fi

if grep -En '\.package[[:space:]]*\(' Package.swift
then
    echo "third-party package dependencies require explicit approval" >&2
    exit 1
fi

c_family_sources=$(
    find Sources -type f \
        \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' \
        -o -name '*.m' -o -name '*.mm' -o -name 'module.modulemap' \) \
        -print
)
if [ -n "$c_family_sources" ]
then
    echo "$c_family_sources" >&2
    echo "Treeish production targets must contain Swift source only" >&2
    exit 1
fi
