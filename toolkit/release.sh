#!/bin/bash
# toolkit/release.sh — Archive, Developer ID export, notarize, DMG, minisign, GitHub release.
# Driven by osxr.json. Secrets in ~/.config/osxr/. See skills/setup/SKILL.md.
# Run --help for usage.
set -euo pipefail

TOOLKIT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }
step() { echo ""; echo "▶ $*"; }

print_help() {
  cat <<'EOF'
release.sh — Archive, Developer ID export, notarize, DMG, minisign, GitHub release.

Driven by osxr.json at the project root (walks up from cwd). Secrets live in
~/.config/osxr/ — never in the repo. See /osxr:setup.

Usage (from anywhere inside a project with osxr.json):
  release.sh                 # dry run: build + sign + DMG; no notarize/publish/push
  release.sh --apply         # full release
  release.sh 0.2 --apply     # set marketing version, bump build, release
  release.sh --dry-run       # same as default (explicit)

Options:
  [VERSION]       Optional marketing version (e.g. 1.2). Build always bumps.
  --apply         Notarize, staple, minisign, commit, push, gh release create
  --dry-run       Build + sign + DMG only (default)
  -h, --help      Show this help and exit (works without osxr.json)

Environment overrides:
  NOTARY_PROFILE       Keychain profile (default: osxr.json notaryProfile)
  MINISIGN_SECRET_KEY  Path to minisign secret (default: ~/.config/osxr/minisign.key)
  OSXR_CONFIG          Path to osxr.json (skip walk-up from cwd)
EOF
}

# Parse argv before looking for osxr.json so --help / bad flags work anywhere.
APPLY=false
NEW_VERSION=""
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --dry-run) APPLY=false ;;
    -h|--help) print_help; exit 0 ;;
    -*) die "unknown option ${arg}" ;;
    *) NEW_VERSION="$arg" ;;
  esac
done

# ── Locate osxr.json ───────────────────────────────────────────────────────────
find_config() {
  if [ -n "${OSXR_CONFIG:-}" ]; then
    [ -f "$OSXR_CONFIG" ] || die "OSXR_CONFIG not found: ${OSXR_CONFIG}"
    printf '%s' "$OSXR_CONFIG"
    return
  fi
  local dir="$PWD"
  while true; do
    if [ -f "${dir}/osxr.json" ]; then
      printf '%s' "${dir}/osxr.json"
      return
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done
  die "no osxr.json found (walked up from ${PWD}). Run /osxr:setup first."
}

CONFIG_PATH="$(find_config)"
PROJECT_ROOT="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
cd "$PROJECT_ROOT"

# ── Parse config (python3 — always on macOS) ───────────────────────────────────
# json_get KEY [DEFAULT]
# If DEFAULT is omitted and KEY is missing, exits 1. Pass "" for optional empty.
json_get() {
  local key="$1"
  local has_default=0
  local default=""
  if [ "$#" -ge 2 ]; then
    has_default=1
    default="$2"
  fi
  HAS_DEFAULT="$has_default" DEFAULT_VAL="$default" /usr/bin/python3 - "$CONFIG_PATH" "$key" <<'PY'
import json, os, sys
path, key = sys.argv[1], sys.argv[2]
has_default = os.environ.get("HAS_DEFAULT") == "1"
default = os.environ.get("DEFAULT_VAL", "")
with open(path) as f:
    data = json.load(f)
if key not in data:
    if has_default:
        val = default
    else:
        sys.exit(1)
else:
    val = data[key]
if val is None:
    if has_default:
        val = default
    else:
        sys.exit(1)
if isinstance(val, bool):
    print("true" if val else "false")
elif isinstance(val, list):
    print("\n".join(str(x) for x in val))
else:
    print(val)
PY
}

SCHEME="$(json_get scheme)" || die "osxr.json missing required key: scheme"
PROJECT="$(json_get project)" || die "osxr.json missing required key: project"
APP_NAME="$(json_get appName)" || die "osxr.json missing required key: appName"
NOTARY_PROFILE="${NOTARY_PROFILE:-$(json_get notaryProfile osxr-notary)}"
VERSION_SOURCE="$(json_get versionSource agvtool)"
RELEASE_BRANCH="$(json_get releaseBranch main)"
RUN_TESTS="$(json_get runTests false)"
DMG_BACKGROUND="$(json_get dmgBackground "")"
MINISIGN_PUB_URL="$(json_get minisignPublicKeyURL "")"
PROJECT_YML="$(json_get projectYml project.yml)"
INFO_PLIST="$(json_get infoPlist "")"
# Secret path: env > osxr.json > ~/.config/osxr/minisign.key
if [ -z "${MINISIGN_SECRET_KEY:-}" ]; then
  MINISIGN_SECRET_KEY="$(json_get minisignSecretKey "")"
  [ -z "$MINISIGN_SECRET_KEY" ] && MINISIGN_SECRET_KEY="$HOME/.config/osxr/minisign.key"
  # Expand leading ~/
  case "$MINISIGN_SECRET_KEY" in
    "~/"*) MINISIGN_SECRET_KEY="$HOME/${MINISIGN_SECRET_KEY#~/}" ;;
  esac
