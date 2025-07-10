<#
.SYNOPSIS
    Automates testing, packaging, and zipping of an Unreal Engine plugin across multiple engine versions.

.DESCRIPTION
    Reads configuration from 'config.json' and, for each engine version:
    1. Creates a host project from a clean template and adds the source plugin.
    2. Packages the plugin for distribution.
    3. Creates a test project with the packaged plugin installed.
    4. Zips both the packaged plugin and the test project for distribution.
    All operations are logged to timestamped log files. The source plugin directory is never modified.

.NOTES
    Author: Prajwal Shetty
    Version: 2.0
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

# --- Create a timestamped output directory ---
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
    $EnginePath = Join-Path -Path $Config.UnrealEngineBasePath -ChildPath "UE_$EngineVersion"
    $LogFile = Join-Path -Path $LogsDir -ChildPath "BuildLog_UE_${EngineVersion}_$Timestamp.txt"
    $HostProjectDir = Join-Path -Path $OutputBuildsDir -ChildPath "UE_${EngineVersion}_HostProject"
    $TestProjectDir = Join-Path -Path $OutputBuildsDir -ChildPath "UE_${EngineVersion}_TestProject"
    $PackageOutputDir = Join-Path -Path $OutputBuildsDir -ChildPath "PackagedPlugin_${EngineVersion}"
    $PluginZipPath = Join-Path -Path $OutputBuildsDir -ChildPath "$($Config.PluginName)_UE_$EngineVersion.zip"
    $TestProjectZipPath = Join-Path -Path $OutputBuildsDir -ChildPath "TestProject_UE_$EngineVersion.zip"

    Write-Host "`n-----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " [TASK] Starting pipeline for Unreal Engine $EngineVersion" -ForegroundColor Yellow
    Write-Host " (Full log will be saved to: $LogFile)" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------------------------"

    try {
        if (-not (Test-Path $EnginePath)) {
            throw "[SKIP] Engine not found at '$EnginePath'"
        }

        # --- 1. SETUP HOST PROJECT ---
        $CurrentStage = "SETUP_HOST_PROJECT"
        Write-Host "[1/6] [SETUP] Creating host project in '$HostProjectDir'..."
        if (Test-Path $HostProjectDir) { Remove-Item -Recurse -Force -Path $HostProjectDir }
        Copy-Item -Recurse -Force -Path $TemplateProjectPath -Destination $HostProjectDir
        $HostUprojectPath = Join-Path -Path $HostProjectDir -ChildPath "TemplateProject.uproject"
        $HostPluginDir = Join-Path -Path $HostProjectDir -ChildPath "Plugins/$($Config.PluginName)"
        Copy-Item -Recurse -Force -Path $Config.PluginSourceDirectory -Destination $HostPluginDir
        $HostUpluginPath = Join-Path -Path $HostPluginDir -ChildPath "$($Config.PluginName).uplugin"

        # Update host project's .uproject to set EngineAssociation and add plugin
        $HostUprojectJson = Get-Content -Raw -Path $HostUprojectPath | ConvertFrom-Json
        $HostUprojectJson.EngineAssociation = $EngineVersion
        if (-not $HostUprojectJson.Plugins) { $HostUprojectJson.Plugins = @() }
        $HostUprojectJson.Plugins += @{ Name = $Config.PluginName; Enabled = $true }
        $HostUprojectJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $HostUprojectPath -Encoding utf8

        # --- 2. UPDATE UPLUGIN ---
        $CurrentStage = "UPDATE_UPLUGIN"
        Write-Host "[2/6] [UPDATE] Setting EngineVersion in .uplugin to '$($EngineVersion).0'..."
        $UpluginJson = Get-Content -Raw -Path $HostUpluginPath | ConvertFrom-Json
        $UpluginJson.EngineVersion = "$($EngineVersion).0"
        $UpluginJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $HostUpluginPath -Encoding utf8

        # --- 3. PACKAGE PLUGIN ---
        $CurrentStage = "PACKAGING"
        Write-Host "[3/6] [PACKAGE] Packaging plugin..."
        & "$EnginePath/Engine/Build/BatchFiles/RunUAT.bat" BuildPlugin -Plugin="$HostUpluginPath" -Package="$PackageOutputDir" -Rocket *>&1 | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Packaging failed." }
        Write-Host "[SUCCESS] Plugin packaged successfully." -ForegroundColor Green

        # --- 4. SETUP TEST PROJECT ---
        $CurrentStage = "SETUP_TEST_PROJECT"
        Write-Host "[4/6] [SETUP] Creating test project in '$TestProjectDir'..."
        if (Test-Path $TestProjectDir) { Remove-Item -Recurse -Force -Path $TestProjectDir }
        Copy-Item -Recurse -Force -Path $TemplateProjectPath -Destination $TestProjectDir
        $TestUprojectPath = Join-Path -Path $TestProjectDir -ChildPath "TemplateProject.uproject"
        $TestPluginDir = Join-Path -Path $TestProjectDir -ChildPath "Plugins/$($Config.PluginName)"
        $PackagedPluginPath = Join-Path -Path $PackageOutputDir -ChildPath $Config.PluginName
        Copy-Item -Recurse -Force -Path $PackagedPluginPath -Destination $TestPluginDir

        # Update test project's .uproject to set EngineAssociation and add plugin
        $TestUprojectJson = Get-Content -Raw -Path $TestUprojectPath | ConvertFrom-Json
        $TestUprojectJson.EngineAssociation = $EngineVersion
        if (-not $TestUprojectJson.Plugins) { $TestUprojectJson.Plugins = @() }
        $TestUprojectJson.Plugins += @{ Name = $Config.PluginName; Enabled = $true }
        $TestUprojectJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $TestUprojectPath -Encoding utf8

        # --- 5. ZIP PACKAGED PLUGIN ---
        $CurrentStage = "ZIPPING_PLUGIN"
        Write-Host "[5/6] [ZIP] Zipping packaged plugin..."
        Compress-Archive -Path "$PackagedPluginPath/*" -DestinationPath $PluginZipPath -Force
        if ($LASTEXITCODE -ne 0) { throw "Zipping plugin failed." }

        # --- 6. ZIP TEST PROJECT ---
        $CurrentStage = "ZIPPING_TEST_PROJECT"
        Write-Host "[6/6] [ZIP] Zipping test project..."
        Compress-Archive -Path "$TestProjectDir/*" -DestinationPath $TestProjectZipPath -Force
        if ($LASTEXITCODE -ne 0) { throw "Zipping test project failed." }

        Write-Host "[SUCCESS] UE $EngineVersion pipeline finished successfully!" -ForegroundColor Green

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