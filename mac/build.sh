#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O main.swift calendar.swift -o onair \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
echo "built $(pwd)/onair"
