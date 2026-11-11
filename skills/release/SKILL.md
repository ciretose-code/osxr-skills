---
name: release
description: Use when shipping a Developer ID signed macOS app to GitHub — bumping version/build, archiving, notarizing, stapling, packaging a DMG, signing checksums with minisign, or creating a GitHub release.
---

# Releasing to GitHub (Developer ID)

## Overview

`$T/release.sh` is the whole pipeline. `$T` =
`<this skill's base directory>/../../toolkit`. Requires osxr:setup (`osxr.json`
+ `~/.config/osxr/` credentials). Flags: `$T/release.sh --help`.

## Workflow

1. **Confirm the project has `osxr.json`.** If missing, run osxr:setup first.
2. **Working tree:** on `releaseBranch` (from config, usually `main`), clean, and
   synced with `origin`. The script enforces this — fix before retrying.
3. **Dry run (default):**
   ```sh
   $T/release.sh
   # optional marketing version:
   $T/release.sh 1.2
   ```
   Builds archive → Developer ID export → signature checks → DMG. Skips
   notarize, GitHub publish, and push. Show the user the DMG path and the
   "revert version bump" lines.
4. **Screenshots?** If README or release notes need fresh shots, osxr:screenshots
   before `--apply` (optional).
5. **Apply — only on the user's explicit go-ahead in this conversation.**
   ```sh
   $T/release.sh --apply
   # or:
   $T/release.sh 1.2 --apply
   ```
   Notarizes + staples the app, builds DMG, notarizes + staples the DMG,
   minisign-signs `SHA256SUMS`, commits the version bump, pushes, creates the
   GitHub release with DMG + checksums.

## What the script does

| Step | Dry run | `--apply` |
|---|---|---|
| Preflight (cert, team, branch, tools, minisign key) | yes | yes (+ notary profile) |
| Bump build (`versionSource`) | yes | yes |
| Tests if `runTests: true` | yes | yes |
| Archive + Developer ID export | yes | yes |
| codesign / hardened runtime checks | yes | yes |
| Notarize + staple `.app` | no | yes |
| DMG (Applications alias + optional background) | yes | yes |
| Notarize + staple DMG | no | yes |
| SHA256SUMS + minisign | no | yes |
| Commit bump, push, `gh release create` | no | yes |

## Version sources (`osxr.json` → `versionSource`)

- **`agvtool`** — `agvtool next-version`; optional `agvtool new-marketing-version`
- **`plist`** — bumps `infoPlist` CFBundleVersion (+ short version if passed)
- **`xcodegen`** — edits `projectYml`, runs `xcodegen generate`

Tag format: `v{MARKETING_VERSION}.{BUILD}`.

## Env overrides

- `NOTARY_PROFILE` — keychain profile name
- `MINISIGN_SECRET_KEY` — default `~/.config/osxr/minisign.key` (or `osxr.json` → `minisignSecretKey`)
- `minisignPublicKeyURL` in `osxr.json` — required for `--apply` (your published `.pub`)
- `OSXR_CONFIG` — path to `osxr.json` if not walking up from cwd

## Common mistakes

| Symptom | Fix |
|---|---|
| `no osxr.json found` | osxr:setup |
| `no Developer ID Application certificate` | osxr:setup step 2 |
| `DEVELOPMENT_TEAM is empty` | local xcconfig (osxr:setup step 4) |
| `no notary keychain profile` | osxr:setup step 3; only required for `--apply` |
| `tag already exists` | bump already shipped, or failed mid-flight — inspect `git tag` / `gh release list` |
| Dry-run left a version bump | `git checkout --` the paths the script printed |

## After a successful `--apply`

Paste the release URL (`gh release view <tag> --web`) for the user. Do not
retag or re-run `--apply` for the same build without an explicit request.
