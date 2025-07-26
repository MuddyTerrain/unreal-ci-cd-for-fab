<#
.SYNOPSIS
    Master CI/CD pipeline script to build, package, and upload an Unreal Engine plugin.
.DESCRIPTION
    This master script runs the entire local pipeline:
    1. Packages the plugin for multiple engine versions.
    2. (Optional) Packages C++ and/or Blueprint example projects for each version.
    3. (Optional) Uploads all artifacts to a configured cloud provider using rclone.
.NOTES
    Author: Prajwal Shetty
    Version: 2.0
#>

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$ConfigPath = Join-Path -Path $ScriptDir -ChildPath "config.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file (config.json) not found at '$ConfigPath'."
    exit 1
}
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

$GlobalSuccess = $true
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$MainOutputDir = Join-Path -Path $ScriptDir -ChildPath "$($Config.OutputDirectory)_$Timestamp"
New-Item -ItemType Directory -Path $MainOutputDir -Force | Out-Null

# --- MAIN EXECUTION ---
Write-Host "=================================================================" -ForegroundColor Magenta
Write-Host " STARTING MASTER PIPELINE (Output to: $MainOutputDir)" -ForegroundColor Magenta
Write-Host "================================================================="

try {
    # --- 1. PACKAGE PLUGIN ---
    Write-Host "`n[TASK 1/3] Running plugin packaging script..." -ForegroundColor Cyan
    & "$ScriptDir/Tools/package_fast.ps1" -OutputDirectory $MainOutputDir
    if ($LASTEXITCODE -ne 0) { throw "Plugin packaging failed." }

    # --- 2. PACKAGE EXAMPLE PROJECTS ---
    if ($Config.ExampleProject -and $Config.ExampleProject.Generate) {
        Write-Host "`n[TASK 2/3] Running example project packaging script..." -ForegroundColor Cyan
        & "$ScriptDir/Tools/package_example_project.ps1" -OutputDirectory $MainOutputDir
        if ($LASTEXITCODE -ne 0) { throw "Example project packaging failed." }
    } else {
        Write-Host "`n[TASK 2/3] Skipping example project generation (disabled in config)." -ForegroundColor Yellow
    }

    # --- 3. UPLOAD TO CLOUD ---
    if ($Config.CloudUpload -and $Config.CloudUpload.Enable) {
        Write-Host "`n[TASK 3/3] Uploading artifacts to cloud..." -ForegroundColor Cyan
        & "$ScriptDir/Tools/upload_to_cloud.ps1" -SourceDirectory $MainOutputDir
        if ($LASTEXITCODE -ne 0) { throw "Cloud upload failed." }
    } else {
        Write-Host "`n[TASK 3/3] Skipping cloud upload (disabled in config)." -ForegroundColor Yellow
    }

} catch {
    $GlobalSuccess = $false
    Write-Error "`n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Error "!!!! MASTER PIPELINE FAILED !!!!"
    Write-Error "!!!! Error: $($_.Exception.Message)"
    Write-Error "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
} finally {
    Write-Host "`n================================================================="
    if ($GlobalSuccess) {
        Write-Host " MASTER PIPELINE COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    } else {
        Write-Host " One or more tasks in the master pipeline FAILED." -ForegroundColor Red
    }
    Write-Host "================================================================="
}

Read-Host "Press Enter to exit"
