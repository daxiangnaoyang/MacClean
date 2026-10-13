#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
MACCLEAN_VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
MACCLEAN_ARCH="$(uname -m)"
if [[ "$MACCLEAN_ARCH" != "arm64" ]]; then
  print -u2 "This release workflow is verified only for Apple Silicon."
  exit 1
fi
env MACCLEAN_SYNC_DESKTOP=0 zsh build-app.sh
MacClean.app/Contents/MacOS/MacClean --self-test
MacClean.app/Contents/MacOS/MacClean --render-public-docs docs/images
mkdir -p dist
MACCLEAN_STAGE="$(mktemp -d "$PWD/.build/public-release.XXXXXX")"
mkdir "$MACCLEAN_STAGE/installer" "$MACCLEAN_STAGE/docs"
ditto --norsrc --noextattr MacClean.app "$MACCLEAN_STAGE/installer/MacClean.app"
ln -s /Applications "$MACCLEAN_STAGE/installer/Applications"
cp docs/INSTALL.md "$MACCLEAN_STAGE/installer/INSTALL.md"
mkdir "$MACCLEAN_STAGE/installer/images"
cp docs/images/settings.png "$MACCLEAN_STAGE/installer/images/settings.png"
codesign --verify --strict "$MACCLEAN_STAGE/installer/MacClean.app"
node verify-publication.mjs
MACCLEAN_PREFIX="MacClean-$MACCLEAN_VERSION"
for MACCLEAN_OUTPUT in "$MACCLEAN_PREFIX-$MACCLEAN_ARCH.dmg" "$MACCLEAN_PREFIX-$MACCLEAN_ARCH.app.zip" "$MACCLEAN_PREFIX-docs.zip"; do
  if [[ -e "dist/$MACCLEAN_OUTPUT" ]]; then
    print -u2 "Refusing to overwrite existing release asset: dist/$MACCLEAN_OUTPUT"
    exit 1
  fi
done
hdiutil create -volname "MacClean $MACCLEAN_VERSION" -srcfolder "$MACCLEAN_STAGE/installer" -format UDZO "dist/$MACCLEAN_PREFIX-$MACCLEAN_ARCH.dmg"
ditto --norsrc --noextattr -c -k --keepParent "$MACCLEAN_STAGE/installer/MacClean.app" "dist/$MACCLEAN_PREFIX-$MACCLEAN_ARCH.app.zip"
ditto --norsrc --noextattr docs "$MACCLEAN_STAGE/docs/docs"
cp README.md VERIFICATION.md CHANGELOG.md LICENSE "$MACCLEAN_STAGE/docs/"
ditto --norsrc --noextattr -c -k --keepParent "$MACCLEAN_STAGE/docs" "dist/$MACCLEAN_PREFIX-docs.zip"
shasum -a 256 dist/"$MACCLEAN_PREFIX-$MACCLEAN_ARCH.dmg" dist/"$MACCLEAN_PREFIX-$MACCLEAN_ARCH.app.zip" dist/"$MACCLEAN_PREFIX-docs.zip" | sed 's@  dist/@  @' > dist/SHA256SUMS.txt
print "Release artifacts: $PWD/dist"
print "Recoverable packaging stage retained: $MACCLEAN_STAGE"
