#Requires -Version 7
<#
.SYNOPSIS
  One-shot probe of a GitHub repo's latest release for writing a Scoop manifest.
.EXAMPLE
  pwsh scripts/probe.ps1 Tianyu199509/DeskBox
  pwsh scripts/probe.ps1 owner/repo -Asset 'x64.exe'   # substring to pick the asset to inspect
#>
param(
    [Parameter(Mandatory)][string]$Repo,
    [string]$Asset = '',
    [switch]$NoDownload
)
$ErrorActionPreference = 'Stop'

'== REPO =='
gh repo view $Repo --json description,licenseInfo,url --jq '{description,license:.licenseInfo.spdxId,url}'
if (-not (gh repo view $Repo --json licenseInfo --jq .licenseInfo.spdxId)) {
    'LICENSE head:'
    try { gh api "repos/$Repo/contents/LICENSE" --jq .content | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) } | Select-Object -First 3 } catch { '  (no LICENSE file)' }
}

'== RELEASE =='
$rel = gh release view --repo $Repo --json tagName,assets | ConvertFrom-Json
"tag: $($rel.tagName)"
$rel.assets | ForEach-Object { '  {0,-60} {1,8:N1} MB' -f $_.name, ($_.size / 1MB) }

'== SHA256 ASSETS =='
$rel.assets | Where-Object name -match '\.(sha256|sha256sum|txt)$' | ForEach-Object {
    $bytes = (Invoke-WebRequest $_.url).Content
    if ($bytes -is [byte[]]) { $bytes = [Text.Encoding]::ASCII.GetString($bytes) }
    "  [$($_.name)]"; $bytes.Trim() -split "`n" | ForEach-Object { "    $_" }
}

'== INSTALLER .iss (if any) =='
try {
    $issFiles = @(gh api "repos/$Repo/contents/installer" --jq '.[]|select(.name|endswith(".iss"))|.path' 2>$null)
    if ($issFiles) {
        foreach ($iss in $issFiles) {
            "  [$iss]"
            $c = gh api "repos/$Repo/contents/$iss" --jq .content | Out-String | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($_ -replace '\s', ''))) }
            $c -split "`r?`n" | Select-String -Pattern '^\s*(AppName|AppId|DefaultDirName|PrivilegesRequired|ArchitecturesAllowed|OutputBaseFilename)\s*=' | ForEach-Object { "    $($_.Line.Trim())" }
        }
    } else { '  none' }
} catch { '  none' }

'== PRIMARY ASSET INSPECTION =='
$pick = $rel.assets | Where-Object { $_.name -notmatch '\.(sha256|txt|sig|asc|yml|blockmap)$' }
if ($Asset) { $pick = $pick | Where-Object name -like "*$Asset*" }
$pick = $pick | Where-Object name -match 'x64|x86_64|amd64|win' | Select-Object -First 1
if (-not $pick) { $pick = $rel.assets | Select-Object -First 1 }
"asset: $($pick.name)"
"url:   $($pick.url)"
if ($NoDownload) { return }

$tmp = Join-Path $env:TEMP "scoop-probe-$($pick.name)"
if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -ne $pick.size) { Invoke-WebRequest $pick.url -OutFile $tmp }
"sha256: $((Get-FileHash $tmp).Hash.ToLower())"

if ($pick.name -match '\.exe$') {
    $t = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($tmp))
    $kinds = [ordered]@{ 'Inno Setup' = 'Inno Setup'; 'NSIS' = 'Nullsoft'; 'Squirrel' = 'Squirrel'; 'WiX' = 'WixToolset'; 'Velopack' = 'Velopack'; '7z-SFX' = '7-Zip' }
    'installer strings:'
    $kinds.GetEnumerator() | ForEach-Object { '  {0,-12} {1}' -f $_.Key, $t.Contains($_.Value) }
    $vi = (Get-Item $tmp).VersionInfo
    "product: $($vi.ProductName) | company: $($vi.CompanyName) | version: $($vi.ProductVersion)"
    if ($t.Contains('Inno Setup')) {
        'innounp test:'
        if (Get-Command innounp -ErrorAction SilentlyContinue) {
            $out = innounp -v $tmp 2>&1 | Select-Object -First 25
            $out | ForEach-Object { "  $_" }
        } else { '  innounp not installed (scoop install innounp)' }
    }
} elseif ($pick.name -match '\.(zip|7z)$') {
    'top-level entries:'
    7z l -ba -slt $tmp 2>$null | Select-String '^Path = ' | ForEach-Object { ($_ -replace '^Path = ', '') -split '[\\/]' | Select-Object -First 1 } | Sort-Object -Unique | Select-Object -First 15 | ForEach-Object { "  $_" }
} elseif ($pick.name -match '\.msi$') {
    'msi: scoop extracts with lessmsi; check extract_dir after a test install'
}
"local file: $tmp"
