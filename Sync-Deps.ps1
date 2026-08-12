#Requires -Version 5.1
<#
.SYNOPSIS
  Sync git dependencies and binaries from a DEPS.json manifest.

.DESCRIPTION
  Reads a JSON file with "dependencies" (git url + commit) and optional
  "binaries" (url + version), then clones/updates repos into SyncDir and
  downloads binaries into BinDir.

.PARAMETER DepsFile
  Path to the dependency JSON file.

.PARAMETER SyncDir
  Directory where git dependencies are cloned (e.g. third_party).

.PARAMETER BinDir
  Directory for binary downloads. Default: <SyncDir>/../bin relative to SyncDir's parent,
  or alongside SyncDir as "bin" under the same parent. Explicitly set when needed.

.PARAMETER Name
  Optional list of dependency/binary names to sync. Omit to sync all.

.PARAMETER DryRun
  Print what would be synced without changing anything.

.EXAMPLE
  .\Sync-Deps.ps1 -DepsFile .\DEPS.json -SyncDir .\third_party

.EXAMPLE
  .\Sync-Deps.ps1 .\DEPS.json .\third_party -BinDir .\bin -Name cli11 zlib -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('Json', 'Deps')]
    [string]$DepsFile,

    [Parameter(Mandatory = $true, Position = 1)]
    [Alias('OutDir', 'Target')]
    [string]$SyncDir,

    [Parameter()]
    [string]$BinDir,

    [Parameter()]
    [Alias('n')]
    [switch]$DryRun,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Cyan', 'Green', 'Yellow', 'Red', 'Gray', 'White')]
        [string]$Color = 'White'
    )
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GitArgs,
        [string]$WorkingDirectory = (Get-Location).Path,
        [switch]$AllowFail
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $WorkingDirectory @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) {
        if ($AllowFail) { return $null }
        $msg = if ($output) { ($output | Out-String).Trim() } else { "git $($GitArgs -join ' ') failed ($code)" }
        throw $msg
    }
    if ($null -eq $output) { return '' }
    return ($output | Out-String).Trim()
}

function Get-RepoCommit {
    param([string]$RepoPath)
    return Invoke-Git -GitArgs @('rev-parse', 'HEAD') -WorkingDirectory $RepoPath -AllowFail
}

function Remove-PathSafe {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Sync-CloneRepo {
    param(
        [string]$Name,
        [string]$Url,
        [string]$Commit,
        [string]$TargetPath
    )
    Write-Log "`n=== Cloning $Name ===" Cyan
    Write-Log "URL: $Url"
    Write-Log ("Commit: {0}..." -f $Commit.Substring(0, [Math]::Min(8, $Commit.Length)))

    Remove-PathSafe $TargetPath
    $parent = Split-Path -Parent $TargetPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-Log 'Cloning (shallow, no checkout)...'
    Invoke-Git -GitArgs @('clone', '--depth', '1', '--no-checkout', $Url, $TargetPath)

    Write-Log ("Fetching commit {0}..." -f $Commit.Substring(0, [Math]::Min(8, $Commit.Length)))
    Invoke-Git -GitArgs @('fetch', '--depth', '1', 'origin', $Commit) -WorkingDirectory $TargetPath

    Write-Log 'Checking out...'
    Invoke-Git -GitArgs @('checkout', 'FETCH_HEAD') -WorkingDirectory $TargetPath

    Write-Log "Cloned $Name" Green
}

function Sync-UpdateRepo {
    param(
        [string]$Name,
        [string]$Url,
        [string]$Commit,
        [string]$TargetPath
    )
    Write-Log "`n=== Updating $Name ===" Cyan
    Write-Log "URL: $Url"
    Write-Log ("Target: {0}..." -f $Commit.Substring(0, [Math]::Min(8, $Commit.Length)))

    $current = Get-RepoCommit $TargetPath
    if ($current -eq $Commit) {
        Write-Log ("Already at {0}, skipping" -f $Commit.Substring(0, [Math]::Min(8, $Commit.Length))) Green
        return
    }

    $curShort = if ($current) { $current.Substring(0, [Math]::Min(8, $current.Length)) } else { 'unknown' }
    Write-Log "Current: $curShort"
    Write-Log 'Updating...'

    try {
        Invoke-Git -GitArgs @('fetch', '--depth', '1', 'origin', $Commit) -WorkingDirectory $TargetPath
        Invoke-Git -GitArgs @('checkout', 'FETCH_HEAD') -WorkingDirectory $TargetPath
        Write-Log "Updated $Name" Green
    } catch {
        Write-Log 'Fetch failed, re-cloning...' Yellow
        Sync-CloneRepo -Name $Name -Url $Url -Commit $Commit -TargetPath $TargetPath
    }
}

function Sync-GitDependency {
    param(
        [string]$Name,
        [psobject]$Config,
        [string]$Root
    )
    $url = [string]$Config.url
    $commit = [string]$Config.commit
    if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($commit)) {
        throw "Dependency '$Name' requires url and commit"
    }

    $targetPath = Join-Path $Root $Name

    if (-not (Test-Path -LiteralPath $targetPath)) {
        Sync-CloneRepo -Name $Name -Url $url -Commit $commit -TargetPath $targetPath
        return
    }

    $gitDir = Join-Path $targetPath '.git'
    if (-not (Test-Path -LiteralPath $gitDir)) {
        Write-Log "`n$Name exists but is not a git repo, re-cloning..." Yellow
        Sync-CloneRepo -Name $Name -Url $url -Commit $commit -TargetPath $targetPath
        return
    }

    Sync-UpdateRepo -Name $Name -Url $url -Commit $commit -TargetPath $targetPath
}

