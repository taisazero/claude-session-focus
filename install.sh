#!/usr/bin/env bash
# Build and install claude-session-focus + the ccfocus:// URL scheme handler.
# Safe to re-run; re-running re-signs the applet, so re-check its Accessibility
# grant afterwards (System Settings > Privacy & Security > Accessibility).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/ClaudeSessionFocus.app"
PLIST="$APP/Contents/Info.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

echo "==> Compiling claude-session-focus"
xcrun swiftc -O "$DIR/claude-session-focus.swift" -o "$DIR/claude-session-focus"

echo "==> Building ClaudeSessionFocus.app (ccfocus:// handler) into $APP_DIR"
mkdir -p "$APP_DIR" "$DIR/build"
sed "s|__TOOL_DIR__|$DIR|" "$DIR/wrapper.applescript.template" > "$DIR/build/wrapper.applescript"
rm -rf "$APP"
osacompile -o "$APP" "$DIR/build/wrapper.applescript"

echo "==> Registering the ccfocus:// scheme"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.taisazero.claude-session-focus' "$PLIST" 2>/dev/null ||
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.taisazero.claude-session-focus' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes array' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0 dict' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLName string ccfocus' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string ccfocus' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$PLIST"
codesign --force -s - "$APP"
"$LSREGISTER" -f "$APP"

echo "==> Installed."
echo
echo "One-time setup left to you:"
echo "  System Settings > Privacy & Security > Accessibility > enable ClaudeSessionFocus"
echo "  (it appears in the list after the first denied run; the first link click triggers that)"
echo
echo 'Test: open "ccfocus://<session title substring, spaces as %20>"'
echo "Log:  $DIR/last-run.log"
