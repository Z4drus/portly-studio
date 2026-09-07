#!/bin/bash
# Publishes the version already committed in Sources/PortlyCore/Version.swift as a
# GitHub release: a universal, ad-hoc signed macOS app built from the pushed commit.
#
#   ./release.sh 0.2.0
#
# The archive is deliberately free of anything personal. It is built from a clean
# `git archive` of HEAD, never from the working tree, it carries no configuration
# from ~/.config/portly, and its ad-hoc signature contains no Apple ID or team
# identifier. macOS therefore treats the download as unidentified: the release
# notes tell people to clear the quarantine flag.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${PORTLY_RELEASE_REPO:-Z4drus/portly-studio}"
VERSION="$(git -C "$ROOT" show HEAD:Sources/PortlyCore/Version.swift | grep -o '"[0-9][^"]*"' | tr -d '"')"
EXPECTED_VERSION="${1:-$VERSION}"
TAG="v$VERSION"

if [ "$EXPECTED_VERSION" != "$VERSION" ]; then
  echo "Version.swift contains $VERSION, not $EXPECTED_VERSION." >&2
  exit 1
fi

BRANCH="$(git -C "$ROOT" branch --show-current)"
LOCAL_SHA="$(git -C "$ROOT" rev-parse HEAD)"
REMOTE_SHA="$(git -C "$ROOT" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  echo "Push $BRANCH before publishing $TAG." >&2
  exit 1
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists." >&2
  exit 1
fi

RELEASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/portly-release.XXXXXX")"
SOURCE_DIR="$RELEASE_DIR/source"
mkdir -p "$SOURCE_DIR"
trap 'rm -rf "$RELEASE_DIR"' EXIT

# Build exactly the pushed commit. Local edits in the working tree are never
# stashed, copied into the archive, or otherwise disturbed.
git -C "$ROOT" archive HEAD | tar -x -C "$SOURCE_DIR"
"$SOURCE_DIR/build.sh" --release

NOTES="$RELEASE_DIR/notes.md"
cat > "$NOTES" <<NOTE
Universal build for Apple silicon and Intel, macOS 14 or newer.

### Install

1. Download \`Portly-Studio-macOS.zip\` and unzip it.
2. Move **Portly Custom.app** to \`/Applications\`.
3. The build is ad-hoc signed rather than notarized, so clear the quarantine flag once:

   \`\`\`bash
   xattr -dr com.apple.quarantine "/Applications/Portly Custom.app"
   open "/Applications/Portly Custom.app"
   \`\`\`

Portly Studio lives in the menu bar. Open its onboarding card to install the \`portly\`
CLI and the agent skill, and to grant Full Disk Access and Accessibility so the agents
it starts inherit them.
NOTE

gh release create "$TAG" \
  "$SOURCE_DIR/dist/Portly-Studio-macOS.zip#Portly Studio for macOS (universal)" \
  --repo "$REPO" \
  --target "$LOCAL_SHA" \
  --title "Portly Studio $VERSION" \
  --notes-file "$NOTES"

mkdir -p "$ROOT/dist"
cp "$SOURCE_DIR/dist/Portly-Studio-macOS.zip" "$ROOT/dist/Portly-Studio-macOS.zip"

gh release view "$TAG" --repo "$REPO" --json tagName,url,assets
