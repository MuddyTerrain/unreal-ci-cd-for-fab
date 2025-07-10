<#
.SYNOPSIS
    Automates testing, packaging, and zipping of an Unreal Engine plugin across multiple engine versions.
.DESCRIPTION
    For each engine version, this script temporarily creates a global BuildConfiguration.xml to force the correct
    MSVC toolchain, builds the plugin, cleans it, and creates a final test project.
.NOTES
    Author: Prajwal Shetty
    Version: 5.1
#>

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$GlobalSuccess = $true

# Load configuration
$ConfigPath = Join-Path -Path $ScriptDir -ChildPath "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found at '$ConfigPath'."
    exit 1
}
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# --- Get Plugin Version from .uplugin file ---
$SourceUpluginPath = Join-Path -Path $Config.PluginSourceDirectory -ChildPath "$($Config.PluginName).uplugin"
if (-not (Test-Path $SourceUpluginPath)) {
    Write-Error "Could not find source .uplugin file at '$SourceUpluginPath'. Check your 'PluginSourceDirectory' and 'PluginName' in config.json."
    exit 1
}
$PluginInfo = Get-Content -Raw -Path $SourceUpluginPath | ConvertFrom-Json
$PluginVersion = $PluginInfo.VersionName

# --- PREREQUISITE CHECKS ---
$TemplateProjectPath = Join-Path -Path $ScriptDir -ChildPath $Config.TemplateProjectDirectory
if (-not (Test-Path $TemplateProjectPath)) {
    New-Item -Path $TemplateProjectPath -ItemType Directory -Force | Out-Null
}

if (-not (Test-Path $Config.PluginSourceDirectory)) {
    Write-Error "Plugin source directory not found at '$($Config.PluginSourceDirectory)'."
    exit 1
}

# --- Create timestamped output directory ---
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputBuildsDir = Join-Path -Path $ScriptDir -ChildPath "$($Config.OutputDirectory)_$Timestamp"
$LogsDir = Join-Path -Path $ScriptDir -ChildPath "Logs"
New-Item -Path $OutputBuildsDir -ItemType Directory -Force | Out-Null
New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null

# --- MAIN EXECUTION LOOP ---
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " STARTING UNREAL PLUGIN LOCAL CI/CD PIPELINE" -ForegroundColor Green
Write-Host "================================================================="
Write-Host "Plugin: $($Config.PluginName) v$($PluginVersion)"
Write-Host "Outputting to: $OutputBuildsDir"

# --- Define path for the GLOBAL BuildConfiguration.xml ---
$UserBuildConfigDir = Join-Path -Path $HOME -ChildPath "Documents/Unreal Engine/UnrealBuildTool"
$UserBuildConfigPath = Join-Path -Path $UserBuildConfigDir -ChildPath "BuildConfiguration.xml"
$UserBuildConfigBackupPath = Join-Path -Path $UserBuildConfigDir -ChildPath "BuildConfiguration.xml.bak"


