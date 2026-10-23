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

if $DO_INSTALL; then
  echo "Installing DevTools.app to $INSTALL_DIR..."
  pkill -f "$APP_DIR/Contents/MacOS/DevTools" 2>/dev/null || true
  sleep 1
  rm -rf "$INSTALL_DIR/$APP_DIR"
  mv "$APP_DIR" "$INSTALL_DIR/$APP_DIR"
  
  echo "Linking 'ws' to /usr/local/bin/ws..."
  mkdir -p /usr/local/bin 2>/dev/null || true
  if cp ".build/release/ws" "/usr/local/bin/ws" 2>/dev/null; then
    chmod +x "/usr/local/bin/ws"
    echo "CLI installed to /usr/local/bin/ws"
  else
    echo "Notice: Could not write to /usr/local/bin (requires sudo). Try: sudo cp .build/release/ws /usr/local/bin/"
  fi
  
  open "$INSTALL_DIR/$APP_DIR"
  echo "Installed and running. Look for hammer icon in menu bar."
else
  echo
  echo "Run App: open $APP_DIR"
  echo "Run CLI: .build/release/ws"
  echo "Install: $0 --install"
fi
