<#
.SYNOPSIS
    A script to automate the testing, packaging, and zipping of an Unreal Engine plugin across multiple engine versions.
.DESCRIPTION
    This script reads its configuration from 'config.json', then for each specified engine version it:
    1. Creates a clean host project instance from a template (and generates the template if it's missing).
    2. Updates the .uplugin file with the correct engine version.
    3. (Optional) Runs automation tests.
    4. Packages the plugin for distribution using RunUAT.bat.
    5. Cleans the packaged plugin by removing Intermediate and Binaries folders.
    6. Zips the final, clean plugin into a distributable archive.
    All detailed output is redirected to log files in the 'Logs' directory.
.NOTES
    Author: Prajwal Shetty
    Version: 1.8
#>

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$GlobalSuccess = $true

# Load configuration from JSON file
$ConfigPath = Join-Path -Path $ScriptDir -ChildPath "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found at '$ConfigPath'. Please copy 'config.example.json' to 'config.json' and edit it."
    exit 1
}
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# --- PREREQUISITE CHECKS ---
$TemplateProjectPath = Join-Path -Path $ScriptDir -ChildPath $Config.TemplateProjectDirectory
if (-not (Test-Path $TemplateProjectPath)) {
    Write-Host "Template Project not found. Attempting to generate it automatically..." -ForegroundColor Yellow
    $GeneratorScriptPath = Join-Path -Path $ScriptDir -ChildPath "Tools/CreateTemplateProject.ps1"
    if (-not (Test-Path $GeneratorScriptPath)) {
        Write-Error "Could not find the template generator script at '$GeneratorScriptPath'. Please ensure the 'Tools' folder and its contents are present."
        exit 1
    }
    
    & $GeneratorScriptPath
    
    if (-not (Test-Path $TemplateProjectPath)) {
        Write-Error "Failed to automatically generate the template project. Please run './Tools/CreateTemplateProject.ps1' manually to diagnose the issue."
        exit 1
    }
    Write-Host "[SUCCESS] Template project generated successfully." -ForegroundColor Green
}

if (-not (Test-Path $Config.PluginSourceDirectory)) {
    Write-Error "Plugin source directory not found at '$($Config.PluginSourceDirectory)'. Please check your config.json."
    exit 1
}

# --- Create a timestamped output directory to avoid overwriting builds ---
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputBuildsDir = Join-Path -Path $ScriptDir -ChildPath "$($Config.OutputDirectory)_$Timestamp"
$LogsDir = Join-Path -Path $ScriptDir -ChildPath "Logs"
New-Item -Path $OutputBuildsDir -ItemType Directory -Force | Out-Null
New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null

# --- MAIN EXECUTION LOOP ---
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " STARTING UNREAL PLUGIN LOCAL CI/CD PIPELINE" -ForegroundColor Green
Write-Host "================================================================="
Write-Host "Plugin: $($Config.PluginName)"
Write-Host "Outputting to: $OutputBuildsDir"

