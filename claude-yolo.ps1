# * ********************************************************************************************************* *
# *
# * Copyright 2026 Oidis
# *
# * SPDX-License-Identifier: BSD-3-Clause
# * The BSD-3-Clause license for this file can be found in the LICENSE.txt file included with this distribution
# * or at https://spdx.org/licenses/BSD-3-Clause.html#licenseText
# *
# * ********************************************************************************************************* *

param(
    [switch]$Silent,
    [Parameter(Position = 0)]
    [string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'

$ScriptPath = $MyInvocation.MyCommand.Definition
while ((Get-Item $ScriptPath).LinkType -eq 'SymbolicLink') {
    $ScriptPath = (Get-Item $ScriptPath).Target
}
$ScriptDir = Split-Path -Parent $ScriptPath

$ImageRepo = 'claude-yolo'
$GlobalDir = Join-Path $ScriptDir '.claude-cache'
$ProjectDir = Join-Path (Get-Location).Path '.claude-cache'
$RegistryDir = Join-Path $env:USERPROFILE '.claude-yolo'
$RegistryFile = Join-Path $RegistryDir 'registry.json'
$ProjectConfig = Join-Path $ProjectDir 'config.json'
$HostCredentials = Join-Path (Join-Path $env:USERPROFILE '.claude') '.credentials.json'

$DefaultBaseImage = 'ubuntu:24.04'

function Show-Usage {
    @"
Usage: claude-yolo.ps1 [OPTIONS] [-- CLAUDE_ARGS...]

COMMANDS:
  build [--force] [IMAGE]  Build Docker image (--force disables cache)
  list                     List all built images
  select <number|tag>      Select image for the current project
  remove <number|tag>      Remove image from registry and optionally from Docker
  login                    Authenticate via OAuth using local Claude CLI and save token
  status                   Show container status for the current directory
  logs                     Show logs of a running container (-Silent mode)
  stop                     Stop the container for the current directory

OPTIONS:
  -Silent         Run the container in the background (detached), no console
  --              Everything after this separator is passed directly to Claude

EXAMPLES:
  .\claude-yolo.ps1                                  Interactive session
  .\claude-yolo.ps1 -- "Write tests"                 Give Claude a task
  .\claude-yolo.ps1 -Silent -- "Refactor"            Run in the background
  .\claude-yolo.ps1 build                            Build default image ($DefaultBaseImage)
  .\claude-yolo.ps1 build oidis/builder:latest       Build with custom base image
  .\claude-yolo.ps1 list                             Show all available images
  .\claude-yolo.ps1 select 2                         Use image #2 for this project
  .\claude-yolo.ps1 status                           Container status
  .\claude-yolo.ps1 logs                             Follow background output
  .\claude-yolo.ps1 stop                             Stop the container
"@
}

function Test-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] 'docker' is not installed."
        Write-Host "   Install Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/"
        exit 1
    }

    & { $ErrorActionPreference = 'Continue'; docker info *>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Docker is installed but not reachable."
        Write-Host ""
        Write-Host "   Docker Desktop is probably not running."
        Write-Host "   Start Docker Desktop from the Start menu or system tray."
        exit 1
    }
}

function Get-ImageSlug {
    param([string]$BaseImage)
    if (-not $BaseImage -or $BaseImage -eq $DefaultBaseImage) {
        return 'default'
    }
    $name = $BaseImage.Split('/')[-1] -replace ':latest$', ''
    $slug = $name.ToLower() -replace '[^a-z0-9]', '-' -replace '-+', '-' -replace '^-|-$', ''
    if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60) }
    return $slug
}

function Get-ImageTag {
    param([string]$Slug)
    return "${ImageRepo}:${Slug}"
}

function Initialize-Registry {
    if (-not (Test-Path $RegistryDir)) { New-Item -ItemType Directory -Path $RegistryDir -Force | Out-Null }
    if (-not (Test-Path $RegistryFile)) {
        @{ images = @() } | ConvertTo-Json -Depth 10 | Set-Content $RegistryFile
    }
}

