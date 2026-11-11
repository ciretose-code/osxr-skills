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

Never commit `.p8` or `.key` files. Folder `700`, keys `600`.

If secrets still live under `~/Code/.private_keys/` or inside a repo, **move**
them here and delete the old copies.

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

### 3. Notary API key + keychain profile (once per machine)

You need an App Store Connect API key (App Manager role is enough): Key ID,
Issuer ID, and the downloaded `.p8`.

```sh
# Keep the private key only under ~/.config/osxr/
mv ~/Downloads/AuthKey_<KEY_ID>.p8 ~/.config/osxr/
chmod 600 ~/.config/osxr/AuthKey_<KEY_ID>.p8

# One shared profile for every app on this machine
xcrun notarytool store-credentials "osxr-notary" \
  --key ~/.config/osxr/AuthKey_<KEY_ID>.p8 \
  --key-id <KEY_ID> \
  --issuer <ISSUER_ID>
```

Verify:

```sh
xcrun notarytool history --keychain-profile osxr-notary
```

Put `"notaryProfile": "osxr-notary"` in each app's `osxr.json`. Legacy per-app
profile names still work if you keep them in config.

### 4. Minisign keypair (release checksum signing)

Each release attaches `SHA256SUMS` + `SHA256SUMS.minisig` so downloaders (and
apps like Hash/Check) can verify the DMG. You need **your own** keypair — never
reuse someone else's secret key, and never put a vendor-specific key name in the
toolkit.

**Create once per publisher** (password-protect the secret):

```sh
brew install minisign   # if needed

# Writes minisign.key (secret) + minisign.pub (public) into ~/.config/osxr/
cd ~/.config/osxr
minisign -G -p minisign.pub -s minisign.key
chmod 600 minisign.key
chmod 644 minisign.pub
```

- **`minisign.key`** — stays on this machine only (`~/.config/osxr/`, mode `600`).
  Override path with `MINISIGN_SECRET_KEY` or `osxr.json` → `minisignSecretKey`
  if you prefer another filename.
- **`minisign.pub`** — safe to publish. Host it at a stable HTTPS URL you control
  (personal site, GitHub raw URL, etc.).

**Publish the public key**, then put that URL in every app's `osxr.json`:

```json
"minisignPublicKeyURL": "https://example.com/minisign.pub"
```

Release notes will tell downloaders to verify with that URL.

**What users do to verify** (document in the app README if you want):

1. Download the DMG, `SHA256SUMS`, and `SHA256SUMS.minisig` from the GitHub release.
2. Fetch your published `.pub`.
3. Either:
   - Open them in **Hash/Check** (or similar), or
   - CLI: `minisign -Vm SHA256SUMS -p minisign.pub` then
     `shasum -a 256 -c SHA256SUMS`.

Do **not** commit `minisign.key`. Committing `minisign.pub` in a docs folder is
optional if you also host it at the URL above.

### 5. Team ID in a gitignored local xcconfig

Releases need `DEVELOPMENT_TEAM` resolved by `xcodebuild`. Pattern varies by
repo — pick the one already in use:

- `Config/Local.xcconfig` (from `Local.xcconfig.template`)
- `Config/Signing.local.xcconfig`

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

### 6. CLI tools

| Tool | Install |
|---|---|
| Xcode / `xcodebuild` / `xcrun` | App Store + CLT |
| `gh` | `brew install gh` then `gh auth login` |
| `minisign` | `brew install minisign` (step 4) |
| `xcodegen` | only if `versionSource` is `xcodegen`: `brew install xcodegen` |

```sh
gh auth status
command -v minisign
```

### 7. Project `osxr.json`

Copy the example and fill from the real Xcode project — don't guess:

```sh
cp $T/osxr.example.json ./osxr.json
```

Required keys:

| Key | Example | Notes |
|---|---|---|
| `scheme` | `"MyApp"` | Xcode scheme name |
| `project` | `"MyApp.xcodeproj"` | |
| `appName` | `"My App"` | Display name / DMG volname |
| `notaryProfile` | `"osxr-notary"` | Keychain profile from step 3 |
| `versionSource` | `"agvtool"` | `agvtool` \| `plist` \| `xcodegen` |
| `releaseBranch` | `"main"` | Must be clean and synced |
| `minisignPublicKeyURL` | `"https://example.com/minisign.pub"` | Your published `.pub` (step 4) |

Optional:

| Key | When |
|---|---|
| `dmgBackground` | Path to PNG (default tries `Assets/DMGBackground.png`) |
| `runTests` | `true` if the suite must pass before shipping |
| `infoPlist` | Required for `plist`; recommended verify path for `xcodegen` |
| `projectYml` | For `xcodegen` (default `project.yml`) |
| `minisignSecretKey` | Override secret path (default `~/.config/osxr/minisign.key`) |
| `commitPaths` | Extra paths to `git add` with the version bump |

`versionSource` mapping:

- **agvtool** — MARKETING_VERSION / CURRENT_PROJECT_VERSION in the pbxproj
- **plist** — CFBundleShortVersionString / CFBundleVersion in Info.plist
- **xcodegen** — bump `project.yml` then `xcodegen generate`

`osxr.json` is committed — it holds no secrets. The public key **URL** is fine to
commit; the secret key file is not.

### 8. DMG background (optional)

A 440×300-ish PNG at `Assets/DMGBackground.png` (or the path in `dmgBackground`)
gives the drag-to-Applications window a background. Without it, icon layout still
works.

### 9. gitignore

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

### 10. Preflight

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

### 11. Migrating a project with `Scripts/release.sh`

1. Map hard-coded scheme / project / app name / notary profile / version bump
   style into `osxr.json`.
2. Point `dmgBackground` at the existing asset.
3. Set `minisignPublicKeyURL` to **your** published `.pub` URL (not a copied
   vendor URL from another project's script).
4. Point the secret at `~/.config/osxr/minisign.key` (move/rename any old
   private key file into that path).
5. Run `$T/release.sh` (dry run) and confirm it matches the old script's
   artefacts.
6. On success, delete `Scripts/release.sh` (and any generated ExportOptions that
   are now produced under `build/`).
7. Update README release docs to `/osxr:release` / `$T/release.sh --apply`.

Legacy `NOTARY_PROFILE=…` and `MINISIGN_SECRET_KEY=…` env overrides still work.

## Common mistakes

| Mistake | Fix |
|---|---|
| Only an Apple Development cert | Step 2 — Developer ID Application |
| `.p8` or `.key` still in the repo | Move to `~/.config/osxr/`, chmod 600 |
| Missing / unpublished `minisign.pub` | Step 4 — generate, host URL, set `minisignPublicKeyURL` |
| Empty `DEVELOPMENT_TEAM` | Step 5 — local xcconfig |
| Wrong `versionSource` | agvtool writes pbxproj; xcodegen apps must use `xcodegen` or the bump vanishes |
| Running `--apply` first | Dry run, show the user, then apply |
| Dirty tree / wrong branch | Commit/stash; be on `releaseBranch` synced with origin |