foreach ($EngineVersion in $Config.EngineVersions) {
    $CurrentStage = "SETUP"
    $EnginePath = "C:/Program Files/Epic Games/UE_$EngineVersion"
    $LogFile = Join-Path -Path $LogsDir -ChildPath "BuildLog_UE_${EngineVersion}_$Timestamp.txt"
    $ProjectBuildDir = Join-Path -Path $OutputBuildsDir -ChildPath "UE_${EngineVersion}_ProjectHost"
    $PackageOutputDir = Join-Path -Path $OutputBuildsDir -ChildPath "PackagedPlugin_${EngineVersion}"
    $ZipFilePath = Join-Path -Path $OutputBuildsDir -ChildPath "$($Config.PluginName)_UE_$EngineVersion.zip"

    Write-Host "`n-----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " [TASK] Starting pipeline for Unreal Engine $EngineVersion" -ForegroundColor Yellow
    Write-Host " (Full log will be saved to: $LogFile)" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------------------------"

    try {
        if (-not (Test-Path $EnginePath)) {
            throw "[SKIP] Engine not found at '$EnginePath'"
        }

        # --- 1. SETUP STAGE ---
        $CurrentStage = "SETUP"
        Write-Host "[1/6] [SETUP] Creating clean project instance in '$ProjectBuildDir'..."
        if (Test-Path $ProjectBuildDir) { Remove-Item -Recurse -Force -Path $ProjectBuildDir }
        Copy-Item -Recurse -Force -Path $TemplateProjectPath -Destination $ProjectBuildDir
        Copy-Item -Recurse -Force -Path $Config.PluginSourceDirectory -Destination (Join-Path $ProjectBuildDir "Plugins/$($Config.PluginName)")
        
        $CurrentUpluginPath = Join-Path $ProjectBuildDir "Plugins/$($Config.PluginName)/$($Config.PluginName).uplugin"

        # --- 2. UPDATE STAGE ---
        $CurrentStage = "UPDATE_UPLUGIN"
        Write-Host "[2/6] [UPDATE] Setting EngineVersion to '$($EngineVersion).0'..."
        $UpluginJson = Get-Content -Raw -Path $CurrentUpluginPath | ConvertFrom-Json
        $UpluginJson.EngineVersion = "$($EngineVersion).0"
        $UpluginJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $CurrentUpluginPath -Encoding utf8

        # --- 3. TEST STAGE (Optional) ---
        $CurrentStage = "TESTING"
        if ($Config.RunTests) {
            Write-Host "[3/6] [TEST] Running automation tests..."
            & "$EnginePath/Engine/Build/BatchFiles/RunUAT.bat" RunTests -project="$ProjectBuildDir/TemplateProject.uproject" -test="$($Config.AutomationTestFilter)" -build=never *>&1 | Tee-Object -FilePath $LogFile -Append
            if ($LASTEXITCODE -ne 0) { throw "Automation tests failed." }
            Write-Host "[SUCCESS] Tests passed." -ForegroundColor Green
        } else {
            Write-Host "[3/6] [SKIP] Skipping automation tests as per config.json."
        }

        # --- 4. PACKAGE STAGE ---
        $CurrentStage = "PACKAGING"
        Write-Host "[4/6] [PACKAGE] Creating distributable plugin package..."
        & "$EnginePath/Engine/Build/BatchFiles/RunUAT.bat" BuildPlugin -Plugin="$CurrentUpluginPath" -Package="$PackageOutputDir" -Rocket *>&1 | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Packaging failed." }
        Write-Host "[SUCCESS] Plugin packaged successfully." -ForegroundColor Green

        # --- 5. CLEANUP STAGE ---
        $CurrentStage = "CLEANUP"
        Write-Host "[5/6] [CLEANUP] Deleting Binaries and Intermediate folders..."
        $PackagedPluginPath = Join-Path $PackageOutputDir "HostProject/Plugins/$($Config.PluginName)"
        if(Test-Path $PackagedPluginPath) {
            Remove-Item -Recurse -Force -Path (Join-Path $PackagedPluginPath "Intermediate") -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force -Path (Join-Path $PackagedPluginPath "Binaries") -ErrorAction SilentlyContinue
        } else {
            # In some engine versions, the output path might be different.
            $PackagedPluginPath = $PackageOutputDir
            if(Test-Path $PackagedPluginPath) {
                Remove-Item -Recurse -Force -Path (Join-Path $PackagedPluginPath "Intermediate") -ErrorAction SilentlyContinue
                Remove-Item -Recurse -Force -Path (Join-Path $PackagedPluginPath "Binaries") -ErrorAction SilentlyContinue
            } else {
                 throw "Could not find the packaged plugin path to clean."
            }
        }
        

        # --- 6. ZIP STAGE ---
        $CurrentStage = "ZIPPING"
        Write-Host "[6/6] [ZIP] Creating final zip archive..."
        # FIX: Correctly define the source path for zipping
        $ZipSourcePath = Join-Path $PackageOutputDir "HostProject/Plugins/$($Config.PluginName)"
        
        # In case the directory structure is different for some engine versions
        if (-not (Test-Path $ZipSourcePath)) {
            $ZipSourcePath = $PackageOutputDir
        }

        if (Test-Path $ZipSourcePath) {
            Compress-Archive -Path "$ZipSourcePath/*" -DestinationPath $ZipFilePath -Force
            if ($LASTEXITCODE -ne 0) { throw "Zipping failed." }
            
            # Clean up the entire temporary package directory AFTER zipping
            Remove-Item -Recurse -Force -Path $PackageOutputDir
            
            Write-Host "[SUCCESS] UE $EngineVersion pipeline finished successfully!" -ForegroundColor Green
        } else {
            throw "Packaged plugin path not found for zipping: $ZipSourcePath"
        }

    } catch {
        $GlobalSuccess = $false
        Write-Error "`n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        Write-Error "!!!! BUILD FAILED for UE $EngineVersion at stage: $CurrentStage !!!!`n"
        Write-Error "!!!! Error: $($_.Exception.Message)"
        Write-Error "!!!! Check the log file for details: $LogFile"
        Write-Error "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    }
}

# --- FINAL SUMMARY ---
Write-Host "`n================================================================="
if ($GlobalSuccess) {
    Write-Host " All tasks completed SUCCESSFULLY!" -ForegroundColor Green
} else {
    Write-Host " One or more tasks FAILED. Please review the logs." -ForegroundColor Red
}
Write-Host "================================================================="

Read-Host "Press Enter to exit"