function Read-Registry {
    $reg = Get-Content $RegistryFile -Raw | ConvertFrom-Json
    $reg.images = @($reg.images)
    return $reg
}

$RegistryLock = Join-Path $RegistryDir '.registry.lock'
$LockTimeout = 30
$LockInterval = 1

function Lock-Registry {
    $waited = 0
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $RegistryLock -ErrorAction Stop | Out-Null
            return
        }
        catch {
            if ($waited -ge $LockTimeout) {
                Write-Host "[ERROR] Registry is locked by another process (timeout after ${LockTimeout}s)."
                Write-Host "   Lock dir: $RegistryLock"
                Write-Host "   If no other instance is running, remove it manually:"
                Write-Host "   Remove-Item '$RegistryLock'"
                exit 1
            }
            Start-Sleep -Seconds $LockInterval
            $waited += $LockInterval
        }
    }
}

function Unlock-Registry {
    Remove-Item $RegistryLock -Force -Recurse -ErrorAction SilentlyContinue
}

function Add-RegistryEntry {
    param([string]$Slug, [string]$BaseImage)
    Initialize-Registry
    Lock-Registry
    try {
        $reg = Read-Registry
        $built = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $fullTag = Get-ImageTag -Slug $Slug
        $existing = @($reg.images | Where-Object { $_.tag -ne $Slug })
        $entry = [PSCustomObject]@{
            tag        = $Slug
            base_image = $BaseImage
            full_tag   = $fullTag
            built_at   = $built
        }
        $reg.images = @($existing) + @($entry)
        $reg | ConvertTo-Json -Depth 10 | Set-Content $RegistryFile
    }
    finally {
        Unlock-Registry
    }
}

function Resolve-Image {
    if (Test-Path $ProjectConfig) {
        $cfg = Get-Content $ProjectConfig -Raw | ConvertFrom-Json
        if ($cfg.image) { return $cfg.image }
    }
    return Get-ImageTag -Slug 'default'
}

function Assert-ImageExists {
    param([string]$Image)
    & { $ErrorActionPreference = 'Continue'; docker image inspect $Image *>$null }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Docker image '${Image}' does not exist. Build it first:"
        $baseHint = ''
        if (Test-Path $RegistryFile) {
            $tag = $Image.Split(':')[-1]
            $reg = Read-Registry
            $entry = $reg.images | Where-Object { $_.tag -eq $tag }
            if ($entry) { $baseHint = $entry.base_image }
        }
        $defaultTag = Get-ImageTag -Slug 'default'
        if ($baseHint -and $baseHint -ne $DefaultBaseImage) {
            Write-Host "   .\claude-yolo.ps1 build $baseHint"
        }
        elseif ($Image -ne $defaultTag) {
            Write-Host "   .\claude-yolo.ps1 build <base-image>"
        }
        else {
            Write-Host "   .\claude-yolo.ps1 build"
        }
        exit 1
    }
}

function Set-ProjectImage {
    param([string]$FullTag)
    if (-not (Test-Path $ProjectDir)) { New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null }
    @{ image = $FullTag } | ConvertTo-Json | Set-Content $ProjectConfig
}

function Get-ContainerName {
    $dir = (Get-Location).Path
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($dir)
    $hash = ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $hash = $hash.Substring(0, 8)
    $slug = (Split-Path -Leaf $dir).ToLower() -replace '[^a-z0-9]', '-'
    if ($slug.Length -gt 20) { $slug = $slug.Substring(0, 20) }
    "claude-yolo-${slug}-${hash}"
}

function Import-EnvFile {
    $envFile = Join-Path $ScriptDir '.env'
    if (Test-Path $envFile) {
        Get-Content $envFile | ForEach-Object {
            if ($_ -match '^\s*([^#=][^=]*)=(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim() -replace '^["'']|["'']$', ''
                [Environment]::SetEnvironmentVariable($key, $val, 'Process')
            }
        }
    }
}

