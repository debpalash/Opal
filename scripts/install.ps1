<#
.SYNOPSIS
  Opal — official one-command installer / updater / uninstaller for Windows.

.DESCRIPTION
  install.sh is a POSIX sh script and is the wrong tool on Windows, so it refuses
  to run there and tells you to go download the .msi by hand. This is the missing
  half: the same one-command install, in the shell Windows actually has.

    irm https://raw.githubusercontent.com/debpalash/Opal/main/scripts/install.ps1 | iex

  Every download is verified against the release's SHA256SUMS.txt, exactly as the
  sh installer does.

.PARAMETER Command
  install (default) | update | uninstall | list-versions

.PARAMETER Version
  Pin a release, e.g. -Version v0.3.0. Defaults to the latest.

.PARAMETER Portable
  Unzip the portable build to %LOCALAPPDATA%\Programs\Opal instead of running the
  .msi. No admin rights needed, nothing written to the registry.
#>
[CmdletBinding()]
param(
    [ValidateSet('install', 'update', 'uninstall', 'list-versions')]
    [string]$Command = 'install',
    [string]$Version,
    [switch]$Portable
)

$ErrorActionPreference = 'Stop'

$Repo = 'debpalash/Opal'
$Api  = "https://api.github.com/repos/$Repo"
$Dl   = "https://github.com/$Repo/releases/download"

# Resolve the roots defensively. `Join-Path $env:APPDATA 'opal'` throws
# "Cannot bind argument to parameter 'Path' because it is null" the moment APPDATA
# is unset — and because these are top-level, that killed the ENTIRE script at load
# time, including `list-versions`, which needs neither path.
$AppDataRoot = if ($env:APPDATA)      { $env:APPDATA }
               elseif ($env:HOME)     { Join-Path $env:HOME '.config' }
               else                   { [System.IO.Path]::GetTempPath() }
$LocalRoot   = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $AppDataRoot }

$StateDir   = Join-Path $AppDataRoot 'opal'
$Receipt    = Join-Path $StateDir '.install-method'
$PortableIn = Join-Path $LocalRoot (Join-Path 'Programs' 'Opal')

function Say  { param($m) Write-Host "> opal " -ForegroundColor Magenta -NoNewline; Write-Host $m }
function Die  { param($m) Write-Host "x opal " -ForegroundColor Red -NoNewline; Write-Host $m; exit 1 }

function Resolve-Version {
    if ($Version) { $v = $Version }
    else {
        try { $v = (Invoke-RestMethod -Uri "$Api/releases/latest" -Headers @{ 'User-Agent' = 'opal-installer' }).tag_name }
        catch { Die "could not resolve the latest release (rate limit? no network?)" }
    }
    if (-not $v.StartsWith('v')) { $v = "v$v" }
    Say "version: $v"
    return $v
}

# Download an asset and verify it against the release's SHA256SUMS.txt. A silent
# corrupt/truncated download that then gets executed is exactly what a checksum is
# for, so a missing sum is a warning and a WRONG sum is fatal.
function Get-Asset {
    param([string]$Tag, [string]$Asset, [string]$Dest)

    Say "downloading $Asset"
    try { Invoke-WebRequest -Uri "$Dl/$Tag/$Asset" -OutFile $Dest -UseBasicParsing }
    catch { Die "download failed: $Asset" }

    $sumsPath = Join-Path ([System.IO.Path]::GetTempPath()) 'opal-SHA256SUMS.txt'
    try { Invoke-WebRequest -Uri "$Dl/$Tag/SHA256SUMS.txt" -OutFile $sumsPath -UseBasicParsing }
    catch { Say "warning: no SHA256SUMS.txt — skipping verification"; return }

    # Format is "<sha256>  <filename>" (two spaces).
    $line = Select-String -Path $sumsPath -Pattern ([regex]::Escape($Asset) + '$') | Select-Object -First 1
    if (-not $line) { Say "warning: $Asset not in SHA256SUMS.txt — skipping verification"; return }

    $want = ($line.Line -split '\s+')[0]
    $got  = (Get-FileHash -Path $Dest -Algorithm SHA256).Hash
    if ($want -ine $got) { Die "checksum mismatch for $Asset (expected $want, got $got)" }
    Say 'sha256 verified'
}

function Write-Receipt {
    param([string]$Method, [string]$Tag)
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    "$Method $Tag" | Set-Content -Path $Receipt -Encoding ascii
}

function Install-Opal {
    if ([System.Environment]::Is64BitOperatingSystem -eq $false) {
        Die 'Opal ships 64-bit builds only'
    }
    $tag = Resolve-Version
    $ver = $tag.TrimStart('v')
    $tmp = [System.IO.Path]::GetTempPath()

    if ($Portable) {
        # NB: the release names the zip lowercase 'opal-' but the msi 'Opal-'.
        $asset = "opal-$ver-windows-x86_64.zip"
        $zip   = Join-Path $tmp $asset
        Get-Asset -Tag $tag -Asset $asset -Dest $zip

        if (Test-Path $PortableIn) { Remove-Item -Recurse -Force $PortableIn }
        New-Item -ItemType Directory -Force -Path $PortableIn | Out-Null
        Expand-Archive -Path $zip -DestinationPath $PortableIn -Force

        # Put it on PATH for the user (no admin, no registry beyond the user env).
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$PortableIn*") {
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$PortableIn", 'User')
            Say "added $PortableIn to your PATH (restart the terminal)"
        }
        Write-Receipt -Method "portable:$PortableIn" -Tag $tag
        Say "installed -> $PortableIn"
        return
    }

    $asset = "Opal-$ver-windows-x86_64.msi"
    $msi   = Join-Path $tmp $asset
    Get-Asset -Tag $tag -Asset $asset -Dest $msi

    Say 'running the installer (UAC prompt may appear)'
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/passive', '/norestart') -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Die "msiexec failed with exit code $($p.ExitCode) — try -Portable for a no-admin install"
    }
    Write-Receipt -Method 'msi' -Tag $tag
    Say 'done — launch Opal from the Start menu'
}

function Uninstall-Opal {
    if (-not (Test-Path $Receipt)) { Die "no install receipt at $Receipt — was Opal installed by this script?" }
    $method = (Get-Content $Receipt -Raw).Split(' ')[0]

    if ($method -like 'portable:*') {
        $dir = $method.Substring('portable:'.Length)
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        [Environment]::SetEnvironmentVariable(
            'Path', (($userPath -split ';' | Where-Object { $_ -and $_ -ne $dir }) -join ';'), 'User')
        Say "removed $dir"
    }
    elseif ($method -eq 'msi') {
        $app = Get-WmiObject -Class Win32_Product -Filter "Name = 'Opal'" -ErrorAction SilentlyContinue
        if (-not $app) { Die 'Opal is not registered with the Windows installer' }
        $app.Uninstall() | Out-Null
        Say 'uninstalled'
    }
    else { Die "unknown install method in receipt: $method" }

    Remove-Item -Force $Receipt -ErrorAction SilentlyContinue
}

function Get-Versions {
    $rels = Invoke-RestMethod -Uri "$Api/releases" -Headers @{ 'User-Agent' = 'opal-installer' }
    Say 'released versions:'
    $rels | ForEach-Object { Write-Host "  $($_.tag_name)" }
}

switch ($Command) {
    'install'       { Install-Opal }
    'update'        { Install-Opal }   # same path — always converges on the requested version
    'uninstall'     { Uninstall-Opal }
    'list-versions' { Get-Versions }
}
