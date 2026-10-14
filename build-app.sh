#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
MACCLEAN_IDENTITY="${MACCLEAN_SIGN_IDENTITY:-}"
if [[ -z "$MACCLEAN_IDENTITY" && -f .signing-identity ]]; then
  MACCLEAN_IDENTITY="$(<.signing-identity)"
fi
MACCLEAN_IDENTITY="${MACCLEAN_IDENTITY:--}"
function macclean_sign() {
  if [[ "$MACCLEAN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$1"
  else
    # Pin the certificate, not a build-specific hash. Do not silently rotate identities.
    if [[ ! "$MACCLEAN_IDENTITY" =~ '^[[:xdigit:]]{40}$' ]]; then
      print -u2 "MACCLEAN_SIGN_IDENTITY must be the fixed certificate SHA-1 fingerprint."; return 1
    fi
    codesign --force --sign "$MACCLEAN_IDENTITY" --requirements "=designated => identifier \"com.daxiang.macclean\" and certificate leaf = H\"${MACCLEAN_IDENTITY:l}\"" "$1"
  fi
  codesign --verify --strict "$1"
}
MACCLEAN_SWIFT_FLAGS=(-c release -j 2 -Xswiftc -gnone -Xswiftc -file-prefix-map -Xswiftc "$PWD=/MacClean")
swift build "${MACCLEAN_SWIFT_FLAGS[@]}"
MACCLEAN_APP="$PWD/MacClean.app"
MACCLEAN_BIN_DIR="$(swift build "${MACCLEAN_SWIFT_FLAGS[@]}" --show-bin-path)"
# Keep the bundle at its established desktop target; never recursively remove it.
mkdir -p "$MACCLEAN_APP/Contents/MacOS" "$MACCLEAN_APP/Contents/Resources"
MACCLEAN_STAGE="$(mktemp "$MACCLEAN_APP/Contents/MacOS/MacClean.XXXXXX")"
cp "$MACCLEAN_BIN_DIR/MacClean" "$MACCLEAN_STAGE"
strip -S "$MACCLEAN_STAGE"
chmod 755 "$MACCLEAN_STAGE"
mv -f "$MACCLEAN_STAGE" "$MACCLEAN_APP/Contents/MacOS/MacClean"
cp Info.plist "$MACCLEAN_APP/Contents/Info.plist"
"$MACCLEAN_APP/Contents/MacOS/MacClean" --make-icon "$MACCLEAN_APP/Contents/Resources/MacClean.icns"
macclean_sign "$MACCLEAN_APP"
touch "$MACCLEAN_APP"
# A Finder copy on the desktop is independent from the project bundle.
# Only update an existing regular copy bearing this app's identifier.
MACCLEAN_DESKTOP_APP="$HOME/Desktop/MacClean.app"
if [[ "${MACCLEAN_SYNC_DESKTOP:-1}" == "1" && -d "$MACCLEAN_DESKTOP_APP/Contents/MacOS" && ! -L "$MACCLEAN_DESKTOP_APP" && "$MACCLEAN_DESKTOP_APP" != "$MACCLEAN_APP" ]]; then
  MACCLEAN_DESKTOP_ID="$(plutil -extract CFBundleIdentifier raw "$MACCLEAN_DESKTOP_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$MACCLEAN_DESKTOP_ID" == "com.daxiang.macclean" ]]; then
    if /bin/ps -axo comm= | /usr/bin/grep -F -x -q "$MACCLEAN_DESKTOP_APP/Contents/MacOS/MacClean"; then
      print -u2 "Quit the desktop MacClean before updating it. The project build remains available."
      exit 1
    fi
    if [[ ! -e "$PWD/.build/MacClean-desktop-before-update.zip" ]]; then
      ditto -c -k --keepParent "$MACCLEAN_DESKTOP_APP" "$PWD/.build/MacClean-desktop-before-update.zip"
    fi
    MACCLEAN_DESKTOP_STAGE="$(mktemp "$MACCLEAN_DESKTOP_APP/Contents/MacOS/MacClean.XXXXXX")"
    cp "$MACCLEAN_APP/Contents/MacOS/MacClean" "$MACCLEAN_DESKTOP_STAGE"
    chmod 755 "$MACCLEAN_DESKTOP_STAGE"
    mv -f "$MACCLEAN_DESKTOP_STAGE" "$MACCLEAN_DESKTOP_APP/Contents/MacOS/MacClean"
    cp "$MACCLEAN_APP/Contents/Info.plist" "$MACCLEAN_DESKTOP_APP/Contents/Info.plist"
    cp "$MACCLEAN_APP/Contents/Resources/MacClean.icns" "$MACCLEAN_DESKTOP_APP/Contents/Resources/MacClean.icns"
    macclean_sign "$MACCLEAN_DESKTOP_APP"
    touch "$MACCLEAN_DESKTOP_APP"
  fi
fi
echo "$MACCLEAN_APP"