function Test-Auth {
    if ($env:ANTHROPIC_API_KEY) { return }

    if (Test-Path $HostCredentials) { return }

    $tokenFile = Join-Path $GlobalDir '.claude-oauth-token'
    if (Test-Path $tokenFile) {
        $env:CLAUDE_CODE_OAUTH_TOKEN = (Get-Content $tokenFile -Raw).Trim()
        return
    }

    if ($Silent) {
        Write-Host "[ERROR] -Silent requires authentication"
        Write-Host "   Set ANTHROPIC_API_KEY in $ScriptDir\.env or run: claude login"
        exit 1
    }

    Write-Host "[ERROR] No authentication found."
    Write-Host "   Run 'claude login' on the host first, or set ANTHROPIC_API_KEY."
    exit 1
}

function Invoke-Login {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] 'claude' CLI not found on this machine."
        Write-Host "   Install it first: https://docs.anthropic.com/en/docs/claude-code/setup"
        exit 1
    }

    if (-not (Test-Path $GlobalDir)) { New-Item -ItemType Directory -Path $GlobalDir -Force | Out-Null }
    Write-Host "[*] Starting OAuth login via local Claude CLI..."
    Write-Host ""

    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        & { $ErrorActionPreference = 'Continue'; claude setup-token } | Tee-Object -FilePath $tmpFile
        $output = Get-Content $tmpFile -Raw
        if ($output -match '(sk-ant-[A-Za-z0-9_-]+)') {
            $token = $Matches[1]
        }
    }
    finally {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    }

    if (-not $token) {
        Write-Host "[ERROR] Failed to capture token from output."
        $tokenFile = Join-Path $GlobalDir '.claude-oauth-token'
        Write-Host "   Run 'claude setup-token' manually and save the token to: $tokenFile"
        exit 1
    }

    $tokenFile = Join-Path $GlobalDir '.claude-oauth-token'
    Set-Content -Path $tokenFile -Value $token -NoNewline
    Write-Host ""
    Write-Host "[OK] Token saved to $tokenFile"
}

function Invoke-Build {
    param([string[]]$Params)

    $baseImage = ''
    $force = $false

    foreach ($arg in $Params) {
        if ($arg -eq '--force') { $force = $true }
        else { $baseImage = $arg }
    }

    $slug = Get-ImageSlug -BaseImage $baseImage
    $fullTag = Get-ImageTag -Slug $slug
    $actualBase = if ($baseImage) { $baseImage } else { $DefaultBaseImage }

    $buildArgs = @()
    if ($baseImage) {
        $buildArgs += '--build-arg', "BASE_IMAGE=$baseImage"
    }
    Write-Host "[*] Building ${fullTag} (base: ${actualBase})..."
    if ($force) {
        $buildArgs += '--no-cache'
        Write-Host "   (no-cache)"
    }
    & { $ErrorActionPreference = 'Continue'; docker build @buildArgs -t $fullTag $ScriptDir }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Docker build failed."
        exit 1
    }
    Initialize-Registry
    Add-RegistryEntry -Slug $slug -BaseImage $actualBase
    Write-Host "[OK] Image built and registered: ${fullTag}"
}

