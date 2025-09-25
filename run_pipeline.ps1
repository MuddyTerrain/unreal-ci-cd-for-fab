<#
.SYNOPSIS
    Master CI/CD pipeline script to build, package, and upload an Unreal Engine plugin.
.DESCRIPTION
    This master script runs the entire local pipeline:
    1. Validates configuration and prerequisites
    2. Packages the plugin for multiple engine versions.
    3. (Optional) Packages C++ and/or Blueprint example projects for each version.
    4. (Optional) Uploads all artifacts to a configured cloud provider using rclone.
.PARAMETER DryRun
    Validates configuration and shows what would be built without actually building.
.PARAMETER SkipValidation
    Skip the configuration validation step (not recommended for production).
.NOTES
    Author: Prajwal Shetty
    Version: 3.0 - Refactored to use temporary staging directory
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipValidation,

    [Parameter(Mandatory=$false)]
    [switch]$UseCache,

    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = "config.json"
)

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$LogDir = Join-Path -Path $PSScriptRoot -ChildPath "Logs"

# Resolve ConfigPath relative to script root if it's not an absolute path
if (-not ([System.IO.Path]::IsPathRooted($ConfigPath))) {
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath $ConfigPath
}

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file (config.json) not found at '$ConfigPath'."
    Write-Host "Please copy 'config.example.json' to 'config.json' and configure it for your project." -ForegroundColor Yellow
    exit 1
}

# Validate configuration before proceeding (unless skipped)
if (-not $SkipValidation) {
    Write-Host "Validating configuration and prerequisites..." -ForegroundColor Cyan
    & "$ScriptDir/Tools/validate_config.ps1" -ConfigPath $ConfigPath
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Configuration validation failed. Please fix the issues above before running the pipeline."
        exit 1
    }
} else {
    Write-Host "[WARNING] Skipping validation (not recommended for production)" -ForegroundColor Yellow
}

$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

$GlobalSuccess = $true

# Define final and temporary directories
$FinalOutputDir = Join-Path -Path $ScriptDir -ChildPath $Config.OutputDirectory
$TempStagingDir = Join-Path -Path $ScriptDir -ChildPath ".tmp"

# --- DRY RUN MODE ---
if ($DryRun) {
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host " DRY RUN MODE - SHOWING WHAT WOULD BE BUILT" -ForegroundColor Cyan
    Write-Host "================================================================="
    
    Write-Host "`nPIPELINE SUMMARY:" -ForegroundColor Yellow
    Write-Host "Plugin: $($Config.PluginName)" -ForegroundColor White
    Write-Host "Engine Versions: $($Config.EngineVersions -join ', ')" -ForegroundColor White
    Write-Host "Final Output Directory: $FinalOutputDir" -ForegroundColor White
    Write-Host "Temporary Staging Directory: $TempStagingDir (would be created)" -ForegroundColor Gray

    Write-Host "`nTASKS THAT WOULD RUN:" -ForegroundColor Yellow
    Write-Host "1. Package plugin for $($Config.EngineVersions.Count) engine version(s)"
    
    if ($Config.ExampleProject -and $Config.ExampleProject.Generate) {
        $ExampleTypes = @()
        if ($Config.ExampleProject.GenerateCppExample) { $ExampleTypes += "C++" }
        if ($Config.ExampleProject.GenerateBlueprintExample) { $ExampleTypes += "Blueprint" }
        Write-Host "2. Package example projects ($($ExampleTypes -join ', ')) for $($Config.EngineVersions.Count) engine version(s)"
    } else {
        Write-Host "2. Skip example projects (disabled in config)"
    }
    
    if ($Config.CloudUpload -and $Config.CloudUpload.Enable) {
        Write-Host "3. Upload to cloud: $($Config.CloudUpload.RemoteName):$($Config.CloudUpload.RemoteFolderPath)"
    } else {
        Write-Host "3. Skip cloud upload (disabled in config)"
    }
    
    Write-Host "`n[SUCCESS] Dry run completed. Run without -DryRun to execute the pipeline." -ForegroundColor Green
    exit 0
}

# Create and clean directories for the actual run
if (Test-Path $TempStagingDir) {
    Write-Host "Removing existing temporary directory..." -ForegroundColor Gray
    Remove-Item -Path $TempStagingDir -Recurse -Force
}
New-Item -ItemType Directory -Path $FinalOutputDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path $TempStagingDir -Force | Out-Null

# --- MAIN EXECUTION ---
Write-Host "=================================================================" -ForegroundColor Magenta
Write-Host " STARTING MASTER PIPELINE (Final output to: $FinalOutputDir)" -ForegroundColor Magenta
Write-Host "================================================================="