foreach ($EngineVersion in $Config.EngineVersions) {
    $CurrentStage = "SETUP"
    $EnginePath = Join-Path -Path $Config.UnrealEngineBasePath -ChildPath "UE_$EngineVersion"
    $LogFile = Join-Path -Path $LogsDir -ChildPath "BuildLog_UE_${EngineVersion}_$Timestamp.txt"

    # Define paths
    $HostProjectDir = Join-Path -Path $OutputBuildsDir -ChildPath "UE_${EngineVersion}_HostProject"
    $PackageOutputDir = Join-Path -Path $OutputBuildsDir -ChildPath "PackagedPlugin_Raw_${EngineVersion}"
    $CleanedPluginStageDir = Join-Path -Path $OutputBuildsDir -ChildPath "Staging_${EngineVersion}"
    $FinalPluginZipPath = Join-Path -Path $OutputBuildsDir -ChildPath "$($Config.PluginName)_v$($PluginVersion)_ue$($EngineVersion).zip"
    $TestProjectDir = Join-Path -Path $OutputBuildsDir -ChildPath "UE_${EngineVersion}_TestProject"


    Write-Host "`n-----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " [TASK] Starting pipeline for Unreal Engine $EngineVersion" -ForegroundColor Yellow
    Write-Host " (Full log will be saved to: $LogFile)" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------------------------"

    try {
        # --- Backup and Create Global Build Config ---
        $CurrentStage = "SETUP_BUILD_CONFIG"
        Write-Host "[1/5] [CONFIG] Setting up global build configuration for UE $EngineVersion..."
        New-Item -Path $UserBuildConfigDir -ItemType Directory -Force | Out-Null
        if (Test-Path $UserBuildConfigPath) {
            Rename-Item -Path $UserBuildConfigPath -NewName "BuildConfiguration.xml.bak" -Force
        }
        $ToolchainVersion = switch ($EngineVersion) {
            "5.1" { "14.32.31326" }
            "5.2" { "14.34.31933" }
            "5.3" { "14.36.32532" }
            "5.4" { "14.38.33130" }
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

        # --- 2. SETUP HOST PROJECT ---
        $CurrentStage = "SETUP_HOST_PROJECT"
        Write-Host "[2/5] [SETUP] Creating host project..."
        if (Test-Path $HostProjectDir) { Remove-Item -Recurse -Force -Path $HostProjectDir }
        Copy-Item -Recurse -Force -Path $TemplateProjectPath -Destination $HostProjectDir
        $HostUprojectPath = Join-Path -Path $HostProjectDir -ChildPath "HostProject.uproject"
        @{ FileVersion = 3; EngineAssociation = $EngineVersion; Category = ""; Description = ""; Plugins = @(@{ Name = $Config.PluginName; Enabled = $true }) } | ConvertTo-Json -Depth 5 | Out-File -FilePath $HostUprojectPath -Encoding utf8
        $HostPluginDir = Join-Path -Path $HostProjectDir -ChildPath "Plugins/$($Config.PluginName)"
        Copy-Item -Recurse -Force -Path $Config.PluginSourceDirectory -Destination $HostPluginDir

        # --- 3. UPDATE UPLUGIN ---
        $CurrentStage = "UPDATE_UPLUGIN"
        Write-Host "[3/5] [UPDATE] Setting EngineVersion in .uplugin..."
        $HostUpluginPath = Join-Path -Path $HostPluginDir -ChildPath "$($Config.PluginName).uplugin"
        $UpluginJson = Get-Content -Raw -Path $HostUpluginPath | ConvertFrom-Json
        $UpluginJson.EngineVersion = "$($EngineVersion).0"
        $UpluginJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $HostUpluginPath -Encoding utf8

        # --- 4. PACKAGE PLUGIN (RAW) ---
        $CurrentStage = "PACKAGING"
        Write-Host "[4/5] [PACKAGE] Packaging plugin (raw)..."
        & "$EnginePath/Engine/Build/BatchFiles/RunUAT.bat" BuildPlugin -Plugin="$HostUpluginPath" -Package="$PackageOutputDir" -Rocket *>&1 | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Packaging failed." }

        # --- 5. CLEAN & FINALIZE ---
        $CurrentStage = "FINALIZE"
        Write-Host "[5/5] [FINALIZE] Creating distributable zip and test project..."
        if (Test-Path $CleanedPluginStageDir) { Remove-Item -Recurse -Force -Path $CleanedPluginStageDir }
        New-Item -Path $CleanedPluginStageDir -ItemType Directory -Force | Out-Null
        
        # --- FIX: Correctly path to the packaged plugin inside the HostProject structure ---
        $SourceForCleaning = Join-Path -Path $PackageOutputDir -ChildPath "HostProject/Plugins/$($Config.PluginName)"
        
        "Source", "Content", "Resources" | ForEach-Object {
            $SourcePath = Join-Path -Path $SourceForCleaning -ChildPath $_
            if (Test-Path $SourcePath) { Copy-Item -Recurse -Force -Path $SourcePath -Destination (Join-Path -Path $CleanedPluginStageDir -ChildPath $_) }
        }
        Copy-Item -Force -Path (Join-Path $SourceForCleaning "$($Config.PluginName).uplugin") -Destination (Join-Path -Path $CleanedPluginStageDir -ChildPath "$($Config.PluginName).uplugin")
        Compress-Archive -Path "$CleanedPluginStageDir/*" -DestinationPath $FinalPluginZipPath -Force

        if (Test-Path $TestProjectDir) { Remove-Item -Recurse -Force -Path $TestProjectDir }
        Copy-Item -Recurse -Force -Path $TemplateProjectPath -Destination $TestProjectDir
        $TestUprojectPath = Join-Path -Path $TestProjectDir -ChildPath "TestProject.uproject"
        @{ FileVersion = 3; EngineAssociation = $EngineVersion; Category = ""; Description = ""; Plugins = @(@{ Name = $Config.PluginName; Enabled = $true; }) } | ConvertTo-Json -Depth 5 | Out-File -FilePath $TestUprojectPath -Encoding utf8
        $TestPluginDir = Join-Path -Path $TestProjectDir -ChildPath "Plugins/$($Config.PluginName)"
        Expand-Archive -Path $FinalPluginZipPath -DestinationPath $TestPluginDir -Force

        Write-Host "[SUCCESS] UE $EngineVersion pipeline finished successfully!" -ForegroundColor Green

    } catch {
        $GlobalSuccess = $false
        Write-Error "`n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        Write-Error "!!!! BUILD FAILED for UE $EngineVersion at stage: $CurrentStage !!!!`n"
        Write-Error "!!!! Error: $($_.Exception.Message)"
        Write-Error "!!!! Check the log file for details: $LogFile"
        Write-Error "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    } finally {
        # --- Cleanup Global Build Config ---
        if (Test-Path $UserBuildConfigPath) { Remove-Item -Path $UserBuildConfigPath -Force }
        if (Test-Path $UserBuildConfigBackupPath) {
            Rename-Item -Path $UserBuildConfigBackupPath -NewName "BuildConfiguration.xml" -Force
        }
    }
}

# --- FINAL SUMMARY ---
Write-Host "`n================================================================="
if ($GlobalSuccess) {
    Write-Host " All tasks completed SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "Your builds are available in '$OutputBuildsDir'" -ForegroundColor Green
} else {
    Write-Host " One or more tasks FAILED. Please review the logs." -ForegroundColor Red
}
Write-Host "================================================================="

Read-Host "Press Enter to exit"