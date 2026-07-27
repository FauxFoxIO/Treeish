#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

Scripts/check-production-boundaries.sh
swift package dump-package >/dev/null

if [ ! -d Sources/Treeish/Treeish.docc ]
then
    echo "the Treeish DocC catalog must live inside the public target" >&2
    exit 1
fi
