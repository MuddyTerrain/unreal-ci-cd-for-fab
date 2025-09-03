<#
.SYNOPSIS
    Packages C++ and Blueprint example projects for multiple Unreal Engine versions.
.DESCRIPTION
    Uses a "Develop Low, Upgrade High" workflow. It takes a master project
    (developed in the oldest supported engine version), and for each version in the
    config, it:
    1. Creates a smart copy (excluding .git, build artifacts, etc.)
    2. Compiles the plugin for the target engine version first (if not excluded).
    3. Builds the main project C++ to prevent popups.
    4. Upgrades the project to the target engine version.
    5. Packages C++ and/or Blueprint-only versions directly to the final output directory.
.NOTES
    Author: Prajwal Shetty
    Version: 5.0 - Major refactor for packaging correctness.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$OutputDirectory, # This is the temporary staging directory

    [Parameter(Mandatory=$true)]
    [string]$FinalOutputDir,   # This is the final /Builds directory

    [Parameter(Mandatory=$false)]
    [string]$EngineVersion,

    [Parameter(Mandatory=$false)]
    [switch]$UseCache
)

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigPath = Join-Path -Path $ProjectRoot -ChildPath "config.json"
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$MasterProjectDir = $Config.ExampleProject.MasterProjectDirectory
$LogsDir = Join-Path -Path $ProjectRoot -ChildPath "Logs"

if (-not (Test-Path $MasterProjectDir)) {
    throw "Master example project not found at '$MasterProjectDir'. Please check your config.json."
}
$MasterUProjectFile = Get-ChildItem -Path $MasterProjectDir -Filter "*.uproject" | Select-Object -First 1
$MasterProjectName = $MasterUProjectFile.BaseName

# Define path for the GLOBAL BuildConfiguration.xml
$UserBuildConfigDir = Join-Path -Path $HOME -ChildPath "Documents/Unreal Engine/UnrealBuildTool"
$UserBuildConfigPath = Join-Path -Path $UserBuildConfigDir -ChildPath "BuildConfiguration.xml"
$UserBuildConfigBackupPath = Join-Path -Path $UserBuildConfigDir -ChildPath "BuildConfiguration.xml.bak"

# --- MAIN EXECUTION LOOP ---
$VersionsToProcess = if (-not [string]::IsNullOrEmpty($EngineVersion)) { @($EngineVersion) } else { $Config.EngineVersions }