fi

ARCHIVE_PATH="build/${SCHEME}.xcarchive"
EXPORT_PATH="build/export"
EXPORT_OPTIONS="build/ExportOptions.plist"
STAGING_DMG="build/staging.dmg"
# Volume names can't have spaces reliably for Finder scripting — strip them.
MOUNT_SAFE_NAME="${APP_NAME// /}"
MOUNT_DIR="/Volumes/${MOUNT_SAFE_NAME}-staging"

cleanup() {
  if [ -d "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── 1. Preflight ───────────────────────────────────────────────────────────────
step "Preflight"

REQUIRED_TOOLS=(gh xcrun hdiutil minisign)
[ "$VERSION_SOURCE" = "xcodegen" ] && REQUIRED_TOOLS+=(xcodegen)
for tool in "${REQUIRED_TOOLS[@]}"; do
  command -v "$tool" >/dev/null || die "${tool} is not installed"
done

[ -f "$MINISIGN_SECRET_KEY" ] || die "minisign secret key not found: ${MINISIGN_SECRET_KEY}
       Generate your own with minisign -G (see /osxr:setup). Default path:
       ~/.config/osxr/minisign.key"

[ -f "$PROJECT" ] || [ -d "$PROJECT" ] || die "project not found: ${PROJECT}"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "$RELEASE_BRANCH" ] || die "on branch ${BRANCH}, expected ${RELEASE_BRANCH}"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"

git fetch --quiet origin "$RELEASE_BRANCH"
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/${RELEASE_BRANCH}")
[ "$LOCAL" = "$REMOTE" ] || die "local ${RELEASE_BRANCH} differs from origin — pull or push first"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  die "no 'Developer ID Application' certificate in the keychain.
       Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application.
       Requires the Account Holder or an Admin on the team."
fi

TEAM_ID=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk '/[[:space:]]DEVELOPMENT_TEAM = /{print $3; exit}')
[ -n "${TEAM_ID:-}" ] || die "DEVELOPMENT_TEAM is empty.
       Set it in a gitignored local xcconfig (Config/Local.xcconfig or
       Config/Signing.local.xcconfig). See /osxr:setup."

if [ "$APPLY" = true ]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || die \
    "no notary keychain profile named '${NOTARY_PROFILE}'.
       Create it with notarytool store-credentials using ~/.config/osxr/*.p8
       (see /osxr:setup), or override with NOTARY_PROFILE=<name>."
fi

echo "  config ${CONFIG_PATH}"
echo "  branch ${BRANCH}, tree clean, in sync with origin"
echo "  Developer ID certificate present, team ${TEAM_ID}"
echo "  mode: $([ "$APPLY" = true ] && echo apply || echo dry-run)"

# ── 2. Version ─────────────────────────────────────────────────────────────────
step "Version (${VERSION_SOURCE})"

COMMIT_PATHS=()
case "$VERSION_SOURCE" in
  agvtool)
    VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
      | awk '/MARKETING_VERSION/{print $3; exit}')
    [ -n "$VERSION" ] || die "could not read MARKETING_VERSION from xcodebuild"
    if [ -n "$NEW_VERSION" ]; then
      VERSION="$NEW_VERSION"
      xcrun agvtool new-marketing-version "$VERSION" >/dev/null
    fi
    xcrun agvtool next-version -all >/dev/null
    BUILD=$(xcrun agvtool what-version -terse)
    COMMIT_PATHS+=("$PROJECT/project.pbxproj")
    ;;

  plist)
    [ -n "$INFO_PLIST" ] || die "versionSource=plist requires infoPlist in osxr.json"
    [ -f "$INFO_PLIST" ] || die "infoPlist not found: ${INFO_PLIST}"
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$INFO_PLIST")
    BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$INFO_PLIST")
    [ -n "$VERSION" ] || die "could not read CFBundleShortVersionString from ${INFO_PLIST}"
    [ -n "$BUILD" ] || die "could not read CFBundleVersion from ${INFO_PLIST}"
    [ -n "$NEW_VERSION" ] && VERSION="$NEW_VERSION"
    BUILD=$((BUILD + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "$INFO_PLIST"
    COMMIT_PATHS+=("$INFO_PLIST")
    ;;

  xcodegen)
    [ -f "$PROJECT_YML" ] || die "projectYml not found: ${PROJECT_YML}"
    command -v xcodegen >/dev/null || die "xcodegen is not installed"
    read_yml() { grep -E "^[[:space:]]*$1:" "$PROJECT_YML" | head -1 | sed -E 's/.*"([^"]*)".*/\1/'; }
    VERSION=$(read_yml "MARKETING_VERSION")
    BUILD=$(read_yml "CFBundleVersion")
    [ -n "$VERSION" ] || die "could not read MARKETING_VERSION from ${PROJECT_YML}"
    [ -n "$BUILD" ] || die "could not read CFBundleVersion from ${PROJECT_YML}"
    [ -n "$NEW_VERSION" ] && VERSION="$NEW_VERSION"
    BUILD=$((BUILD + 1))
    sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION: )\"[^\"]*\"/\1\"${VERSION}\"/" "$PROJECT_YML"
    sed -i '' -E "s/^([[:space:]]*CFBundleShortVersionString: )\"[^\"]*\"/\1\"${VERSION}\"/" "$PROJECT_YML"
    sed -i '' -E "s/^([[:space:]]*CFBundleVersion: )\"[^\"]*\"/\1\"${BUILD}\"/" "$PROJECT_YML"
    xcodegen generate >/dev/null
    COMMIT_PATHS+=("$PROJECT_YML" "$PROJECT/project.pbxproj")
    if [ -n "$INFO_PLIST" ] && [ -f "$INFO_PLIST" ]; then
      GENERATED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
      GENERATED_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
      [ "$GENERATED_VERSION" = "$VERSION" ] || die "Info.plist says version ${GENERATED_VERSION}, expected ${VERSION}"
      [ "$GENERATED_BUILD" = "$BUILD" ] || die "Info.plist says build ${GENERATED_BUILD}, expected ${BUILD}"
      COMMIT_PATHS+=("$INFO_PLIST")
    fi
    ;;

  *)
    die "unknown versionSource '${VERSION_SOURCE}' (want agvtool|plist|xcodegen)"
    ;;
