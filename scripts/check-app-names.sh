#!/bin/bash
# Checks Decide.appBundleID (how open_app's name becomes a bundle id) without building the app.
set -euo pipefail
cd "$(dirname "$0")/.."
F=$(mktemp -t apps).swift
{ echo 'import Foundation'
  sed -n '/static func appBundleID/,/^    }$/p' iPhoneUse/Agent/Decide.swift | sed 's/^    static func/func/'
  cat <<'EOF'
let apps = ["com.apple.Preferences": "Settings", "com.zimride.instant": "Lyft", "com.ubercab.UberClient": "Uber",
            "com.ubercab.UberEats": "Uber Eats", "com.apple.mobilenotes": "Notes"]
assert(appBundleID("settings", in: apps) == "com.apple.Preferences")
assert(appBundleID("Uber", in: apps) == "com.ubercab.UberClient")      // exact beats prefix
assert(appBundleID("uber ea", in: apps) == "com.ubercab.UberEats")     // prefix
assert(appBundleID("Eats", in: apps) == "com.ubercab.UberEats")        // substring
assert(appBundleID("com.zimride.instant", in: apps) == "com.zimride.instant")
assert(appBundleID("Instagram", in: apps) == nil)
print("appBundleID ok")
EOF
} > "$F"
swift "$F"
