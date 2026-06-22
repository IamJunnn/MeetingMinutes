#!/usr/bin/env bash
#
# Build Meeting Minutes and install it to /Applications.
#
# Works with zero configuration: if you haven't set a signing team in
# Local.xcconfig, it builds with ad-hoc signing (runs locally, no Apple account
# needed). If you have set a team, it uses it for a stable signature that keeps
# macOS permission grants across rebuilds.
#
# Usage:  ./scripts/install.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="MeetingMinutes.xcodeproj"
SCHEME="MeetingMinutes"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode (and run: xcode-select --install)." >&2
  exit 1
fi

# Decide how to sign.
TEAM=""
if [ -f Local.xcconfig ]; then
  TEAM=$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM' Local.xcconfig | tail -1 | sed 's/.*=//' | tr -d '[:space:]' || true)
fi

SIGN_ARGS=()
if [ -n "$TEAM" ] && [ "$TEAM" != "YOUR_TEAM_ID" ]; then
  echo "==> Signing with your team: $TEAM"
else
  echo "==> No DEVELOPMENT_TEAM set — using ad-hoc signing (runs locally, no Apple account needed)."
  echo "    For permissions that persist across rebuilds, copy Local.xcconfig.example to"
  echo "    Local.xcconfig and set your team ID."
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=)
fi

echo "==> Resolving Swift packages..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -resolvePackageDependencies >/dev/null

echo "==> Building (Release) — this compiles whisper.cpp and may take a few minutes..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release -destination 'platform=macOS' \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  build >/dev/null

APP=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')

if [ ! -d "$APP" ]; then
  echo "error: build product not found at: $APP" >&2
  exit 1
fi

DEST="/Applications/MeetingMinutes.app"
echo "==> Installing to $DEST..."
rm -rf "$DEST" 2>/dev/null || true
if ! cp -R "$APP" /Applications/ 2>/dev/null; then
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/MeetingMinutes.app"
  rm -rf "$DEST" 2>/dev/null || true
  cp -R "$APP" "$HOME/Applications/"
fi

echo ""
echo "Installed: $DEST"
echo ""
echo "Launch it from Spotlight (Cmd-Space, type \"Meeting Minutes\") or your Applications folder."
echo "On first run, grant Microphone and Screen Recording, then quit and reopen once"
echo "(macOS only applies Screen Recording on a fresh launch)."