esac

# Optional extra commit paths from config
while IFS= read -r extra; do
  [ -n "$extra" ] && COMMIT_PATHS+=("$extra")
done < <(json_get commitPaths "" 2>/dev/null || true)

TAG="v${VERSION}.${BUILD}"
git rev-parse "$TAG" >/dev/null 2>&1 && die "tag ${TAG} already exists"

DMG_SAFE_NAME="${APP_NAME// /-}"
DMG_PATH="build/${DMG_SAFE_NAME}-${VERSION}.dmg"
mkdir -p build

echo "  ${APP_NAME} ${VERSION} (build ${BUILD}) → ${TAG}"

# ── 3. Tests (optional) ────────────────────────────────────────────────────────
if [ "$RUN_TESTS" = "true" ]; then
  step "Tests"
  set +e
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' test 2>&1 \
    | tee build/test.log \
    | grep -E "Test run with|TEST SUCCEEDED|TEST FAILED|error:" | tail -3
  TEST_STATUS=${PIPESTATUS[0]}
  set -e
  [ "$TEST_STATUS" -eq 0 ] || die "tests failed — not releasing. Full log: build/test.log"
fi

# ── 4. Archive ─────────────────────────────────────────────────────────────────
step "Archiving"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  -allowProvisioningUpdates \
  | grep -E "^(error:|warning:|Archive succeeded)" || true

[ -d "$ARCHIVE_PATH" ] || die "archive not produced"

# ── 5. Export ──────────────────────────────────────────────────────────────────
step "Exporting (Developer ID, team ${TEAM_ID})"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>signingStyle</key><string>automatic</string>
    <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  | grep -E "^(error:|Export succeeded)" || true

APP_PATH=$(find "$EXPORT_PATH" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP_PATH" ] || die "no .app found in ${EXPORT_PATH}"

# ── 6. Verify signature ────────────────────────────────────────────────────────
step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -2

CS_INFO=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1) \
  || die "codesign could not read ${APP_PATH}:
${CS_INFO}"

grep -qE "flags=.*runtime" <<<"$CS_INFO" \
  || die "hardened runtime is not enabled — notarization will reject this"

grep -q "Developer ID Application" <<<"$CS_INFO" \
  || die "app is not signed with Developer ID Application"

echo "  signed, hardened runtime on"

# ── 7. Notarize app (apply only) ───────────────────────────────────────────────
# Staple the app before packing the DMG so the dragged-out bundle has a ticket offline.
if [ "$APPLY" = true ]; then
  step "Notarizing the app (takes a few minutes)"
  APP_ZIP="build/${DMG_SAFE_NAME}-app.zip"
  rm -f "$APP_ZIP"
  ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$APP_ZIP"

  step "Stapling the app"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH" \
    || die "the app has no stapled ticket — it would not launch offline"
fi

