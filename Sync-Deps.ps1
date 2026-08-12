#Requires -Version 5.1
<#
.SYNOPSIS
  Sync git / zip / 7z dependencies and binaries from a DEPS.json manifest.

.DESCRIPTION
  Reads a JSON file with "dependencies" and optional "binaries", then syncs into
  SyncDir / BinDir.

  Dependency mode is chosen from the URL path suffix:
    - *.zip  → download and extract zip into SyncDir
    - *.7z   → download and extract 7z into SyncDir (requires 7-Zip)
    - else   → git shallow clone + checkout (requires commit)

.PARAMETER DepsFile
  Path to the dependency JSON file.

.PARAMETER SyncDir
  Directory where dependencies are placed (e.g. third_party).

.PARAMETER BinDir
  Directory for binary downloads and archive cache.
  Default: <SyncDir parent>/bin.

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

function Get-UrlLeaf {
    param([string]$Url)
    try {
        $leaf = Split-Path -Leaf ([Uri]$Url).AbsolutePath
        if (-not [string]::IsNullOrWhiteSpace($leaf)) { return $leaf }
    } catch { }
    return [string]$Url
}

function Get-DependencyMode {
    param([string]$Url)
    $leaf = (Get-UrlLeaf $Url).ToLowerInvariant()
    if ($leaf.EndsWith('.7z')) { return '7z' }
    if ($leaf.EndsWith('.zip')) { return 'zip' }
    return 'git'
}

