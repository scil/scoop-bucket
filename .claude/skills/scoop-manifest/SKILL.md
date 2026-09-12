---
name: scoop-manifest
description: Create or update a Scoop bucket manifest (bucket/<app>.json) for a GitHub-released Windows app, install it locally, and commit. Use when the user says "支持 <github url>", "add <app> to scoop bucket", "make a scoop manifest", or "scoop 安装 <app>".
allowed-tools: Bash, PowerShell, Read, Write, Edit
---

# Scoop manifest for a GitHub release

Goal: one probe → one manifest → one install → one commit. Avoid exploratory round-trips.

## Step 1 — Probe (single command)

Run `scripts/probe.ps1 <owner>/<repo>` (path relative to this skill dir). It prints, in one shot:
release tag + asset names/sizes/urls, repo description, license SPDX, content of any `*.sha256`
assets, and — for the primary Windows asset — installer type detection (Inno/NSIS/Squirrel/WiX/MSIX/zip)
plus the computed sha256.

Do NOT `Invoke-WebRequest` for `.sha256` files and print `.Content` raw — it comes back as a byte
array. The script decodes it. If no `.sha256` asset exists, the script downloads the asset and hashes it.

## Step 2 — Pick a strategy by installer type

| Type | Manifest pattern |
|---|---|
| zip / 7z / portable | `url` as-is, `extract_dir` if single top folder, `bin` / `shortcuts` |
| NSIS (`Nullsoft` string) | append `#/dl.7z` to url so scoop extracts with 7zip; `pre_install` removes `$PLUGINSDIR`; `shortcuts` |
| Squirrel `.nupkg` | url `...full.nupkg#/dl.7z`, `extract_dir: lib\\net45` |
| Inno Setup | try `innounp -v file.exe`. If it works: url `...exe#/dl.7z`? No — use `innosetup: true`. If innounp says "corrupted or incompatible version" (new Inno 6.x), fall back to **silent install** pattern below |
| MSI | `msi`-style: scoop extracts via lessmsi automatically; set `extract_dir` from probe output |
| MSIX / appx | not scoop-friendly; tell user |

### Inno Setup silent-install fallback (when innounp can't unpack)

```json
"installer": {
    "script": [
        "$setup = Get-ChildItem \"$dir\\<Prefix>_*.exe\" | Select-Object -First 1",
        "Start-Process $setup.FullName -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', \"/DIR=`\"$dir`\"\") -Wait -Verb RunAs",
        "Remove-Item $setup.FullName -ErrorAction SilentlyContinue"
    ]
},
"uninstaller": {
    "script": [
        "$unins = Get-ChildItem \"$dir\\unins*.exe\" | Select-Object -First 1",
        "if ($unins) { Start-Process $unins.FullName -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -Verb RunAs }"
    ]
}
```
`-Verb RunAs` is needed when the .iss has `PrivilegesRequired=admin` (probe greps this from `installer/*.iss` in the repo if present). Note it in `notes` (UAC prompt).

## Step 3 — Write `bucket/<app>.json`

Follow the existing manifests in the bucket for style (4-space indent, key order:
version, description, homepage, license, architecture, extract_dir/pre_install, bin, shortcuts,
persist, checkver, autoupdate, notes).

- `checkver`: `{ "github": "<repo url>" }`
- `autoupdate.url`: replace the version in the asset url with `$version`. **When followed by `_` or a
  word char use `${version}`** (e.g. `App_Setup_${version}_x64.exe`) — scoop's substitution is literal
  string replace, but `${version}` is unambiguous and matches upstream bucket convention.
- If upstream publishes `<asset>.sha256`, add `"hash": { "url": "$url.sha256" }` under each arch in autoupdate.
- Include `arm64` arch when an asset exists.
- `license`: SPDX id; if `gh repo view` returns null, read `LICENSE` first lines (GPL v3 → `GPL-3.0-only`).
- Framework-dependent apps (WinUI 3 / .NET runtime / WebView2): mention runtime requirement in `notes`.

## Step 4 — Install, verify, commit

```powershell
scoop install "$PWD\bucket\<app>.json"
Test-Path "$(scoop prefix <app>)\<Main>.exe"
git add bucket/<app>.json && git commit -m "feat(bucket): add <app>"
```
Install output is noisy (scoop update log); pipe `| Select -Last 15`. Don't push unless asked.
Version bump commit message: `<app>: Update to version X.Y.Z` (matches Excavator bot).

## Gotchas collected

- `gh release view --json assets` is the fastest asset listing; `gh api repos/../contents/<file> --jq .content` is base64 — decode with `[Convert]::FromBase64String`.
- Detect installer type by searching ASCII strings in the exe (`Inno Setup`, `Nullsoft`, `Squirrel`, `WixToolset`); `Inno Setup` may only appear past the first 300 KB — scan the whole file.
- innounp 2.64 can't unpack Inno 6.4+ installers ("corrupted or incompatible version") → silent-install fallback.
- Inno silent install writes `unins000.exe` into `$dir`; `/NOICONS` prevents duplicate Start Menu entries (scoop creates its own via `shortcuts`).
- `scoop install <local path>` works without adding the bucket; good for testing before commit.
