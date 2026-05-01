# fzmp - Config.ps1
# Load configuration from file, apply defaults, merge CLI overrides

$script:DefaultConfig = @{
    MusicRoot       = "H:\music"
    PreviewPosition = "top"        # "top" or "left"
    PreviewMode     = "art"        # "art" or "tags"
    ChafaPath       = "chafa"
    MpvPath         = "mpv"
    FfprobePath     = "ffprobe"
    FfmpegPath      = "ffmpeg"
    FdPath          = "fd.exe"
    FzfPath         = "fzf"
    PipeName        = "fzmp"
    Recent          = $null
    ArtFilenames    = @("folder.jpg", "folder.png", "cover.jpg", "cover.png", "front.jpg", "front.png")
    AudioExtensions = @("mp3", "flac", "ogg", "wav", "m4a", "opus", "wma", "aac", "ape", "wv", "mka")
}

function Get-FzmpConfigPath {
    $configDir = Join-Path $env:APPDATA "fzmp"
    return Join-Path $configDir "config.ps1"
}

function Get-FzmpConfig {
    [CmdletBinding()]
    param(
        [string]$MusicRoot,
        [string]$PreviewPosition,
        [string]$PreviewMode,
        [string]$Recent
    )

    # Start with defaults
    $config = @{}
    foreach ($key in $script:DefaultConfig.Keys) {
        $config[$key] = $script:DefaultConfig[$key]
    }

    # Load config file if it exists
    $configPath = Get-FzmpConfigPath
    if (Test-Path $configPath) {
        try {
            $fileConfig = & $configPath
            if ($fileConfig -is [hashtable]) {
                foreach ($key in $fileConfig.Keys) {
                    $config[$key] = $fileConfig[$key]
                }
            }
        }
        catch {
            Write-Warning "Failed to load config from $configPath : $_"
        }
    }

    # Apply CLI overrides
    if ($MusicRoot)       { $config.MusicRoot       = $MusicRoot }
    if ($PreviewPosition) { $config.PreviewPosition = $PreviewPosition }
    if ($PreviewMode)     { $config.PreviewMode     = $PreviewMode }
    if ($Recent)          { $config.Recent          = $Recent }

    # Resolve the script root for lib path reference
    $config['_ScriptRoot'] = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (-not $config['_ScriptRoot']) {
        $config['_ScriptRoot'] = Split-Path -Parent $PSScriptRoot
    }

    return $config
}

function Test-FzmpDependencies {
    [CmdletBinding()]
    param([hashtable]$Config)

    $errors = @()

    # Check tool paths
    $tools = @(
        @{ Name = "fzf";     Path = $Config.FzfPath }
        @{ Name = "fd";      Path = $Config.FdPath }
        @{ Name = "mpv";     Path = $Config.MpvPath }
        @{ Name = "chafa";   Path = $Config.ChafaPath }
        @{ Name = "ffprobe"; Path = $Config.FfprobePath }
    )

    foreach ($tool in $tools) {
        $resolved = $null
        if ([System.IO.Path]::IsPathRooted($tool.Path)) {
            if (-not (Test-Path $tool.Path)) {
                $errors += "$($tool.Name): not found at '$($tool.Path)'"
            }
        }
        else {
            $resolved = Get-Command $tool.Path -ErrorAction SilentlyContinue
            if (-not $resolved) {
                $errors += "$($tool.Name): '$($tool.Path)' not found in PATH"
            }
        }
    }

    # Check music root
    if (-not (Test-Path $Config.MusicRoot -PathType Container)) {
        $errors += "Music root not found: '$($Config.MusicRoot)'"
    }

    # Validate preview settings
    if ($Config.PreviewPosition -notin @('top', 'left')) {
        $errors += "PreviewPosition must be 'top' or 'left', got '$($Config.PreviewPosition)'"
    }
    if ($Config.PreviewMode -notin @('art', 'tags')) {
        $errors += "PreviewMode must be 'art' or 'tags', got '$($Config.PreviewMode)'"
    }

    return $errors
}
