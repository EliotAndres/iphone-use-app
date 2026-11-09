#!/bin/bash
# Checks Jev.typeCandidates (the text Jev may type) without building the app.
set -euo pipefail
cd "$(dirname "$0")/.."
F=$(mktemp -t tc).swift
{ echo 'import Foundation'
  sed -n '/static func typeCandidates/,/^    }$/p' iPhoneUse/Agent/Jev.swift | sed 's/^    static func/func/'
  cat <<'EOF'
let a = typeCandidates("Text Marc \"running late, sorry\" on WhatsApp")
assert(a.first == "running late, sorry" && !a.contains { $0.contains("\"") })
let b = typeCandidates("Get a Lyft to the Eiffel Tower")
assert(b.contains("Eiffel Tower") && b.contains("Lyft"))
assert(typeCandidates("I'm going to 'Gare de Lyon' now").first == "Gare de Lyon")
print("typeCandidates ok")
EOF
} > "$F"
swift "$F"
