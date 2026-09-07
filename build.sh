#!/bin/bash
# Builds Portly Custom.app and the portly CLI, then installs both.
#
#   ./build.sh            build + install to /Applications and /usr/local/bin
#   ./build.sh --no-install   build only, leaves the bundle in ./dist
#   ./build.sh --run          build, install, and relaunch the app
#   ./build.sh --forever      build, install, and enable launch at login
#   ./build.sh --release      universal, ad-hoc signed ZIP for a GitHub release
#
# --release carries nothing personal: it never touches the local configuration in
# ~/.config/portly, and it signs ad-hoc instead of with a developer certificate,
# so no Apple ID, team identifier or machine name ends up in the archive.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Portly Custom.app"
INSTALL=1
RUN=0
FOREVER=0
RELEASE=0
RUNNING_SERVERS=()

# `trash` is a personal convenience, not a dependency: anyone who clones the
# repository should be able to build without installing it.
discard() {
  [ -e "$1" ] || return 0
  if command -v trash >/dev/null 2>&1; then
    trash "$1"
  else
    rm -rf "$1"
  fi
}

for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --run) RUN=1 ;;
    --forever) FOREVER=1 ;;
    --release) RELEASE=1; INSTALL=0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Building (release)"
cd "$ROOT"
if [ "$RELEASE" -eq 1 ]; then
  swift build -c release --triple arm64-apple-macosx14.0 --product PortlyApp
  swift build -c release --triple x86_64-apple-macosx14.0 --product PortlyApp
  swift build -c release --triple arm64-apple-macosx14.0 --product portly
  swift build -c release --triple x86_64-apple-macosx14.0 --product portly
  ARM64_BIN_DIR="$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)"
  X86_64_BIN_DIR="$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)"
  BIN_DIR="$ARM64_BIN_DIR"
else
  swift build -c release --product PortlyApp
  swift build -c release --product portly
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

VERSION="$(grep -o '"[0-9][^"]*"' "$ROOT/Sources/PortlyCore/Version.swift" | tr -d '"')"

echo "==> Assembling Portly Custom.app"
discard "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

if [ "$RELEASE" -eq 1 ]; then
  lipo -create "$ARM64_BIN_DIR/PortlyApp" "$X86_64_BIN_DIR/PortlyApp" -output "$APP/Contents/MacOS/Portly"
  ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Portly")"
  case " $ARCHITECTURES " in
    *" arm64 "*) ;;
    *) echo "Universal build is missing arm64: $ARCHITECTURES" >&2; exit 1 ;;
  esac
  case " $ARCHITECTURES " in
    *" x86_64 "*) ;;
    *) echo "Universal build is missing x86_64: $ARCHITECTURES" >&2; exit 1 ;;
  esac
  echo "    architectures: $ARCHITECTURES"
else
  cp "$BIN_DIR/PortlyApp" "$APP/Contents/MacOS/Portly"
fi

# SwiftTerm ships a resource bundle; carry it along if this build produced one.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# The downloadable app performs agent setup itself, so it must carry both the
# distributable skill and a CLI matching the app's architectures.
cp -R "$ROOT/skills/portly" "$APP/Contents/Resources/portly-skill"
if [ "$RELEASE" -eq 1 ]; then
  lipo -create "$ARM64_BIN_DIR/portly" "$X86_64_BIN_DIR/portly" -output "$APP/Contents/Resources/portly-cli"
else
  cp "$BIN_DIR/portly" "$APP/Contents/Resources/portly-cli"
fi
chmod +x "$APP/Contents/Resources/portly-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Portly Custom</string>
	<key>CFBundleDisplayName</key>
	<string>Portly Custom</string>
	<key>CFBundleIdentifier</key>
	<string>dev.portly.app</string>
	<key>CFBundleExecutable</key>
	<string>Portly</string>
	<key>CFBundleIconFile</key>
	<string>Portly</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> Icon"
if swift "$ROOT/Tools/makeicon.swift" "$APP/Contents/Resources/Portly.icns" >/dev/null 2>&1; then
  echo "    generated"
else
  echo "    skipped (icon generation failed, using the default)"
fi

if [ "$RELEASE" -eq 1 ]; then
  # An ad-hoc signature is deliberate. A Developer ID certificate would stamp the
  # maintainer's Apple ID and team identifier into every downloaded copy, and this
  # fork is not notarized, so the download instructions clear the quarantine flag
  # instead. Nothing about the machine that built the archive travels with it.
  echo "==> Signing (ad-hoc)"
  codesign --force --sign - "$APP/Contents/Resources/portly-cli"
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"

  ARCHIVE="$DIST/Portly-Studio-macOS.zip"
  discard "$ARCHIVE"
  echo "==> Archiving"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
  echo "    $ARCHIVE"
else
  # A fixed identity keeps the TCC grants (Full Disk Access, Accessibility)
  # across rebuilds; ad-hoc signatures change every build and lose them.
  DEV_IDENTITY="${PORTLY_DEV_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
  if [ -n "$DEV_IDENTITY" ] && codesign --force --deep --sign "$DEV_IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "==> Signed with $DEV_IDENTITY"
  else
    echo "==> Signing (ad-hoc)"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    ad-hoc signing failed, continuing"
  fi
fi