function Show-ImageList {
    Initialize-Registry
    $reg = Read-Registry

    if (@($reg.images).Count -eq 0) {
        Write-Host "No images built yet. Run '.\claude-yolo.ps1 build' first."
        return
    }

    $stale = @()
    foreach ($img in $reg.images) {
        & { $ErrorActionPreference = 'Continue'; docker image inspect $img.full_tag *>$null }
        if ($LASTEXITCODE -ne 0) {
            $stale += $img.tag
        }
    }

    if ($stale.Count -gt 0) {
        Lock-Registry
        try {
            $reg = Read-Registry
            foreach ($t in $stale) {
                $reg.images = @($reg.images | Where-Object { $_.tag -ne $t })
                Write-Host "  [DEL]  Removed stale entry: $t (Docker image no longer exists)"
            }
            $reg | ConvertTo-Json -Depth 10 | Set-Content $RegistryFile
        }
        finally {
            Unlock-Registry
        }
        if (@($reg.images).Count -eq 0) {
            Write-Host ""
            Write-Host "No images left. Run '.\claude-yolo.ps1 build' first."
            return
        }
        Write-Host ""
    }

    $current = ''
    if (Test-Path $ProjectConfig) {
        $cfg = Get-Content $ProjectConfig -Raw | ConvertFrom-Json
        $current = $cfg.image
    }

    $maxTag = 3
    $maxBase = 10
    foreach ($img in $reg.images) {
        if ($img.tag.Length -gt $maxTag) { $maxTag = $img.tag.Length }
        if ($img.base_image.Length -gt $maxBase) { $maxBase = $img.base_image.Length }
    }

    $fmt = "  {0,-2}{1,-4}  {2,-$maxTag}  {3,-$maxBase}  {4}"
    Write-Host ($fmt -f ' ', '#', 'TAG', 'BASE IMAGE', 'BUILT')
    Write-Host ($fmt -f ' ', '---', ('-' * $maxTag), ('-' * $maxBase), ('-' * 19))

    for ($i = 0; $i -lt @($reg.images).Count; $i++) {
        $img = $reg.images[$i]
        $built = $img.built_at -replace 'T', ' ' -replace 'Z', ''
        $prefix = if ($img.full_tag -eq $current) { '*' } else { ' ' }
        Write-Host ($fmt -f $prefix, ($i + 1), $img.tag, $img.base_image, $built)
    }

    Write-Host ""
    if ($current) {
        Write-Host "  * = current project image"
    }
    else {
        Write-Host "  No image selected for this project (will use claude-yolo:default)"
    }
}

function Select-Image {
    param([string]$Selector)

    if (-not $Selector) {
        Write-Host "Usage: .\claude-yolo.ps1 select <number|tag>"
        Write-Host "   Run '.\claude-yolo.ps1 list' to see available images."
        exit 1
    }

    Initialize-Registry
    $reg = Read-Registry
    $fullTag = ''
    $tag = ''
    $baseImage = ''

    if ($Selector -match '^\d+$') {
        $idx = [int]$Selector - 1
        if ($idx -lt 0 -or $idx -ge @($reg.images).Count) {
            Write-Host "[ERROR] Invalid number: $Selector (have $(@($reg.images).Count) images)"
            exit 1
        }
        $fullTag = $reg.images[$idx].full_tag
        $tag = $reg.images[$idx].tag
        $baseImage = $reg.images[$idx].base_image
    }
    else {
        $match = $reg.images | Where-Object { $_.tag -eq $Selector }
        if (-not $match) {
            Write-Host "[ERROR] No image with tag '$Selector' found."
            Write-Host "   Run '.\claude-yolo.ps1 list' to see available images."
            exit 1
        }
        $fullTag = $match.full_tag
        $tag = $match.tag
        $baseImage = $match.base_image
    }

    Assert-ImageExists -Image $fullTag

    Set-ProjectImage -FullTag $fullTag
    Write-Host "[OK] Project now uses: ${fullTag} (base: ${baseImage})"
}

