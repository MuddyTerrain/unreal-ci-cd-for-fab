<#
.SYNOPSIS
    A script to automate the testing, packaging, and zipping of an Unreal Engine plugin across multiple engine versions.
.DESCRIPTION
    This script reads its configuration from 'config.json', then for each specified engine version it:
    1. Creates a clean host project instance.
    2. Updates the .uplugin file with the correct engine version.
    3. (Optional) Runs automation tests.
    4. Packages the plugin for distribution using RunUAT.bat.
    5. Cleans the packaged plugin by removing Intermediate and Binaries folders.
    6. Zips the final, clean plugin into a distributable archive.
    All detailed output is redirected to log files in the 'Logs' directory.
.NOTES
    Author: Prajwal Shetty
    Version: 1.0
#>

# --- PREPARATION ---
# Get the directory where the script is located
$ScriptDir = $PSScriptRoot

# Load configuration from JSON file
$ConfigPath = Join-Path -Path $ScriptDir -ChildPath "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found at '$ConfigPath'. Please copy 'config.example.json' to 'config.json' and edit it."
    exit 1
}
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# Create output directories if they don't exist
$OutputBuildsDir = Join-Path -Path $ScriptDir -ChildPath $Config.OutputDirectory
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
    # --- PER-VERSION SETUP ---
    $EnginePath = "C:/Program Files/Epic Games/UE_$EngineVersion"
    $LogFile = Join-Path -Path $LogsDir -ChildPath "BuildLog_UE_$EngineVersion.txt"
    $ProjectBuildDir = Join-Path -Path $OutputBuildsDir -ChildPath "UE_`"$EngineVersion`"_ProjectHost"
    $PackageOutputDir = Join-Path -Path $OutputBuildsDir -ChildPath "PackagedPlugin_`"$EngineVersion`""
    $ZipFilePath = Join-Path -Path $OutputBuildsDir -ChildPath "$($Config.PluginName)_UE_$EngineVersion.zip"

    Write-Host "`n-----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " [TASK] Starting pipeline for Unreal Engine $EngineVersion" -ForegroundColor Yellow
    Write-Host " (Full log will be saved to: $LogFile)" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------------------------"

    if (-not (Test-Path $EnginePath)) {
        Write-Warning "[SKIP] Engine not found at '$EnginePath'"
        continue
    }

    try {
        # --- 1. SETUP STAGE ---
        Write-Host "[1/6] [SETUP] Creating clean project instance..."
        if (Test-Path $ProjectBuildDir) {
            Remove-Item -Recurse -Force -Path $ProjectBuildDir
        }
        Copy-Item -Recurse -Force -Path (Join-Path -Path $ScriptDir -ChildPath $Config.TemplateProjectDirectory) -Destination $ProjectBuildDir
        Copy-Item -Recurse -Force -Path $Config.PluginSourceDirectory -Destination (Join-Path $ProjectBuildDir "Plugins/$($Config.PluginName)")
        
        $CurrentUpluginPath = Join-Path $ProjectBuildDir "Plugins/$($Config.PluginName)/$($Config.PluginName).uplugin"

        # --- 2. UPDATE STAGE ---
        Write-Host "[2/6] [UPDATE] Setting EngineVersion to '$($EngineVersion).0'..."
        $UpluginJson = Get-Content -Raw -Path $CurrentUpluginPath | ConvertFrom-Json
        $UpluginJson.EngineVersion = "$($EngineVersion).0"
        $UpluginJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $CurrentUpluginPath -Encoding utf8

        # --- 3. TEST STAGE (Optional) ---
        if ($Config.RunTests) {
            Write-Host "[3/6] [TEST] Running automation tests..."
            & "$EnginePath/Engine/Build/BatchFiles/RunUAT.bat" RunTests -project="$ProjectBuildDir/TemplateProject.uproject" -test="$($Config.AutomationTestFilter)" -build=never *>&1 | Tee-Object -FilePath $LogFile -Append
            if ($LASTEXITCODE -ne 0) { throw "Automation tests failed." }
            Write-Host "[SUCCESS] Tests passed." -ForegroundColor Green
        } else {
            Write-Host "[3/6] [SKIP] Skipping automation tests as per config.json."
        }

        # --- 4. PACKAGE STAGE ---
        Write-Host "[4/6] [PACKAGE] Creating distributable plugin package..."
        & "$EnginePath/Engine/Build/BatchFiles/RunUAT.bat" BuildPlugin -Plugin="$CurrentUpluginPath" -Package="$PackageOutputDir" -Rocket *>&1 | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Packaging failed." }
        Write-Host "[SUCCESS] Plugin packaged successfully." -ForegroundColor Green

        # --- 5. CLEANUP STAGE ---
        Write-Host "[5/6] [CLEANUP] Deleting Binaries and Intermediate folders..."
        Remove-Item -Recurse -Force -Path (Join-Path $PackageOutputDir "$($Config.PluginName)/Intermediate")
        Remove-Item -Recurse -Force -Path (Join-Path $PackageOutputDir "$($Config.PluginName)/Binaries")

        # --- 6. ZIP STAGE ---
        Write-Host "[6/6] [ZIP] Creating final zip archive..."
        Compress-Archive -Path (Join-Path $PackageOutputDir "$($Config.PluginName)/*") -DestinationPath $ZipFilePath -Force
        if ($LASTEXITCODE -ne 0) { throw "Zipping failed." }
        
        # Clean up the temporary package folder
        Remove-Item -Recurse -Force -Path $PackageOutputDir
        
        Write-Host "[SUCCESS] UE $EngineVersion pipeline finished successfully!" -ForegroundColor Green

    } catch {
        Write-Error "`n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        Write-Error "!!!! BUILD FAILED for UE $EngineVersion !!!!`n"
        Write-Error "Error: $($_.Exception.Message)"
        Write-Error "Check the log file for details: $LogFile"
        Write-Error "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        exit 1
    }
}

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " All tasks completed SUCCESSFULLY!" -ForegroundColor Green
Write-Host "================================================================="
Read-Host "Press Enter to exit"
