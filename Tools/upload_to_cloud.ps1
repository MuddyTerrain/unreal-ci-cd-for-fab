<#
.SYNOPSIS
    Uploads build artifacts to a configured cloud provider using rclone.
.DESCRIPTION
    Reads cloud settings from config.json and uploads the specified source directory.
    Designed to be generic for any cloud provider supported by rclone.
.NOTES
    Author: Prajwal Shetty
    Version: 1.0
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$SourceDirectory
)

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigPath = Join-Path -Path $ProjectRoot -ChildPath "config.json"
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

$RcloneConfig = $Config.CloudUpload.RcloneConfigPath
$RcloneExePath = $Config.CloudUpload.RcloneExePath
$RemoteName = $Config.CloudUpload.RemoteName
$RemotePath = $Config.CloudUpload.RemoteFolderPath
$SourceDirName = (Get-Item $SourceDirectory).Name

if (-not (Test-Path $RcloneConfig)) {
    throw "rclone config file not found at '$RcloneConfig'. Please check path or run 'rclone config'."
}

if (-not (Test-Path $RcloneExePath)) {
    throw "rclone executable not found at '$RcloneExePath'. Please check the path in config.json."
}

# --- MAIN EXECUTION ---
try {
    Write-Host "Starting organized upload of '$SourceDirectory' to '$($RemoteName):$($RemotePath)'"
    
    # Get all files in the source directory
    $AllFiles = Get-ChildItem -Path $SourceDirectory -File
    
    # Separate plugin files from example project files
    $PluginFiles = $AllFiles | Where-Object { $_.Name -like "*$($Config.PluginName)_v*_ue*.zip" -and $_.Name -notlike "*_CPP_*" -and $_.Name -notlike "*_BP_*" }
    $CppExampleFiles = $AllFiles | Where-Object { $_.Name -like "*_CPP_UE*.zip" }
    $BpExampleFiles = $AllFiles | Where-Object { $_.Name -like "*_BP_UE*.zip" }
    $LogFiles = Get-ChildItem -Path $SourceDirectory -Directory -Name "Logs"
    
    Write-Host "`nFound files to upload:"
    Write-Host "- Plugin packages: $($PluginFiles.Count)"
    Write-Host "- C++ Example projects: $($CppExampleFiles.Count)" 
    Write-Host "- Blueprint Example projects: $($BpExampleFiles.Count)"
    Write-Host "- Log directories: $($LogFiles.Count)"
    
    # Create organized directory structure
    $BaseDestination = "$($RemoteName):$($RemotePath)/$($SourceDirName)"
    
    # Upload plugin packages to /Plugins subdirectory
    if ($PluginFiles.Count -gt 0) {
        Write-Host "`nUploading plugin packages..."
        $PluginDestination = "$BaseDestination/Plugins"
        foreach ($file in $PluginFiles) {
            Write-Host "  -> $($file.Name) to Plugins/"
            & "$RcloneExePath" copy "$($file.FullName)" "$PluginDestination" --config "$RcloneConfig" --progress
            if ($LASTEXITCODE -ne 0) { throw "Failed to upload plugin file: $($file.Name)" }
        }
    }
    
    # Upload example projects organized by engine version
    $AllExampleFiles = $CppExampleFiles + $BpExampleFiles
    if ($AllExampleFiles.Count -gt 0) {
        Write-Host "`nUploading example projects organized by engine version..."
        
        # Group files by engine version
        $FilesByVersion = @{}
        foreach ($file in $AllExampleFiles) {
            # Extract engine version from filename (e.g., "UE5.5" from "ProjectName_CPP_UE5.5.zip")
            if ($file.Name -match "_UE(\d+\.\d+)\.zip$") {
                $engineVersion = $matches[1]
                if (-not $FilesByVersion.ContainsKey($engineVersion)) {
                    $FilesByVersion[$engineVersion] = @()
                }
                $FilesByVersion[$engineVersion] += $file
            }
        }
        
        # Upload files for each engine version to its own subdirectory
        foreach ($version in $FilesByVersion.Keys) {
            $VersionDestination = "$BaseDestination/ExampleProjects/v$($version.Replace('.', '_'))"
            Write-Host "  Uploading for engine version $version to v$($version.Replace('.', '_'))/"
            
            foreach ($file in $FilesByVersion[$version]) {
                Write-Host "    -> $($file.Name)"
                & "$RcloneExePath" copy "$($file.FullName)" "$VersionDestination" --config "$RcloneConfig" --progress
                if ($LASTEXITCODE -ne 0) { throw "Failed to upload example file: $($file.Name)" }
            }
        }
    }
    
    # Upload logs to /Logs subdirectory
    if ($LogFiles.Count -gt 0) {
        Write-Host "`nUploading log files..."
        $LogsDestination = "$BaseDestination/Logs"
        $LogsSourcePath = Join-Path -Path $SourceDirectory -ChildPath "Logs"
        & "$RcloneExePath" copy "$LogsSourcePath" "$LogsDestination" --config "$RcloneConfig" --progress --create-empty-src-dirs
        if ($LASTEXITCODE -ne 0) { throw "Failed to upload logs directory" }
    }

    Write-Host "`nUpload completed successfully with organized structure!" -ForegroundColor Green
    Write-Host "Final structure in Google Drive:" -ForegroundColor Cyan
    Write-Host "  $($RemotePath)/$($SourceDirName)/" -ForegroundColor Cyan
    Write-Host "    +-- Plugins/                    (Plugin .zip files)" -ForegroundColor Cyan
    Write-Host "    +-- ExampleProjects/" -ForegroundColor Cyan
    Write-Host "    |   +-- v5_1/                  (UE 5.1 example projects)" -ForegroundColor Cyan
    Write-Host "    |   +-- v5_2/                  (UE 5.2 example projects)" -ForegroundColor Cyan
    Write-Host "    |   +-- v5_X/                  (etc. for each engine version)" -ForegroundColor Cyan
    Write-Host "    +-- Logs/                      (Build logs)" -ForegroundColor Cyan

} catch {
    Write-Host "`n!!!! CLOUD UPLOAD FAILED !!!!" -ForegroundColor Red
    Write-Host "!!!! Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
