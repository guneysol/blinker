#!/bin/bash
# Local release checks. No GitHub Actions, installation, or publishing.
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n install.sh build.sh
python3 scripts/test-installer.py
swift test
swift build -c release -Xswiftc -warnings-as-errors
bash build.sh
codesign --verify --deep --strict build/Blinker.app
build/Blinker.app/Contents/MacOS/Blinker --version