try {
    # --- Determine if running in Fast Mode ---
    $FastMode = $false
    if ($Config.PSObject.Properties.Name -contains 'BuildOptions' -and $Config.BuildOptions.PSObject.Properties.Name -contains 'FastMode') {
        $FastMode = $Config.BuildOptions.FastMode
    }

    if ($FastMode) {
        Write-Host "`n[INFO] Running in FAST MODE. Using combined packaging script." -ForegroundColor Green
        # --- Loop through each engine version and run the combined task ---
        foreach ($EngineVersion in $Config.EngineVersions) {
            Write-Host "`n=================================================================" -ForegroundColor DarkCyan
            Write-Host " PROCESSING ENGINE VERSION: $EngineVersion" -ForegroundColor DarkCyan
            Write-Host "================================================================="
            & "$ScriptDir/Tools/package_fast_combined.ps1" -OutputDirectory $TempStagingDir -FinalOutputDir $FinalOutputDir -EngineVersion $EngineVersion -UseCache:$UseCache -ConfigPath $ConfigPath
            if ($LASTEXITCODE -ne 0) { throw "Fast mode packaging failed for $EngineVersion." }
        }
    } else {
        Write-Host "`n[INFO] Running in Standard Mode. Using sequential packaging scripts." -ForegroundColor Yellow
        # --- Loop through each engine version and run tasks sequentially ---
        foreach ($EngineVersion in $Config.EngineVersions) {
            Write-Host "`n=================================================================" -ForegroundColor DarkCyan
            Write-Host " PROCESSING ENGINE VERSION: $EngineVersion" -ForegroundColor DarkCyan
            Write-Host "================================================================="

            # --- 1. PACKAGE PLUGIN ---
            if ($Config.BuildOptions -and $Config.BuildOptions.SkipPluginBuild) {
                Write-Host "`n[TASK 1/3] Skipping plugin packaging for $EngineVersion (SkipPluginBuild is true in config)." -ForegroundColor Yellow
            } else {
                Write-Host "`n[TASK 1/3] Running plugin packaging script for $EngineVersion..." -ForegroundColor Cyan
                & "$ScriptDir/Tools/package_fast.ps1" -OutputDirectory $FinalOutputDir -EngineVersion $EngineVersion -UseCache:$UseCache -ConfigPath $ConfigPath
                if ($LASTEXITCODE -ne 0) { throw "Plugin packaging failed for $EngineVersion." }
            }

            # --- 2. PACKAGE EXAMPLE PROJECTS ---
            if ($Config.ExampleProject -and $Config.ExampleProject.Generate) {
                Write-Host "`n[TASK 2/3] Running example project packaging script for $EngineVersion..." -ForegroundColor Cyan
                & "$ScriptDir/Tools/package_example_project.ps1" -OutputDirectory $TempStagingDir -FinalOutputDir $FinalOutputDir -EngineVersion $EngineVersion -UseCache:$UseCache -ConfigPath $ConfigPath
                if ($LASTEXITCODE -ne 0) { throw "Example project packaging failed for $EngineVersion." }
            } else {
                Write-Host "`n[TASK 2/3] Skipping example project generation for $EngineVersion (disabled in config)." -ForegroundColor Yellow
            }
        }
    }

    # --- 3. UPLOAD TO CLOUD (runs once after all versions are processed) ---
    if ($Config.CloudUpload -and $Config.CloudUpload.Enable) {
        Write-Host "`n[TASK 3/3] Uploading all artifacts to cloud..." -ForegroundColor Cyan
        # Copy logs to the final output directory for archival and upload
        Write-Host "Copying logs to $FinalOutputDir..." -ForegroundColor Cyan
        Copy-Item -Path $LogDir -Destination $FinalOutputDir -Recurse -Force
        & "$ScriptDir/Tools/upload_to_cloud.ps1" -SourceDirectory $FinalOutputDir -ConfigPath $ConfigPath
        if ($LASTEXITCODE -ne 0) { throw "Cloud upload failed." }
    } else {
        Write-Host "`n[TASK 3/3] Skipping cloud upload (disabled in config)." -ForegroundColor Yellow
    }

} catch {
    $GlobalSuccess = $false
    Write-Error "`n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!`n!!!! MASTER PIPELINE FAILED !!!!`n!!!! Error: $($_.Exception.Message)`n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!`n"
} finally {
    # Always clean up the temporary staging directory
    if (Test-Path $TempStagingDir) {
        Write-Host "`nCleaning up temporary staging directory: $TempStagingDir" -ForegroundColor Gray
        Remove-Item -Path $TempStagingDir -Recurse -Force
    }

    Write-Host "`n================================================================="
    if ($GlobalSuccess) {
        Write-Host " MASTER PIPELINE COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    } else {
        Write-Host " One or more tasks in the master pipeline FAILED." -ForegroundColor Red
    }
    Write-Host "================================================================="
}

# Only prompt for input if running interactively (not called from another script)
if ($Host.Name -eq "ConsoleHost") {
    Read-Host "Press Enter to exit"
}

# Exit with appropriate code
exit $(if ($GlobalSuccess) { 0 } else { 1 })