#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_name=$(plutil -extract CFBundleName raw Resources/Info.plist)
resources="$PWD/dist/$app_name.app/Contents/Resources"
"$resources/runtime/bin/python3.12" -B Tests/workers.py
mkdir -p build/ModelChecks.app/Contents/MacOS
cp Resources/Info.plist build/ModelChecks.app/Contents/
ln -sfn "$resources" build/ModelChecks.app/Contents/Resources
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path build/swift-cache Sources/Workspace.swift Sources/Model.swift Sources/Preview.swift Sources/SizeWarning.swift Tests/ModelChecks.swift -o build/ModelChecks.app/Contents/MacOS/ModelChecks
"$resources/runtime/bin/python3.12" -B Tests/workers.py --fixture "$PWD/build/model.pdf"
build/ModelChecks.app/Contents/MacOS/ModelChecks "$PWD/build"