foreach ($CurrentEngineVersion in $VersionsToProcess) {
    $CurrentStage = "SETUP"
    $LogFile = Join-Path -Path $LogsDir -ChildPath "Log_ExampleProject_UE_${CurrentEngineVersion}.txt"
    $EnginePath = Join-Path -Path $Config.UnrealEngineBasePath -ChildPath "UE_$CurrentEngineVersion"
    $TempProjectDir = Join-Path -Path $OutputDirectory -ChildPath "Ex$($CurrentEngineVersion)"
    
    # --- Get Project Version from DefaultGame.ini ---
    $ProjectVersion = "1.0" # Default version
    $GameIniPath = Join-Path -Path $MasterProjectDir -ChildPath "Config/DefaultGame.ini"
    if (Test-Path $GameIniPath) {
        $IniContent = Get-Content $GameIniPath
        $VersionLine = $IniContent | Select-String -Pattern "^\s*ProjectVersion\s*=\s*(.+)$"
        if ($VersionLine) {
            $ProjectVersion = $VersionLine.Matches[0].Groups[1].Value.Trim()
        }
    }

    Write-Host "`n-----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " [EXAMPLE] Processing UE $CurrentEngineVersion for Project v$ProjectVersion" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------------------------"

    # --- CACHE CHECK ---
    $CppExampleExists = $true # Default to true if not generated
    $BpExampleExists = $true  # Default to true if not generated

    if ($Config.ExampleProject.GenerateCppExample) {
        $FinalCppZipPath = Join-Path -Path $FinalOutputDir -ChildPath "$($MasterProjectName)_v$($ProjectVersion)_CPP_UE$($CurrentEngineVersion).zip"
        $CppExampleExists = Test-Path $FinalCppZipPath
    }
    if ($Config.ExampleProject.GenerateBlueprintExample) {
        $FinalBpZipPath = Join-Path -Path $FinalOutputDir -ChildPath "$($MasterProjectName)_v$($ProjectVersion)_BP_UE$($CurrentEngineVersion).zip"
        $BpExampleExists = Test-Path $FinalBpZipPath
    }

    if ($UseCache.IsPresent -and $CppExampleExists -and $BpExampleExists) {
        Write-Host "[CACHE] Skipping UE $CurrentEngineVersion because all example project outputs already exist." -ForegroundColor Cyan
        continue
    }

    try {
        if (-not (Test-Path $EnginePath)) { throw "[SKIP] Engine not found at '$EnginePath'" }

        # --- SETUP BUILD CONFIG ---
        New-Item -Path $UserBuildConfigDir -ItemType Directory -Force | Out-Null
        if (Test-Path $UserBuildConfigPath) {
            Rename-Item -Path $UserBuildConfigPath -NewName "BuildConfiguration.xml.bak" -Force
        }
        
        $ToolchainVersion = switch ($CurrentEngineVersion) {
            "5.1" { "14.32.31326" } 
            "5.2" { "14.34.31933" } 
            "5.3" { "14.36.32532" } 
            "5.4" { "14.38.33130" } 
            "5.5" { "14.38.33130" } 
            "5.6" { "14.38.33130" } 
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

        # --- 1. COPY MASTER PROJECT (SMART COPY) ---
        $CurrentStage = "COPY"
        Write-Host "[1/7] Copying master project..."
        
        $ExcludeDirs = @( ".git", ".vs", ".idea", ".vscode", "Binaries", "Build", "Intermediate", "Saved", "DerivedDataCache", "__pycache__", "Platforms" )
        $ExcludeFiles = @( "*.sln", "*.suo", "*.VC.db", "*.DotSettings.user", ".vsconfig", "GEMINI.md", ".gitignore", ".gitmodules" )
        if ($Config.ExampleProject.ExcludeFiles) {
            $ExcludeFiles += $Config.ExampleProject.ExcludeFiles
        }

        robocopy $MasterProjectDir $TempProjectDir /E /XD $ExcludeDirs /XF $ExcludeFiles /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "Failed to copy master project." }

        $TempUProjectPath = Join-Path -Path $TempProjectDir -ChildPath $MasterUProjectFile.Name
        
        # --- 2. UPDATE UPLUGIN FILE VERSION ---
        $CurrentStage = "UPDATE_UPLUGIN"
        Write-Host "[2/7] Updating .uplugin file version for UE $CurrentEngineVersion..."
        $PluginUpluginPath = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)\$($Config.PluginName).uplugin"
        if (Test-Path $PluginUpluginPath) {
            $PluginJson = Get-Content -Raw -Path $PluginUpluginPath | ConvertFrom-Json
            $PluginJson.EngineVersion = "$($CurrentEngineVersion).0"
            $PluginJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $PluginUpluginPath -Encoding utf8
            Write-Host "Set EngineVersion to $CurrentEngineVersion in .uplugin file." -ForegroundColor Green
        } else {
            Write-Host "No .uplugin file found to update." -ForegroundColor Gray
        }

        # --- 3. COMPILE PLUGIN (if included) ---
        if (-not $Config.ExampleProject.ExcludePlugin) {
            $CurrentStage = "COMPILE_PLUGIN"
            Write-Host "[3/7] Compiling plugin for UE $CurrentEngineVersion..."
            
            $PluginDir = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)"
            if (-not (Test-Path $PluginUpluginPath)) { throw "Plugin .uplugin file not found at: $PluginUpluginPath" }
            
            $RunUATPath = Join-Path -Path $EnginePath -ChildPath "Engine\Build\BatchFiles\RunUAT.bat"
            & $RunUATPath BuildPlugin -Plugin="$PluginUpluginPath" -Package="$PluginDir\Packages" -TargetPlatforms=Win64 -Rocket | Tee-Object -FilePath $LogFile -Append
            if ($LASTEXITCODE -ne 0) { throw "Failed to compile plugin for UE $CurrentEngineVersion." }
        } else {
            Write-Host "[3/7] Skipping plugin compilation (plugin will be excluded from final package)." -ForegroundColor Gray
        }

        # --- 4. BUILD PROJECT (to avoid popups) ---
        $CurrentStage = "BUILD_PROJECT"
        Write-Host "[4/7] Building project editor targets for UE $CurrentEngineVersion..."
        $BuildScriptPath = Join-Path -Path $EnginePath -ChildPath "Engine\Build\BatchFiles\Build.bat"
        & $BuildScriptPath ($MasterProjectName + "Editor") Win64 Development -Project="$TempUProjectPath" | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Failed to build project editor targets for UE $CurrentEngineVersion." }

        # --- 5. UPGRADE PROJECT ---
        $CurrentStage = "UPGRADE"
        Write-Host "[5/7] Upgrading project assets for UE $CurrentEngineVersion..."
        $UnrealEditorPath = Join-Path -Path $EnginePath -ChildPath "Engine/Binaries/Win64/UnrealEditor-Cmd.exe"

        $UProjectJson = Get-Content -Raw -Path $TempUProjectPath | ConvertFrom-Json
        $UProjectJson.EngineAssociation = $CurrentEngineVersion
        $UProjectJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $TempUProjectPath -Encoding utf8

        & $UnrealEditorPath "$TempUProjectPath" -run=ResavePackages -allowcommandletrendering -autocheckout -projectonly | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Failed to resave/upgrade packages." }

        # --- 6. PACKAGE C++ EXAMPLE (OPTIONAL) ---
        $CurrentStage = "PACKAGE_CPP"
        if ($Config.ExampleProject.GenerateCppExample) {
            Write-Host "[6/7] Packaging C++ Example..."
            
            "Binaries", "Intermediate", "Saved", ".vs", "DerivedDataCache" | ForEach-Object {
                $pathToRemove = Join-Path $TempProjectDir $_
                if(Test-Path $pathToRemove) { Remove-Item -Recurse -Force $pathToRemove -ErrorAction SilentlyContinue }
            }
            if (-not $Config.ExampleProject.ExcludePlugin) {
                $PluginPackageDir = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)\Packages"
                if(Test-Path $PluginPackageDir) { Remove-Item -Recurse -Force $PluginPackageDir }
            } else {
                $PluginDirToRemove = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)"
                if (Test-Path $PluginDirToRemove) { Remove-Item -Path $PluginDirToRemove -Recurse -Force }
            }
            
            $FinalZipPath = Join-Path -Path $FinalOutputDir -ChildPath "$($MasterProjectName)_v$($ProjectVersion)_CPP_UE$($CurrentEngineVersion).zip"
            Compress-Archive -Path "$TempProjectDir\*" -DestinationPath $FinalZipPath -Force
            Write-Host "C++ example created at: $FinalZipPath" -ForegroundColor Green
        } else {
             Write-Host "[6/7] Skipping C++ example packaging." -ForegroundColor Gray
        }

        # --- 7. PACKAGE BLUEPRINT EXAMPLE (OPTIONAL) ---
        $CurrentStage = "PACKAGE_BP"
        if ($Config.ExampleProject.GenerateBlueprintExample) {
            Write-Host "[7/7] Creating and packaging Blueprint-only example..."
            
            "Binaries", "Intermediate", "Saved", ".vs", "DerivedDataCache", "Source" | ForEach-Object {
                $pathToRemove = Join-Path $TempProjectDir $_ 
                if(Test-Path $pathToRemove) { Remove-Item -Recurse -Force $pathToRemove -ErrorAction SilentlyContinue }
            }
            Remove-Item -Path "$TempProjectDir\*.sln" -ErrorAction SilentlyContinue

            $UProjectJson = Get-Content -Raw -Path $TempUProjectPath | ConvertFrom-Json
            if ($UProjectJson.PSObject.Properties.Name -contains 'Modules') { $UProjectJson.PSObject.Properties.Remove('Modules') }
            $UProjectJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $TempUProjectPath -Encoding utf8

            if ($Config.ExampleProject.ExcludePlugin) {
                $PluginDirToRemove = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)"
                if (Test-Path $PluginDirToRemove) { Remove-Item -Path $PluginDirToRemove -Recurse -Force }
            } else {
                $PluginDir = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)"
                Remove-Item -Path "$PluginDir\Source" -Recurse -Force -ErrorAction SilentlyContinue
                $PluginUpluginPath = Join-Path -Path $PluginDir -ChildPath "$($Config.PluginName).uplugin"
                if (Test-Path $PluginUpluginPath) {
                    $PluginJson = Get-Content -Raw -Path $PluginUpluginPath | ConvertFrom-Json
                    if ($PluginJson.PSObject.Properties.Name -contains 'Modules') { $PluginJson.PSObject.Properties.Remove('Modules') }
                    $PluginJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $PluginUpluginPath -Encoding utf8
                }
            }
            
            if ($Config.ExampleProject.BlueprintOnlyExcludeFolders) {
                foreach ($ExcludeFolder in $Config.ExampleProject.BlueprintOnlyExcludeFolders) {
                    $FolderToRemove = Join-Path -Path $TempProjectDir -ChildPath $ExcludeFolder
                    if (Test-Path $FolderToRemove) { Remove-Item -Path $FolderToRemove -Recurse -Force }
                }
            }
            
            $FinalZipPath = Join-Path -Path $FinalOutputDir -ChildPath "$($MasterProjectName)_v$($ProjectVersion)_BP_UE$($CurrentEngineVersion).zip"
            Compress-Archive -Path "$TempProjectDir\*" -DestinationPath $FinalZipPath -Force
            Write-Host "Blueprint example created at: $FinalZipPath" -ForegroundColor Green
        } else {
            Write-Host "[7/7] Skipping Blueprint example packaging." -ForegroundColor Gray
        }

    } catch {
        Write-Error "`n!!!! EXAMPLE PROJECT FAILED for UE $CurrentEngineVersion at stage: $CurrentStage !!!!`n!!!! Error: $($_.Exception.Message)`n!!!! See log for details: $LogFile"
        throw
    } finally {
        Write-Host "Cleaning up temporary project for UE $CurrentEngineVersion..."
        if (Test-Path $TempProjectDir) { Remove-Item -Recurse -Force -Path $TempProjectDir }

        if (Test-Path $UserBuildConfigPath) { Remove-Item -Path $UserBuildConfigPath -Force }
        if (Test-Path $UserBuildConfigBackupPath) {
            Rename-Item -Path $UserBuildConfigBackupPath -NewName "BuildConfiguration.xml" -Force
        }
    }
}