#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="DevTools"
APP_DIR="$APP_NAME.app"
INSTALL_DIR="/Applications"

DO_INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --install|-i) DO_INSTALL=true ;;
    --uninstall|-u)
      echo "Removing $INSTALL_DIR/$APP_NAME.app and /usr/local/bin/ws..."
      rm -rf "$INSTALL_DIR/$APP_NAME.app"
      rm -f "/usr/local/bin/ws"
      echo "Done."
      exit 0
      ;;
    --help|-h)
      echo "Usage: $0 [--install] [--uninstall]"
      echo "  (no flag)   Build DevTools.app and ws CLI in this directory"
      echo "  --install   Build + install DevTools.app to /Applications + install ws to /usr/local/bin"
      echo "  --uninstall Remove from system"
      exit 0
      ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  echo "❌ Swift not found. Install Command Line Tools: xcode-select --install"
  exit 1
fi

# Package.swift declares swift-tools-version 6.0. A Swift 5.x toolchain cannot
# parse it and fails with a confusing "package is using Swift tools version" error.
# The default `swift` on a CI runner may be the Command Line Tools one, not Xcode's.
SWIFT_VERSION=$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
if ! printf '%s' "$SWIFT_VERSION" | grep -qE 'Swift version (6|[7-9])\.'; then
  echo "❌ Need Swift 6.x, found: ${SWIFT_VERSION:-unknown}"
  echo "   Select a newer Xcode:  sudo xcode-select -s /Applications/Xcode_16.app"
  exit 1
fi
echo "Using ${SWIFT_VERSION}"

echo "Building release artifacts..."
swift build -c release

echo "Wrapping in $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/DevTools" "$APP_DIR/Contents/MacOS/DevTools"
cp ".build/release/ws" "$APP_DIR/Contents/Resources/ws"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "bin/sync-models" ]]; then
  cp "bin/sync-models" "$APP_DIR/Contents/Resources/sync-models"
  chmod +x "$APP_DIR/Contents/Resources/sync-models"
fi
chmod +x "$APP_DIR/Contents/MacOS/DevTools"
chmod +x "$APP_DIR/Contents/Resources/ws"

# Ad-hoc sign
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
xattr -cr "$APP_DIR"

echo "Built $APP_DIR and CLI binary .build/release/ws"

# User data that MUST survive every install/update. Nothing in this script may ever
# delete these paths. All live outside the .app bundle by design.
#
#   ~/workspaces/               task worktrees
#   ~/.cache/ws/repos/          bare mirrors (incl. unpushed workspace branches)
#   ~/.config/ws/               repo list + activity ranking cache
#   ~/.llm-usage-key            gateway bearer token
#   ~/.llm-usage-user           gateway user id
#   ~/.llm-usage-config         gateway base URL
#   ~/.llm-usage-models.json    cached model catalog
#
# ponytail: this list is the whole contract between install and user data. If you
# ever add a `rm` touching one of these, you are deleting someone's work.
PRESERVED_PATHS=(
  "$HOME/workspaces"
  "$HOME/.cache/ws"
  "$HOME/.config/ws"
  "$HOME/.llm-usage-key"
  "$HOME/.llm-usage-user"
  "$HOME/.llm-usage-config"
  "$HOME/.llm-usage-models.json"
)

assert_preserved() {
  for p in "${PRESERVED_PATHS[@]}"; do
    case "$1" in
      *"$p"*|*"~/${p##*/}"*) echo "FATAL: install step would delete preserved path: $p" >&2; exit 1 ;;
    esac
  done
}

if $DO_INSTALL; then
  echo "Installing DevTools.app to $INSTALL_DIR..."
  pkill -f "$APP_DIR/Contents/MacOS/DevTools" 2>/dev/null || true
  sleep 1
  assert_preserved "$INSTALL_DIR/$APP_DIR"
  rm -rf "$INSTALL_DIR/$APP_DIR"
  mv "$APP_DIR" "$INSTALL_DIR/$APP_DIR"
  
  echo "Installing 'ws' CLI..."
  USER_BIN="$HOME/.local/bin"
  mkdir -p "$USER_BIN"
  assert_preserved "$USER_BIN/ws"
  cp ".build/release/ws" "$USER_BIN/ws"
  chmod +x "$USER_BIN/ws"
  echo "CLI installed to $USER_BIN/ws"
  
  if assert_preserved "/usr/local/bin/ws" && cp ".build/release/ws" "/usr/local/bin/ws" 2>/dev/null; then
    chmod +x "/usr/local/bin/ws"
    echo "CLI also linked to /usr/local/bin/ws"
  fi
  
  open "$INSTALL_DIR/$APP_DIR"
  echo "Installed and running. Look for hammer icon in menu bar."
else
  echo
  echo "Run App: open $APP_DIR"
  echo "Run CLI: .build/release/ws"
  echo "Install: $0 --install"
fi
