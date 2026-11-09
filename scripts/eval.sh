#!/bin/bash
# Offline eval on the Mac: one decision per evals/cases/<case>, scored, per model.
# usage: scripts/eval.sh [model ...]   (default: Jev and Claude Haiku; CASES=a,b to pick cases)
# Compiles the app's own Decide/Jev/ScreenText/LLMSettings with evals/Eval.swift; no Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/evals
A=iPhoneUse/Agent
swiftc -O -parse-as-library -o .build/evals/run $A/Decide.swift $A/Jev.swift $A/ScreenText.swift $A/LLMSettings.swift evals/Eval.swift
OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-$(sed -n 's/^OPEN_ROUTER=//p' ~/.credentials 2>/dev/null | tr -d '"')} .build/evals/run "$@"
