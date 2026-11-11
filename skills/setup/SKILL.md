---
name: setup
description: Use when a project needs Developer ID + GitHub release tooling for the first time, when an osxr.json is missing, when notary/minisign credentials fail, or when migrating an app's copied Scripts/release.sh onto the shared osxr toolkit.
---

# OSX Release setup

## Overview

One canonical toolkit drives every open-source macOS app release. A project holds
only an **`osxr.json`** (scheme, version strategy, DMG assets) plus its own
assets. The scripts live in this plugin at
`<this skill's base directory>/../../toolkit` — call that `$T` below. Every other
`osxr:*` skill assumes this setup is done.

Secrets live in **`~/.config/osxr/`**, never in a repo.

## Toolkit conventions

- **Dry run is the default.** `$T/release.sh` builds and signs a DMG but does
  **not** notarize, publish, or push. Pass `--apply` only after the user confirms
  in this conversation.
- Run from anywhere inside the project; the script walks up to `osxr.json` (or
  honour `$OSXR_CONFIG`).
- `$T/release.sh --help` documents flags.

## Steps

### 1. Machine secrets directory

```sh
mkdir -p ~/.config/osxr
chmod 700 ~/.config/osxr
```

Place (and `chmod 600`) these files:

| File | Purpose |
|---|---|
| `AuthKey_<KEY_ID>.p8` | App Store Connect API key used by `notarytool` |
| `ciretose.key` | minisign secret for Hash/Check checksum signing |

If keys still live under `~/Code/.private_keys/` or inside a repo, **move** them
here and delete the old copies (especially anything that was ever committed).

Never commit `.p8` or `.key` files. Folder `700`, keys `600`.

### 2. Developer ID Application certificate

Notarization and Gatekeeper require **Developer ID Application**, not
"Apple Development".

1. Xcode › Settings › Accounts › select the team › Manage Certificates
2. `+` › **Developer ID Application**
3. Requires Account Holder or Admin on the Apple Developer team

Verify:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 3. Notary keychain profile (once per machine)

Reuse **one** shared profile for every app (recommended name: `ciretose-notary`).

You need an App Store Connect API key (App Manager role is enough) — Key ID,
Issuer ID, and the `.p8` from step 1:

```sh
xcrun notarytool store-credentials "ciretose-notary" \
  --key ~/.config/osxr/AuthKey_<KEY_ID>.p8 \
  --key-id <KEY_ID> \
  --issuer <ISSUER_ID>
```

Verify:

```sh
xcrun notarytool history --keychain-profile ciretose-notary
```

Per-app profile names (`eyeballs-notary`, …) still work if listed in
`osxr.json` → `notaryProfile`, but prefer consolidating to one.

### 4. Team ID in a gitignored local xcconfig

Releases need `DEVELOPMENT_TEAM` resolved by `xcodebuild`. Pattern varies by
repo — pick the one already in use:

- `Config/Local.xcconfig` (from `Local.xcconfig.template`) — Eyeballs-style
- `Config/Signing.local.xcconfig` — CruftCheck-style

Example:

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Find the Team ID in Apple Developer › Membership, or:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
# Team ID is the 10-char ID in parentheses
```

Confirm:

```sh
xcodebuild -project <Project>.xcodeproj -scheme <Scheme> -showBuildSettings 2>/dev/null \
  | awk '/DEVELOPMENT_TEAM/{print; exit}'
```

### 5. CLI tools

| Tool | Install |
|---|---|
| Xcode / `xcodebuild` / `xcrun` | App Store + CLT |
| `gh` | `brew install gh` then `gh auth login` |
| `minisign` | `brew install minisign` |
| `xcodegen` | only if `versionSource` is `xcodegen`: `brew install xcodegen` |

```sh
gh auth status
command -v minisign
```

### 6. Project `osxr.json`

Copy the example and fill from the real Xcode project — don't guess:

```sh
cp $T/osxr.example.json ./osxr.json
```

Required keys:

| Key | Example | Notes |
|---|---|---|
| `scheme` | `"Eyeballs"` | Xcode scheme name |
| `project` | `"Eyeballs.xcodeproj"` | |
| `appName` | `"Eyeballs"` | Display name / DMG volname |
| `notaryProfile` | `"ciretose-notary"` | Keychain profile from step 3 |
| `versionSource` | `"agvtool"` | `agvtool` \| `plist` \| `xcodegen` |
| `releaseBranch` | `"main"` | Must be clean and synced |

Optional:

| Key | When |
|---|---|
| `dmgBackground` | Path to PNG (default tries `Assets/DMGBackground.png`) |
| `runTests` | `true` if the suite must pass before shipping |
| `infoPlist` | Required for `plist`; recommended verify path for `xcodegen` |
| `projectYml` | For `xcodegen` (default `project.yml`) |
| `minisignPublicKeyURL` | Printed in GitHub release notes |
| `commitPaths` | Extra paths to `git add` with the version bump |

`versionSource` mapping for existing apps:

- **agvtool** — MARKETING_VERSION / CURRENT_PROJECT_VERSION in the pbxproj (Eyeballs)
- **plist** — CFBundleShortVersionString / CFBundleVersion in Info.plist (WiFiCheck-style)
- **xcodegen** — bump `project.yml` then `xcodegen generate` (CruftCheck)

`osxr.json` is committed — it holds no secrets.

### 7. DMG background (optional)

A 440×300-ish PNG at `Assets/DMGBackground.png` (or the path in `dmgBackground`)
gives the drag-to-Applications window a background. Without it, icon layout still
works.

### 8. gitignore

Ensure these are ignored (add if missing):

```
Config/Local.xcconfig
Config/Signing.local.xcconfig
Scripts/ExportOptions.plist
build/
*.p8
*.key
```

Never commit Team ID files that embed a personal team, `.p8`, or minisign secrets.

### 9. Preflight

From the project root:

```sh
$T/release.sh
```

Dry-run should: resolve config, pass preflight, bump build, archive, export,
verify Developer ID + hardened runtime, build a DMG — then exit without
notarizing. Show the user the summary. If preflight fails, fix the cited step
above before continuing.

Revert the version bump after a dry run if you are not shipping:

```sh
git checkout -- <paths the script printed>
```

### 10. Migrating a project with `Scripts/release.sh`

1. Map hard-coded scheme / project / app name / notary profile / version bump
   style into `osxr.json`.
2. Point `dmgBackground` at the existing asset.
3. Run `$T/release.sh` (dry run) and confirm it matches the old script's
   artefacts.
4. On success, delete `Scripts/release.sh` (and any generated ExportOptions that
   are now produced under `build/`).
5. Update README release docs to `/osxr:release` / `$T/release.sh --apply`.

Legacy `NOTARY_PROFILE=…` and `MINISIGN_SECRET_KEY=…` env overrides still work.

## Common mistakes

| Mistake | Fix |
|---|---|
| Only an Apple Development cert | Step 2 — Developer ID Application |
| `.p8` still in the repo or `~/Code/.private_keys/` | Move to `~/.config/osxr/`, chmod 600 |
| Empty `DEVELOPMENT_TEAM` | Step 4 — local xcconfig |
| Wrong `versionSource` | agvtool writes pbxproj; xcodegen apps must use `xcodegen` or the bump vanishes |
| Running `--apply` first | Dry run, show the user, then apply |
| Dirty tree / wrong branch | Commit/stash; be on `releaseBranch` synced with origin |
