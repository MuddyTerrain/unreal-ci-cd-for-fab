<#
.SYNOPSIS
    A fast pipeline to build and package a plugin for multiple engine versions.
.DESCRIPTION
    This script automates the compilation and packaging of an Unreal Engine plugin,
    producing clean, marketplace-ready .zip files for each specified engine version.
    It uses smart copying to exclude .git, build artifacts, and other unnecessary files
    for faster, cleaner builds.
.PARAMETER OutputDirectory
    Optional. Specifies the output directory for build artifacts. If not provided, 
    creates a timestamped directory in the project root.
.NOTES
    Author: Prajwal Shetty
    Version: 1.10 - Fixed output directory structure and added parameter support
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory,

    [Parameter(Mandatory=$false)]
    [string]$EngineVersion,

    [Parameter(Mandatory=$false)]
    [switch]$UseCache
)

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $ScriptDir
$GlobalSuccess = $true

# Load configuration
$ConfigPath = Join-Path -Path $ProjectRoot -ChildPath "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found at '$ConfigPath'."
    exit 1
}
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# Get Plugin Version from .uplugin file
$SourceUpluginPath = Join-Path -Path $Config.PluginSourceDirectory -ChildPath "$($Config.PluginName).uplugin"
if (-not (Test-Path $SourceUpluginPath)) {
    Write-Error "Could not find source .uplugin file at '$SourceUpluginPath'. Check your 'PluginSourceDirectory' and 'PluginName' in config.json."
    exit 1
}
$PluginInfo = Get-Content -Raw -Path $SourceUpluginPath | ConvertFrom-Json
$PluginVersion = $PluginInfo.VersionName

# --- Create output directory ---
if ($OutputDirectory) {
    $OutputBuildsDir = $OutputDirectory
} else {
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputBuildsDir = Join-Path -Path $ProjectRoot -ChildPath "$($Config.OutputDirectory)_$Timestamp"
}
$LogsDir = Join-Path -Path $ProjectRoot -ChildPath "Logs"
New-Item -Path $OutputBuildsDir -ItemType Directory -Force | Out-Null
New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null

# --- MAIN EXECUTION LOOP ---
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " STARTING FAST PLUGIN PACKAGING PIPELINE (Fab Upload)" -ForegroundColor Green
Write-Host "================================================================="
Write-Host "Plugin: $($Config.PluginName) v$($PluginVersion)"
Write-Host "Outputting to: $OutputBuildsDir"

# Define path for the GLOBAL BuildConfiguration.xml
$UserBuildConfigDir = Join-Path -Path $HOME -ChildPath "Documents/Unreal Engine/UnrealBuildTool"
$UserBuildConfigPath = Join-Path -Path $UserBuildConfigDir -ChildPath "BuildConfiguration.xml"
$UserBuildConfigBackupPath = Join-Path -Path $UserBuildConfigDir -ChildPath "BuildConfiguration.xml.bak"


# Determine which engine versions to process
$VersionsToProcess = if (-not [string]::IsNullOrEmpty($EngineVersion)) { @($EngineVersion) } else { $Config.EngineVersions }