function Get-7zExe {
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
            'C:\Program Files\7-Zip\7z.exe',
            'C:\Program Files (x86)\7-Zip\7z.exe'
        )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Expand-DepArchive {
    param(
        [string]$ArchivePath,
        [string]$DestDir,
        [ValidateSet('zip', '7z')]
        [string]$Format
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-sync-deps-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        if ($Format -eq '7z') {
            $sevenZip = Get-7zExe
            if (-not $sevenZip) {
                throw '7-Zip not found (install 7-Zip or add 7z to PATH)'
            }
            & $sevenZip x -y ("-o" + $tmp) $ArchivePath | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "7z extraction failed (exit $LASTEXITCODE)"
            }
        } else {
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $tmp -Force
        }

        $dirs = @(Get-ChildItem -LiteralPath $tmp -Directory)
        $files = @(Get-ChildItem -LiteralPath $tmp -File)
        $source = $tmp
        if ($dirs.Count -eq 1 -and $files.Count -eq 0) {
            $source = $dirs[0].FullName
        }

        $parent = Split-Path -Parent $DestDir
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Remove-PathSafe $DestDir
        if ($source -eq $tmp) {
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
            Get-ChildItem -LiteralPath $tmp | Move-Item -Destination $DestDir
        } else {
            Move-Item -LiteralPath $source -Destination $DestDir
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
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

function Get-ConfigString {
    param(
        [psobject]$Config,
        [string]$Name
    )
    if ($null -eq $Config) { return '' }
    if ($Config.PSObject.Properties.Name -notcontains $Name) { return '' }
    return [string]$Config.$Name
}

function Sync-GitDependency {
    param(
        [string]$Name,
        [psobject]$Config,
        [string]$Root
    )
    $url = Get-ConfigString $Config 'url'
    $commit = Get-ConfigString $Config 'commit'
    if ([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($commit)) {
        throw "Dependency '$Name' (git) requires url and commit"
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

function Sync-ArchiveDependency {
    param(
        [string]$Name,
        [psobject]$Config,
        [string]$Root,
        [string]$CacheDir,
        [ValidateSet('zip', '7z')]
        [string]$Format
    )
    $url = Get-ConfigString $Config 'url'
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Dependency '$Name' ($Format) requires url"
    }

    $extractTo = Get-ConfigString $Config 'extract_to'
    if ([string]::IsNullOrWhiteSpace($extractTo)) {
        $extractTo = $Name
    }
    $targetPath = Join-Path $Root $extractTo
    $markerPath = Join-Path $targetPath '.ps_sync_deps_url'
    $fileName = Get-UrlLeaf $url
    $cachePath = Join-Path $CacheDir $fileName

    Write-Log "`n=== Extracting $Name ($Format) ===" Cyan
    Write-Log "URL: $url"
    Write-Log "Target: $targetPath"

    if ((Test-Path -LiteralPath $targetPath) -and (Test-Path -LiteralPath $markerPath)) {
        $recorded = (Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8).Trim()
        if ($recorded -eq $url) {
            Write-Log 'Already extracted, skipping' Green
            return
        }
    }

    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $cachePath)) {
        Write-Log "Downloading $url..."
        Invoke-WebRequest -Uri $url -OutFile $cachePath -UseBasicParsing
    } else {
        Write-Log "Using cached archive: $cachePath"
    }

    Write-Log "Extracting $Format -> $targetPath..."
    Expand-DepArchive -ArchivePath $cachePath -DestDir $targetPath -Format $Format
    Set-Content -LiteralPath $markerPath -Value $url -Encoding UTF8 -NoNewline
    Write-Log "Extracted $Name" Green
}

function Sync-Dependency {
    param(
        [string]$Name,
        [psobject]$Config,
        [string]$Root,
        [string]$CacheDir
    )
    $url = Get-ConfigString $Config 'url'
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Dependency '$Name' requires url"
    }

    $mode = Get-DependencyMode $url
    switch ($mode) {
        'git' {
            Sync-GitDependency -Name $Name -Config $Config -Root $Root
        }
        'zip' {
            Sync-ArchiveDependency -Name $Name -Config $Config -Root $Root -CacheDir $CacheDir -Format zip
        }
        '7z' {
            Sync-ArchiveDependency -Name $Name -Config $Config -Root $Root -CacheDir $CacheDir -Format 7z
        }
        default {
            throw "Dependency '$Name': unknown mode '$mode'"
        }
    }
}

function Sync-BinaryFile {
    param(
        [string]$Name,
        [psobject]$Config,
        [string]$Root
    )
    $url = Get-ConfigString $Config 'url'
    $version = Get-ConfigString $Config 'version'
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Binary '$Name' requires url"
    }

    $fileName = Get-UrlLeaf $url
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

function Test-HasGitDependency {
    param([System.Collections.IDictionary]$Dependencies)
    foreach ($key in $Dependencies.Keys) {
        $url = Get-ConfigString $Dependencies[$key] 'url'
        if ((Get-DependencyMode $url) -eq 'git') {
            return $true
        }
    }
    return $false
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

$raw = Get-Content -LiteralPath $DepsFile -Raw -Encoding UTF8
$deps = $raw | ConvertFrom-Json

$binariesMap = $null
$dependenciesMap = $null
if ($deps.PSObject.Properties.Name -contains 'binaries') {
    $binariesMap = $deps.binaries
}
if ($deps.PSObject.Properties.Name -contains 'dependencies') {
    $dependenciesMap = $deps.dependencies
}

$binaries = Get-NamedEntries -Map $binariesMap -Filter $Name
$dependencies = Get-NamedEntries -Map $dependenciesMap -Filter $Name

if ($binaries.Count -eq 0 -and $dependencies.Count -eq 0) {
    Write-Log 'No dependencies to process' Yellow
    exit 0
}

if ((Test-HasGitDependency $dependencies) -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Log 'git is required for git dependencies but not found in PATH' Red
    exit 1
}

Write-Log "`nDepsFile: $DepsFile" Cyan
Write-Log "SyncDir:  $SyncDir" Cyan
Write-Log "BinDir:   $BinDir" Cyan
Write-Log "Syncing $($binaries.Count) binaries..." Cyan
Write-Log "Syncing $($dependencies.Count) dependencies..." Cyan

if ($DryRun) {
    Write-Log '(dry run)' Yellow
    foreach ($key in $binaries.Keys) {
        Write-Log ("`n  binary/{0}: {1}" -f $key, (Get-ConfigString $binaries[$key] 'version'))
    }
    foreach ($key in $dependencies.Keys) {
        $cfg = $dependencies[$key]
        $url = Get-ConfigString $cfg 'url'
        $mode = Get-DependencyMode $url
        if ($mode -eq 'git') {
            $c = Get-ConfigString $cfg 'commit'
            $short = if ($c) { $c.Substring(0, [Math]::Min(8, $c.Length)) } else { '(missing commit)' }
            Write-Log ("`n  {0} [git]: {1}" -f $key, $short)
        } else {
            $extractTo = Get-ConfigString $cfg 'extract_to'
            if ([string]::IsNullOrWhiteSpace($extractTo)) { $extractTo = $key }
            Write-Log ("`n  {0} [{1}]: extract_to={2}" -f $key, $mode, $extractTo)
        }
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $SyncDir)) {
    New-Item -ItemType Directory -Path $SyncDir -Force | Out-Null
}
$needBinDir = ($binaries.Count -gt 0)
if (-not $needBinDir) {
    foreach ($key in $dependencies.Keys) {
        if ((Get-DependencyMode (Get-ConfigString $dependencies[$key] 'url')) -ne 'git') {
            $needBinDir = $true
            break
        }
    }
}
if ($needBinDir -and -not (Test-Path -LiteralPath $BinDir)) {
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
        Sync-Dependency -Name $key -Config $dependencies[$key] -Root $SyncDir -CacheDir $BinDir
    } catch {
        Write-Log "Failed to sync ${key}: $($_.Exception.Message)" Red
        exit 1
    }
}

Write-Log "`n=== Done ===" Green
