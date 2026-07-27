#!/bin/sh
set -eu

if rg -n '(^|[^A-Za-z])(Process|NSTask)[[:space:]]*\(' Sources; then
  echo "production targets must not launch subprocesses" >&2
  exit 1
fi

if rg -n '^(import|@_exported import)[[:space:]]+(Flow|Mirage|Echo|AppKit|SwiftUI)$' Sources; then
  echo "production target boundary violation" >&2
  exit 1
fi

if rg -n '\.package[[:space:]]*\(' Package.swift; then
  echo "third-party package dependencies require explicit approval" >&2
  exit 1
fi