if [ "$INSTALL" -eq 1 ]; then
  echo "==> Installing"
  if pgrep -x Portly >/dev/null 2>&1; then
    if command -v portly >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      while IFS= read -r server_id; do
        [ -n "$server_id" ] && RUNNING_SERVERS+=("$server_id")
      done < <(portly status --json 2>/dev/null | jq -r '.projects[].servers[] | select(.state != "stopped" and .state != "failed") | .id')
    fi
    echo "    quitting the running Portly (this stops your servers)"
    if command -v portly >/dev/null 2>&1; then
      portly quit >/dev/null 2>&1 || true
    fi
    osascript -e 'quit app "Portly Custom"' >/dev/null 2>&1 || true
    osascript -e 'quit app "Portly"' >/dev/null 2>&1 || true
    for _ in {1..20}; do
      pgrep -x Portly >/dev/null 2>&1 || break
      sleep 0.25
    done
    if pgrep -x Portly >/dev/null 2>&1; then
      echo "    Portly did not quit; close its open sheet and run the installer again" >&2
      exit 1
    fi
  fi
  discard /Applications/Portly.app
  discard "/Applications/Portly Custom.app"
  cp -R "$APP" "/Applications/Portly Custom.app"
  echo "    /Applications/Portly Custom.app"

  # Every writable bin directory on PATH gets the CLI, so a stale copy of the
  # stock Portly CLI can never shadow the custom one.
  CLI_TARGET=""
  for candidate in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    if [ -d "$candidate" ] && [ -w "$candidate" ] && { [ -z "$CLI_TARGET" ] || [ -e "$candidate/portly" ]; }; then
      cp "$APP/Contents/Resources/portly-cli" "$candidate/portly"
      chmod +x "$candidate/portly"
      echo "    $candidate/portly"
      [ -z "$CLI_TARGET" ] && CLI_TARGET="$candidate/portly"
    fi
  done

  if [ -n "$CLI_TARGET" ]; then
    :
  else
    echo "    no writable bin directory found, run:"
    echo "      sudo cp '$BIN_DIR/portly' /usr/local/bin/portly"
  fi

  SKILL_TARGET="$HOME/.agents/skills/portly"
  mkdir -p "$HOME/.agents/skills"
  if [ -L "$SKILL_TARGET" ]; then
    rm -f "$SKILL_TARGET"
  else
    discard "$SKILL_TARGET"
  fi
  cp -R "$ROOT/skills/portly" "$SKILL_TARGET"
  echo "    $SKILL_TARGET"

  AGENTS_FILE="$HOME/.agents/AGENTS.md"
  mkdir -p "$(dirname "$AGENTS_FILE")"
  RULE_SNIPPET="$(mktemp "${TMPDIR:-/tmp}/portly-rule.XXXXXX")"
  cat > "$RULE_SNIPPET" <<'RULE'
<!-- portly:managed-rule:start -->
## Development servers

- Always use Portly (`portly ...`) to start, stop, restart, inspect, or keep local development servers running.
- Start with `portly status`. Use `portly status --details` only for the full inventory and metrics, and `--json` only for machine-readable fields. Reuse a healthy managed server; if an in-scope server is running outside Portly, register it and use `portly take-over <project/server> --json`.
- For long-lived or reusable work, create a project and server.
- For builds, tests, code generation, and other bounded one-off work, run it directly in the foreground with a timeout; Portly only supervises servers.
- Never launch persistent development servers directly, in the background, or through another supervisor.
<!-- portly:managed-rule:end -->
RULE

  if [ -f "$AGENTS_FILE" ] && grep -q 'portly:managed-rule:start' "$AGENTS_FILE" && grep -q 'portly:managed-rule:end' "$AGENTS_FILE"; then
    UPDATED_RULES="$(mktemp "${TMPDIR:-/tmp}/portly-agents.XXXXXX")"
    awk -v rule_file="$RULE_SNIPPET" '
      /<!-- portly:managed-rule:start -->/ {
        while ((getline line < rule_file) > 0) print line
        close(rule_file)
        replacing = 1
        next
      }
      replacing && /<!-- portly:managed-rule:end -->/ { replacing = 0; next }
      !replacing { print }
    ' "$AGENTS_FILE" > "$UPDATED_RULES"
    mv "$UPDATED_RULES" "$AGENTS_FILE"
    echo "    $AGENTS_FILE (Portly rules updated)"
  else
    if [ -s "$AGENTS_FILE" ]; then printf '\n' >> "$AGENTS_FILE"; fi
    cat "$RULE_SNIPPET" >> "$AGENTS_FILE"
    echo "    $AGENTS_FILE (Portly rules added)"
  fi
  rm -f "$RULE_SNIPPET"
fi

if [ "$FOREVER" -eq 1 ]; then
  if [ "$INSTALL" -ne 1 ]; then
    echo "    --forever requires installation; remove --no-install" >&2
    exit 1
  fi
  echo "==> Enabling launch at login"
  portly forever enable
elif [ "$RUN" -eq 1 ]; then
  echo "==> Launching"
  open "/Applications/Portly Custom.app"
fi

if { [ "$FOREVER" -eq 1 ] || [ "$RUN" -eq 1 ]; } && [ "${#RUNNING_SERVERS[@]}" -gt 0 ]; then
  echo "==> Restoring active servers"
  # The app needs a moment to bring its control API up after `open`.
  for _ in {1..60}; do
    curl -s -o /dev/null "http://127.0.0.1:7737/status" && break
    sleep 0.25
  done
  for server_id in "${RUNNING_SERVERS[@]}"; do
    portly start "$server_id" --json >/dev/null
    echo "    $server_id"
  done
fi

echo "Done."