# ── 8. DMG ─────────────────────────────────────────────────────────────────────
step "Creating DMG"
APP_BUNDLE=$(basename "$APP_PATH")
rm -f "$STAGING_DMG"
cleanup

APP_SIZE_MB=$(du -sm "$APP_PATH" | awk '{print $1}')
hdiutil create \
  -megabytes $((APP_SIZE_MB + 20)) \
  -volname "${APP_NAME} ${VERSION}" \
  -fs HFS+ -ov "$STAGING_DMG" >/dev/null

hdiutil attach "$STAGING_DMG" -mountpoint "$MOUNT_DIR" -noautoopen -readwrite >/dev/null
cp -R "$APP_PATH" "$MOUNT_DIR/"

BACKGROUND_CLAUSE=""
BG_SRC="$DMG_BACKGROUND"
if [ -z "$BG_SRC" ] && [ -f "Assets/DMGBackground.png" ]; then
  BG_SRC="Assets/DMGBackground.png"
fi
if [ -n "$BG_SRC" ] && [ -f "$BG_SRC" ]; then
  mkdir -p "$MOUNT_DIR/.background"
  cp "$BG_SRC" "$MOUNT_DIR/.background/DMGBackground.png"
  BG_DIR="$(dirname "$BG_SRC")"
  BG_BASE="$(basename "$BG_SRC" .png)"
  [ -f "${BG_DIR}/${BG_BASE}@2x.png" ] && \
    cp "${BG_DIR}/${BG_BASE}@2x.png" "$MOUNT_DIR/.background/DMGBackground@2x.png"
  BACKGROUND_CLAUSE='set background picture of viewOptions to file ".background:DMGBackground.png"'
fi

osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
  set theDisk to disk "${MOUNT_SAFE_NAME}-staging"
  make new alias file to folder "Applications" of startup disk at theDisk
  tell theDisk
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, 540, 400}
    set viewOptions to icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    ${BACKGROUND_CLAUSE}
    set position of item "${APP_BUNDLE}" of container window to {130, 160}
    set position of item "Applications" of container window to {370, 160}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
sleep 1
hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$STAGING_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" -ov >/dev/null
rm -f "$STAGING_DMG"
echo "  ${DMG_PATH}"

if [ "$APPLY" = false ]; then
  echo ""
  echo "✅ Dry run complete — built and signed, nothing notarized or published."
  echo "   DMG: ${DMG_PATH}"
  echo "   Revert the version bump with: git checkout -- ${COMMIT_PATHS[*]}"
  if [ "$VERSION_SOURCE" = "xcodegen" ]; then
    echo "   Then re-run: xcodegen generate"
  fi
  echo "   Full release: $0 --apply"
  exit 0
fi

# ── 9. Notarize DMG ────────────────────────────────────────────────────────────
step "Notarizing the DMG (takes a few minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

step "Stapling the DMG"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1 | tail -2

# ── 10. Minisign ───────────────────────────────────────────────────────────────
[ -n "$MINISIGN_PUB_URL" ] || die "osxr.json missing minisignPublicKeyURL.
       Publish your minisign.pub over HTTPS and set the URL (see /osxr:setup)."

step "Signing SHA256SUMS with minisign"
SUMS_PATH="build/SHA256SUMS"
(
  cd "$(dirname "$DMG_PATH")"
  shasum -a 256 "$(basename "$DMG_PATH")"
) > "$SUMS_PATH"
minisign -Sm "$SUMS_PATH" -s "$MINISIGN_SECRET_KEY" \
  -t "SHA256SUMS for $(basename "$DMG_PATH")"
SIG_PATH="${SUMS_PATH}.minisig"
CHECKSUM=$(awk '{print $1}' "$SUMS_PATH")
echo "  ${SUMS_PATH} + ${SIG_PATH}"

# ── 11. Commit bump, then publish ──────────────────────────────────────────────
step "Committing ${TAG}"
git add "${COMMIT_PATHS[@]}"
git commit -q -m "Release ${TAG}"
git push -q origin "$RELEASE_BRANCH"

step "Publishing GitHub release"
gh release create "$TAG" \
  "$DMG_PATH" \
  "$SUMS_PATH" \
  "$SIG_PATH" \
  --title "${APP_NAME} ${VERSION}" \
  --notes "$(cat <<EOF
SHA-256: ${CHECKSUM}

### Verify checksums

Download \`SHA256SUMS\` and \`SHA256SUMS.minisig\` alongside the DMG.
Public key: ${MINISIGN_PUB_URL}

\`\`\`
minisign -Vm SHA256SUMS -p minisign.pub
shasum -a 256 -c SHA256SUMS
\`\`\`
EOF
)" \
  --generate-notes

echo ""
echo "✅ Released ${TAG}"
echo "   DMG: ${DMG_PATH}"
echo "   Checksums: ${SUMS_PATH} (signed)"