function Remove-Image {
    param([string]$Selector)

    if (-not $Selector) {
        Write-Host "Usage: .\claude-yolo.ps1 remove <number|tag>"
        Write-Host "   Run '.\claude-yolo.ps1 list' to see available images."
        exit 1
    }

    Initialize-Registry
    $reg = Read-Registry
    $fullTag = ''
    $tag = ''

    if ($Selector -match '^\d+$') {
        $idx = [int]$Selector - 1
        if ($idx -lt 0 -or $idx -ge @($reg.images).Count) {
            Write-Host "[ERROR] Invalid number: $Selector (have $(@($reg.images).Count) images)"
            exit 1
        }
        $fullTag = $reg.images[$idx].full_tag
        $tag = $reg.images[$idx].tag
    }
    else {
        $match = $reg.images | Where-Object { $_.tag -eq $Selector }
        if (-not $match) {
            Write-Host "[ERROR] No image with tag '$Selector' found."
            Write-Host "   Run '.\claude-yolo.ps1 list' to see available images."
            exit 1
        }
        $fullTag = $match.full_tag
        $tag = $match.tag
    }

    Lock-Registry
    try {
        $reg = Read-Registry
        $reg.images = @($reg.images | Where-Object { $_.tag -ne $tag })
        $reg | ConvertTo-Json -Depth 10 | Set-Content $RegistryFile
    }
    finally {
        Unlock-Registry
    }
    Write-Host "[OK] Removed '${tag}' from registry"

    & { $ErrorActionPreference = 'Continue'; docker image inspect $fullTag *>$null }
    if ($LASTEXITCODE -eq 0) {
        $answer = Read-Host "   Docker image ${fullTag} exists. Remove it too? [y/N]"
        if ($answer -match '^[Yy]$') {
            & { $ErrorActionPreference = 'Continue'; docker rmi $fullTag }
            Write-Host "[OK] Docker image removed"
        }
    }
}

function Show-Status {
    $name = Get-ContainerName
    $dir = (Get-Location).Path
    $img = Resolve-Image
    $running = docker ps --format '{{.Names}}' | Where-Object { $_ -eq $name }

    if ($running) {
        $started = & { $ErrorActionPreference = 'Continue'; docker inspect --format '{{.State.StartedAt}}' $name 2>$null }
        if ($started) { $started = $started.Substring(0, 19).Replace('T', ' ') }
        Write-Host "[OK] Container is running"
        Write-Host "   Directory: $dir"
        Write-Host "   Name:      $name"
        Write-Host "   Image:     $img"
        Write-Host "   Started:   $started"
    }
    else {
        $exists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $name }
        if ($exists) {
            $status = & { $ErrorActionPreference = 'Continue'; docker inspect --format '{{.State.Status}}' $name 2>$null }
            Write-Host "[WARN]  Container exists but is not running (status: $status)"
            Write-Host "   Directory: $dir"
            Write-Host "   Name:      $name"
            Write-Host "   Image:     $img"
        }
        else {
            Write-Host "[--] No container for this directory"
            Write-Host "   Directory: $dir"
            Write-Host "   Image:     $img"
        }
    }
}

function Show-Logs {
    $name = Get-ContainerName
    $running = docker ps --format '{{.Names}}' | Where-Object { $_ -eq $name }
    if (-not $running) {
        Write-Host "[ERROR] No container is running for this directory"
        Show-Status
        exit 1
    }
    Write-Host "[*] Logs for container ${name} (Ctrl+C to quit):"
    & { $ErrorActionPreference = 'Continue'; docker logs -f $name }
}

function Stop-Container {
    $name = Get-ContainerName
    $running = docker ps --format '{{.Names}}' | Where-Object { $_ -eq $name }

    if ($running) {
        Write-Host "[*] Stopping container ${name}..."
        & { $ErrorActionPreference = 'Continue'; docker stop $name }
        Write-Host "[OK] Stopped"
    }
    else {
        $exists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $name }
        if ($exists) {
            Write-Host "[DEL]  Removing stopped container ${name}..."
            & { $ErrorActionPreference = 'Continue'; docker rm $name }
            Write-Host "[OK] Removed"
        }
        else {
            Write-Host "[--] No container for this directory"
        }
    }
}

