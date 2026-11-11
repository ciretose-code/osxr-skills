# osxr-skills

Claude Code / Cursor skills for **Developer ID** signing, notarization, and
**GitHub** releases of open-source macOS apps — backed by one shared toolkit.

Every app keeps only an `osxr.json` (scheme, version strategy, DMG paths) and its
own assets. The scripts live here, so a fix reaches every app at once instead of
drifting across per-project `Scripts/release.sh` copies.

For App Store Connect, use [asc-skills](https://github.com/ciretose-code/asc-skills).

## Install

```
/plugin marketplace add ciretose-code/osxr-skills     # or a local path to this repo
/plugin install osxr@osxr-skills
```

Then, once per machine: put the notary `.p8` and **your** minisign secret in
`~/.config/osxr/` (see `/osxr:setup` — including how to generate a keypair).
In each project, run `/osxr:setup`.

## Skills

| Skill | For |
|---|---|
| `/osxr:setup` | Credentials under `~/.config/osxr/`, Developer ID cert, minisign keypair, `osxr.json`, migrating `Scripts/release.sh` |
| `/osxr:release` | Archive, notarize, DMG, minisign, GitHub release |
| `/osxr:screenshots` | README / GitHub Mac screenshots (not App Store) |

## Toolkit

`$T` = this repo's `toolkit/`.

| Script | Does |
|---|---|
| `release.sh` | Full pipeline. **Dry run by default**; `--apply` notarizes and publishes |

```sh
$T/release.sh --help    # flags and env overrides
$T/release.sh           # build + sign + DMG only
$T/release.sh --apply   # notarize, minisign, gh release, push
$T/release.sh 1.2 --apply
```

## Credentials

| Need | Location |
|---|---|
| Notary API `.p8` | `~/.config/osxr/AuthKey_<KEY_ID>.p8` |
| Notary profile | keychain, e.g. `osxr-notary` |
| minisign secret | `~/.config/osxr/minisign.key` (you generate this) |
| minisign public | host `minisign.pub` at a URL; set `minisignPublicKeyURL` in `osxr.json` |
| Team ID | gitignored local xcconfig in each app |
| GitHub | `gh auth` |

## Per-app config

Copy `toolkit/osxr.example.json` → `osxr.json` at the project root. Commit it.
See `/osxr:setup` for every field and prerequisite.
