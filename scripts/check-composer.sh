#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local
swiftc -swift-version 5 Sources/AgentWorkbench/MessageComposer.swift Tests/ComposerChecks/main.swift -o .local/ComposerChecks
.local/ComposerChecks