function Sync-BinaryFile {
    param(
        [string]$Name,
        [psobject]$Config,
        [string]$Root
    )
    $url = [string]$Config.url
    $version = [string]$Config.version
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Binary '$Name' requires url"
    }

    $fileName = Split-Path -Leaf ([Uri]$url).LocalPath
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = $Name
    }
    $targetPath = Join-Path $Root $fileName

    Write-Log "`n=== Syncing binary $Name ===" Cyan
    Write-Log "URL: $url"
    Write-Log "Version: $version"
    Write-Log "Target: $targetPath"

    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }

    if (Test-Path -LiteralPath $targetPath) {
        Write-Log 'Already exists, skipping' Green
        return
    }

    Write-Log "Downloading $url..."
    Invoke-WebRequest -Uri $url -OutFile $targetPath -UseBasicParsing
    Write-Log "Downloaded $Name" Green
}

function Get-PropertyNames {
    param([psobject]$Object)
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-NamedEntries {
    param(
        [psobject]$Map,
        [string[]]$Filter
    )
    $result = [ordered]@{}
    if ($null -eq $Map) { return $result }

    $names = Get-PropertyNames $Map
    if ($Filter -and $Filter.Count -gt 0) {
        foreach ($n in $Filter) {
            if ($names -contains $n) {
                $result[$n] = $Map.$n
            }
        }
    } else {
        foreach ($n in $names) {
            $result[$n] = $Map.$n
        }
    }
    return $result
}

# --- main ---

$DepsFile = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DepsFile)
$SyncDir = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SyncDir)

if (-not $BinDir) {
    $BinDir = Join-Path (Split-Path -Parent $SyncDir) 'bin'
} else {
    $BinDir = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BinDir)
}

if (-not (Test-Path -LiteralPath $DepsFile)) {
    Write-Log "DEPS file not found: $DepsFile" Red
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Log 'git is required but not found in PATH' Red
    exit 1
}

$raw = Get-Content -LiteralPath $DepsFile -Raw -Encoding UTF8
$deps = $raw | ConvertFrom-Json

$binaries = Get-NamedEntries -Map $deps.binaries -Filter $Name
$dependencies = Get-NamedEntries -Map $deps.dependencies -Filter $Name

if ($binaries.Count -eq 0 -and $dependencies.Count -eq 0) {
    Write-Log 'No dependencies to process' Yellow
    exit 0
}

Write-Log "`nDepsFile: $DepsFile" Cyan
Write-Log "SyncDir:  $SyncDir" Cyan
Write-Log "BinDir:   $BinDir" Cyan
Write-Log "Syncing $($binaries.Count) binaries..." Cyan
Write-Log "Syncing $($dependencies.Count) dependencies..." Cyan

if ($DryRun) {
    Write-Log '(dry run)' Yellow
    foreach ($key in $binaries.Keys) {
        Write-Log ("`n  binary/{0}: {1}" -f $key, $binaries[$key].version)
    }
    foreach ($key in $dependencies.Keys) {
        $c = [string]$dependencies[$key].commit
        Write-Log ("`n  {0}: {1}" -f $key, $c.Substring(0, [Math]::Min(8, $c.Length)))
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $SyncDir)) {
    New-Item -ItemType Directory -Path $SyncDir -Force | Out-Null
}
if ($binaries.Count -gt 0 -and -not (Test-Path -LiteralPath $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
}

foreach ($key in $binaries.Keys) {
    try {
        Sync-BinaryFile -Name $key -Config $binaries[$key] -Root $BinDir
    } catch {
        Write-Log "Failed to sync binary ${key}: $($_.Exception.Message)" Red
        exit 1
    }
}

foreach ($key in $dependencies.Keys) {
    try {
        Sync-GitDependency -Name $key -Config $dependencies[$key] -Root $SyncDir
    } catch {
        Write-Log "Failed to sync ${key}: $($_.Exception.Message)" Red
        exit 1
    }
}

Write-Log "`n=== Done ===" Green