foreach ($CurrentEngineVersion in $VersionsToProcess) {
    $CurrentStage = "SETUP"
    $EnginePath = Join-Path -Path $Config.UnrealEngineBasePath -ChildPath "UE_$CurrentEngineVersion"
    $LogFile = Join-Path -Path $LogsDir -ChildPath "BuildLog_UE_${CurrentEngineVersion}_$Timestamp.txt"

    # Define paths for temporary and final artifacts for this version
    $TempDir = Join-Path -Path $OutputBuildsDir -ChildPath "Temp_${CurrentEngineVersion}"
    $HostProjectDir = Join-Path -Path $TempDir -ChildPath "HostProject"
    $PackageOutputDir = Join-Path -Path $TempDir -ChildPath "PackagedPlugin_Raw"
    $CleanedPluginStageDir = Join-Path -Path $TempDir -ChildPath "Staging"
    
    $FinalPluginZipPath = Join-Path -Path $OutputBuildsDir -ChildPath "$($Config.PluginName)_v$($PluginVersion)_ue$($CurrentEngineVersion).zip"

    Write-Host "`n-----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " [TASK] Starting pipeline for Unreal Engine $CurrentEngineVersion" -ForegroundColor Yellow
    Write-Host " (Full log will be saved to: $LogFile)" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------------------------"

    # --- CACHE CHECK ---
    if ($UseCache.IsPresent -and (Test-Path $FinalPluginZipPath)) {
        Write-Host "[CACHE] Skipping UE $CurrentEngineVersion because output already exists: $FinalPluginZipPath" -ForegroundColor Cyan
        continue
    }

    try {
        # --- 1. SETUP BUILD ENVIRONMENT ---
        $CurrentStage = "SETUP_BUILD_CONFIG"
        Write-Host "[1/3] [CONFIG] Setting up build environment for UE $CurrentEngineVersion..."
        
        if (Test-Path $TempDir) { Remove-Item -Recurse -Force -Path $TempDir }
        New-Item -Path $TempDir -ItemType Directory -Force | Out-Null

        New-Item -Path $UserBuildConfigDir -ItemType Directory -Force | Out-Null
        if (Test-Path $UserBuildConfigPath) {
            Rename-Item -Path $UserBuildConfigPath -NewName "BuildConfiguration.xml.bak" -Force
        }
        
        # Updated Toolchain versions based on Epic's recommendations
        $ToolchainVersion = switch ($CurrentEngineVersion) {
            "5.1" { "14.32.31326" } # VS 2022 v17.2
            "5.2" { "14.34.31933" } # VS 2022 v17.4
            "5.3" { "14.36.32532" } # VS 2022 v17.6
            "5.4" { "14.38.33130" } # VS 2022 v17.8
            "5.5" { "14.38.33130" } # VS 2022 v17.10 
            "5.6" { "14.40.33807" } # VS 2022 v17.10 or later
            default { "Latest" }
        }
        @"
<?xml version="1.0" encoding="utf-8" ?>
<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration">
    <WindowsPlatform>
        <CompilerVersion>$($ToolchainVersion)</CompilerVersion>
    </WindowsPlatform>
</Configuration>
"@ | Out-File -FilePath $UserBuildConfigPath -Encoding utf8

        if (-not (Test-Path $EnginePath)) {
            throw "[SKIP] Engine not found at '$EnginePath'"
        }

        # --- 2. SETUP & BUILD HOST PROJECT ---
        $CurrentStage = "BUILD"
        Write-Host "[2/3] [BUILD] Compiling plugin using temporary host project..."
        New-Item -Path $HostProjectDir -ItemType Directory -Force | Out-Null
        $HostUprojectPath = Join-Path -Path $HostProjectDir -ChildPath "HostProject.uproject"
        @{ FileVersion = 3; EngineAssociation = $EngineVersion; Category = ""; Description = ""; Plugins = @(@{ Name = $Config.PluginName; Enabled = $true }) } | ConvertTo-Json -Depth 5 | Out-File -FilePath $HostUprojectPath -Encoding utf8
        $HostPluginDir = Join-Path -Path $HostProjectDir -ChildPath "Plugins/$($Config.PluginName)"
        
        # Smart copy of plugin source (excluding build artifacts and VCS)
        $ExcludeDirs = @(
            ".git",
            ".vs", 
            "Binaries",
            "Build", 
            "Intermediate",
            "Saved",
            "DerivedDataCache",
            "__pycache__",
            ".vscode",
            ".idea",
            "Packages"
        )
        
        # Use Robocopy for efficient copying with exclusions
        Write-Host "Copying plugin source (excluding build artifacts)..."
        robocopy $Config.PluginSourceDirectory $HostPluginDir /E /XD $ExcludeDirs /NFL /NDL /NJH /NJS /nc /ns /np
        # Note: Robocopy exit codes 0-7 are success, 8+ are errors
        if ($LASTEXITCODE -gt 7) { 
            throw "Failed to copy plugin source. Robocopy exit code: $LASTEXITCODE" 
        }
        
        $HostUpluginPath = Join-Path -Path $HostPluginDir -ChildPath "$($Config.PluginName).uplugin"
        $UpluginJson = Get-Content -Raw -Path $HostUpluginPath | ConvertFrom-Json
        $UpluginJson.EngineVersion = "$($CurrentEngineVersion).0"
        $UpluginJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $HostUpluginPath -Encoding utf8

        # FIX: Restore Tee-Object to show live build log in console AND save to file.
        & "$EnginePath/Engine/Build/BatchFiles/RunUAT.bat" BuildPlugin -Plugin="$HostUpluginPath" -Package="$PackageOutputDir" -TargetPlatforms=Win64 -Rocket *>&1 | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Packaging failed. Check the log file." }
        Write-Host "Build process completed successfully."

        # --- 3. CREATE CLEAN DISTRIBUTABLE ---
        $CurrentStage = "CREATE_DISTRIBUTABLE"
        Write-Host "[3/3] [FINALIZE] Creating clean distributable zip..."
        
        $PackagedUpluginFile = Get-ChildItem -Path $PackageOutputDir -Filter "$($Config.PluginName).uplugin" -Recurse | Select-Object -First 1
        if (-not $PackagedUpluginFile) {
            throw "Could not find the packaged .uplugin file in '$PackageOutputDir'. Build may have failed to produce output."
        }
        $SourceForCleaning = $PackagedUpluginFile.DirectoryName
        
        New-Item -Path $CleanedPluginStageDir -ItemType Directory -Force | Out-Null
        
        $PluginRootInStage = Join-Path -Path $CleanedPluginStageDir -ChildPath $Config.PluginName
        New-Item -Path $PluginRootInStage -ItemType Directory -Force | Out-Null

        "Source", "Content", "Resources" | ForEach-Object {
            $SourcePath = Join-Path -Path $SourceForCleaning -ChildPath $_
            if (Test-Path $SourcePath) { Copy-Item -Recurse -Force -Path $SourcePath -Destination (Join-Path -Path $PluginRootInStage -ChildPath $_) }
        }
        Copy-Item -Force -Path $PackagedUpluginFile.FullName -Destination (Join-Path -Path $PluginRootInStage -ChildPath $PackagedUpluginFile.Name)
        
        # Robust retry loop to handle file locking issues during zipping.
        $ItemToZip = Get-ChildItem -Path $CleanedPluginStageDir | Select-Object -First 1
        if (-not $ItemToZip) {
            throw "Staging directory is empty. Nothing to zip."
        }
        
        $MaxRetries = 6
        $RetryDelaySeconds = 5
        for ($i = 1; $i -le $MaxRetries; $i++) {
            try {
                Compress-Archive -Path $ItemToZip.FullName -DestinationPath $FinalPluginZipPath -Force -ErrorAction Stop
                Write-Host "Zipping successful." -ForegroundColor Green
                break # Exit loop on success
            }
            catch {
                if ($i -eq $MaxRetries) {
                    Write-Error "Failed to zip files after $MaxRetries attempts. The last error was:"
                    throw # Re-throw the last exception to fail the script
                }
                Write-Host "Attempt $i/${MaxRetries}: Zipping failed, file may be locked. Retrying in $RetryDelaySeconds seconds..." -ForegroundColor Yellow
                Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor DarkGray
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }

        Write-Host "[SUCCESS] UE $CurrentEngineVersion package created successfully!" -ForegroundColor Green

    } catch {
        $GlobalSuccess = $false
        Write-Host "`n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host "!!!! BUILD FAILED for UE $CurrentEngineVersion at stage: $CurrentStage !!!!" -ForegroundColor Red
        Write-Host "!!!! Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "!!!! Check the log file for details: $LogFile" -ForegroundColor Red
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    } finally {
        # --- Cleanup ---
        Write-Host "Cleaning up temporary files for UE $CurrentEngineVersion..."
        if (Test-Path $TempDir) { Remove-Item -Recurse -Force -Path $TempDir }
        
        if (Test-Path $UserBuildConfigPath) { Remove-Item -Path $UserBuildConfigPath -Force }
        if (Test-Path $UserBuildConfigBackupPath) {
            Rename-Item -Path $UserBuildConfigBackupPath -NewName "BuildConfiguration.xml" -Force
        }
    }
}