function Invoke-Run {
    param([string[]]$ClaudeArgs)

    $name = Get-ContainerName
    $running = docker ps --format '{{.Names}}' | Where-Object { $_ -eq $name }

    if ($running) {
        Write-Host "[WARN]  A container is already running for this directory: ${name}"
        Write-Host "   Use '.\claude-yolo.ps1 status' or '.\claude-yolo.ps1 stop'"
        exit 1
    }

    $exists = docker ps -a --format '{{.Names}}' | Where-Object { $_ -eq $name }
    if ($exists) {
        & { $ErrorActionPreference = 'Continue'; docker rm $name *>$null }
    }

    $img = Resolve-Image

    Assert-ImageExists -Image $img

    if (-not (Test-Path $ProjectConfig)) {
        Set-ProjectImage -FullTag $img
    }

    if (-not (Test-Path $ProjectDir)) { New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null }
    $claudeJson = Join-Path $ProjectDir '.claude.json'
    if (-not (Test-Path $claudeJson) -or (Get-Item $claudeJson).Length -eq 0) {
        Set-Content -Path $claudeJson -Value '{}'
    }

    $dir = (Get-Location).Path
    $baseArgs = @(
        '--name', $name,
        '-v', "${dir}:/workspace",
        '-v', "${ProjectDir}:/root/.claude",
        '-v', "${claudeJson}:/root/.claude.json",
        '-w', '/workspace'
    )

    if ($env:ANTHROPIC_API_KEY) {
        $baseArgs += '-e', "ANTHROPIC_API_KEY=$($env:ANTHROPIC_API_KEY)"
    }
    elseif (Test-Path $HostCredentials) {
        $baseArgs += '-v', "${HostCredentials}:/root/.claude/.credentials.json:ro"
    }
    elseif ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        $baseArgs += '-e', "CLAUDE_CODE_OAUTH_TOKEN=$($env:CLAUDE_CODE_OAUTH_TOKEN)"
    }

    if ($Silent) {
        Write-Host "[*] Starting in the background..."
        Write-Host "   Directory: $dir"
        Write-Host "   Name:      ${name}"
        Write-Host "   Image:     ${img}"
        $allArgs = @('run', '-d') + $baseArgs + @($img) + $ClaudeArgs
        & { $ErrorActionPreference = 'Continue'; docker @allArgs }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] Failed to start container."
            exit 1
        }
        Write-Host ""
        Write-Host "[*] Follow output: .\claude-yolo.ps1 logs"
        Write-Host "[*] Stop:          .\claude-yolo.ps1 stop"
        Write-Host "[*] Status:        .\claude-yolo.ps1 status"
    }
    else {
        $allArgs = @('run', '-it', '--rm') + $baseArgs + @($img) + $ClaudeArgs
        & { $ErrorActionPreference = 'Continue'; docker @allArgs }
    }
}

# --- Main ---

if ($Command -in 'help', '-h', '--help') {
    Show-Usage
    return
}

Test-Docker

$claudeArgs = @()

switch ($Command) {
    'build'  { Initialize-Registry; Invoke-Build -Params $Rest; return }
    'list'   { Show-ImageList; return }
    'select' { Select-Image -Selector ($Rest | Select-Object -First 1); return }
    'remove' { Remove-Image -Selector ($Rest | Select-Object -First 1); return }
    'login'  { Invoke-Login; return }
    'status' { Show-Status; return }
    'logs'   { Show-Logs; return }
    'stop'   { Stop-Container; return }
    '--' {
        $claudeArgs = $Rest
    }
    default {
        if ($Command -and $Command -ne '--silent') {
            $knownCommands = @('build', 'list', 'select', 'remove', 'login', 'status', 'logs', 'stop')
            $best = $knownCommands | Where-Object { $_.StartsWith($Command) -or $Command.StartsWith($_) } | Select-Object -First 1
            if ($best) {
                Write-Host "[ERROR] Unknown command: $Command"
                Write-Host "   Did you mean: .\claude-yolo.ps1 $best"
            }
            else {
                Write-Host "[ERROR] Unknown command: $Command"
                Write-Host "   Run '.\claude-yolo.ps1 help' to see available commands."
            }
            exit 1
        }
        if ($Command -eq '--silent') { $Silent = $true }
        $afterSeparator = $false
        foreach ($arg in $Rest) {
            if ($afterSeparator) {
                $claudeArgs += $arg
                continue
            }
            if ($arg -eq '--') { $afterSeparator = $true; continue }
            if ($arg -eq '--silent') { $Silent = $true; continue }
            $claudeArgs += $arg
        }
    }
}

Import-EnvFile
Test-Auth
Invoke-Run -ClaudeArgs $claudeArgs
