#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'DueBridge requires macOS and Apple frameworks.' >&2
  exit 1
fi
SDK="${DUEBRIDGE_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ ! -d "$SDK" ]]; then printf '%s\n' 'The selected macOS SDK directory is unavailable.' >&2; exit 1; fi
mkdir -p "$ROOT/build/module-cache"
FLAGS=(-sdk "$SDK" -target arm64-apple-macosx14.0 -swift-version 5 -module-cache-path "$ROOT/build/module-cache")
APP_FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework EventKit -framework CryptoKit -framework Combine -framework Security -framework ServiceManagement -framework WebKit)
source "$ROOT/scripts/source-files.sh"
