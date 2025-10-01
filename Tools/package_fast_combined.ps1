<#
.SYNOPSIS
    A fast, combined pipeline for building and packaging a plugin and its example project.
.DESCRIPTION
    This script is the heart of the "Fast Mode" pipeline. It optimizes the build
    process by compiling the C++ code only ONCE. The sequence is:
    1. Smart-copy the master example project.
    2. Build the example project's editor targets. This compiles both the project
       and the plugin C++ code together, serving as the single validation step.
    3. If the build succeeds, create the clean, source-only plugin .zip file.
    4. Proceed to upgrade and package the example project .zip file.
.NOTES
    Author: Prajwal Shetty
    Version: 1.0 - Initial combined script for Fast Mode.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$OutputDirectory, # This is the temporary staging directory (.tmp)

    [Parameter(Mandatory=$true)]
    [string]$FinalOutputDir,   # This is the final /Builds directory

    [Parameter(Mandatory=$false)]
    [string]$EngineVersion,

    [Parameter(Mandatory=$false)]
    [switch]$UseCache,

    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $ScriptDir
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$MasterProjectDir = $Config.ExampleProject.MasterProjectDirectory
$LogsDir = Join-Path -Path $ProjectRoot -ChildPath "Logs"

if (-not (Test-Path $MasterProjectDir)) {
    throw "Master example project not found at '$MasterProjectDir'. Please check your config.json."
}
$MasterUProjectFile = Get-ChildItem -Path $MasterProjectDir -Filter "*.uproject" | Select-Object -First 1
$MasterProjectName = $MasterUProjectFile.BaseName

# Get Plugin Version from .uplugin file
$SourceUpluginPath = Join-Path -Path $Config.PluginSourceDirectory -ChildPath "$($Config.PluginName).uplugin"
if (-not (Test-Path $SourceUpluginPath)) {
    throw "Could not find source .uplugin file at '$SourceUpluginPath'. Check your 'PluginSourceDirectory' and 'PluginName' in config.json."
}
$PluginInfo = Get-Content -Raw -Path $SourceUpluginPath | ConvertFrom-Json
$PluginVersion = $PluginInfo.VersionName

# Define path for the GLOBAL BuildConfiguration.xml
$UserBuildConfigDir = Join-Path -Path $HOME -ChildPath "Documents/Unreal Engine/UnrealBuildTool"
$UserBuildConfigPath = Join-Path -Path $UserBuildConfigDir -ChildPath "BuildConfiguration.xml"
$UserBuildConfigBackupPath = Join-Path -Path $UserBuildConfigDir -ChildPath "BuildConfiguration.xml.bak"

# --- MAIN EXECUTION LOOP ---
$VersionsToProcess = if (-not [string]::IsNullOrEmpty($EngineVersion)) { @($EngineVersion) } else { $Config.EngineVersions }

foreach ($CurrentEngineVersion in $VersionsToProcess) {
    $CurrentStage = "SETUP"
    $LogFile = Join-Path -Path $LogsDir -ChildPath "Log_FastCombined_UE_${CurrentEngineVersion}.txt"
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

    Write-Host "`n-----------------------------------------------------------------" -ForegroundColor Magenta
    Write-Host " [FAST MODE] Processing UE $CurrentEngineVersion for v$($PluginVersion)" -ForegroundColor Magenta
    Write-Host "-----------------------------------------------------------------"

    # --- CACHE CHECK ---
    $FinalPluginZipPath = Join-Path -Path $FinalOutputDir -ChildPath "$($Config.PluginName)_v$($PluginVersion)_ue$($CurrentEngineVersion).zip"
    $PluginZipExists = Test-Path $FinalPluginZipPath

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

    if ($UseCache.IsPresent -and $PluginZipExists -and $CppExampleExists -and $BpExampleExists) {
        Write-Host "[CACHE] Skipping UE $CurrentEngineVersion because all outputs already exist." -ForegroundColor Cyan
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
        Write-Host "[1/5] Copying master project..."
        
        $ExcludeDirs = @( ".git", ".vs", ".idea", ".vscode", "Binaries", "Build", "Intermediate", "Saved", "DerivedDataCache", "__pycache__", "Platforms" )
        $ExcludeFiles = @( "*.sln", "*.suo", "*.VC.db", "*.DotSettings.user", ".vsconfig", "GEMINI.md", ".gitignore", ".gitmodules" )
        if ($Config.ExampleProject.ExcludeFiles) {
            $ExcludeFiles += $Config.ExampleProject.ExcludeFiles
        }
        if ($Config.ExampleProject.ExcludeFolders) {
            $ExcludeDirs += $Config.ExampleProject.ExcludeFolders
        }

        robocopy $MasterProjectDir $TempProjectDir /E /XD $ExcludeDirs /XF $ExcludeFiles /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "Failed to copy master project." }

        $TempUProjectPath = Join-Path -Path $TempProjectDir -ChildPath $MasterUProjectFile.Name

        # --- 1.5. EXCLUDE OTHER PLUGINS ---
        $CurrentStage = "EXCLUDE_PLUGINS"
        if ($Config.ExampleProject.ExcludePluginsFromExample -and $Config.ExampleProject.ExcludePluginsFromExample.Count -gt 0) {
            Write-Host "[1.5/5] Excluding specified plugins from example project..."
            $UProjectJson = Get-Content -Raw -Path $TempUProjectPath | ConvertFrom-Json
            if ($null -ne $UProjectJson.Plugins) {
                $UProjectJson.Plugins = $UProjectJson.Plugins | Where-Object { $Config.ExampleProject.ExcludePluginsFromExample -notcontains $_.Name }
            }
            $UProjectJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $TempUProjectPath -Encoding utf8
            foreach ($PluginToExclude in $Config.ExampleProject.ExcludePluginsFromExample) {
                $PluginDirToRemove = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($PluginToExclude)"
                if (Test-Path $PluginDirToRemove) { Remove-Item -Path $PluginDirToRemove -Recurse -Force }
            }
        }
        
        # --- 1.6. EXCLUDE SPECIFIED FOLDERS ---
        $CurrentStage = "EXCLUDE_FOLDERS"
        if ($Config.ExampleProject.ExcludeFolders -and $Config.ExampleProject.ExcludeFolders.Count -gt 0) {
            Write-Host "[1.6/5] Forcefully removing specified folders from example project..."
            foreach ($FolderToExclude in $Config.ExampleProject.ExcludeFolders) {
                $FolderDirToRemove = Join-Path -Path $TempProjectDir -ChildPath $FolderToExclude
                if (Test-Path $FolderDirToRemove) { Remove-Item -Path $FolderDirToRemove -Recurse -Force }
            }
        }
        
        # --- 2. BUILD PROJECT & PLUGIN (THE ONLY COMPILE STEP) ---
        $CurrentStage = "BUILD_PROJECT"
        Write-Host "[2/5] Building project editor targets for UE $CurrentEngineVersion (single compile step)..."
        $BuildScriptPath = Join-Path -Path $EnginePath -ChildPath "Engine\Build\BatchFiles\Build.bat"
        & $BuildScriptPath ($MasterProjectName + "Editor") Win64 Development -Project="$TempUProjectPath" | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Failed to build project editor targets for UE $CurrentEngineVersion." }

        # --- 3. PACKAGE PLUGIN (SOURCE-ONLY) ---
        $CurrentStage = "PACKAGE_PLUGIN"
        Write-Host "[3/5] Creating clean source-only plugin zip..."
        $TempPluginStageDir = Join-Path -Path $OutputDirectory -ChildPath "PluginStage"
        if (Test-Path $TempPluginStageDir) { Remove-Item -Recurse -Force -Path $TempPluginStageDir }
        New-Item -Path $TempPluginStageDir -ItemType Directory -Force | Out-Null
        
        $PluginRootInStage = Join-Path -Path $TempPluginStageDir -ChildPath $Config.PluginName
        
        $ExcludePluginCopyDirs = @( ".git", ".github", ".vs", "Binaries", "Build", "Intermediate", "Saved", "DerivedDataCache", "__pycache__", ".vscode", ".idea", "Packages" )
        $ExcludePluginCopyFiles = @( "LICENSE", "LICENSE.md" )
        robocopy $Config.PluginSourceDirectory $PluginRootInStage /E /XD $ExcludePluginCopyDirs /XF $ExcludePluginCopyFiles /NFL /NDL /NJH /NJS /nc /ns /np
        if ($LASTEXITCODE -gt 7) { throw "Failed to copy plugin source for zipping." }

        $StagedUplugin = Join-Path -Path $PluginRootInStage -ChildPath "$($Config.PluginName).uplugin"
        $UpluginJson = Get-Content -Raw -Path $StagedUplugin | ConvertFrom-Json
        $UpluginJson.EngineVersion = "$($CurrentEngineVersion).0"
        $UpluginJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $StagedUplugin -Encoding utf8

        Compress-Archive -Path "$PluginRootInStage\*" -DestinationPath $FinalPluginZipPath -Force
        Remove-Item -Recurse -Force -Path $TempPluginStageDir
        Write-Host "Plugin source zip created at: $FinalPluginZipPath" -ForegroundColor Green

        if ($Config.ExampleProject -and $Config.ExampleProject.Generate) {
            # --- 4. UPGRADE PROJECT ---
            $CurrentStage = "UPGRADE"
            Write-Host "[4/5] Upgrading project assets for UE $CurrentEngineVersion..."
            $UnrealEditorPath = Join-Path -Path $EnginePath -ChildPath "Engine/Binaries/Win64/UnrealEditor-Cmd.exe"

            $UProjectJsonOnTemp = Get-Content -Raw -Path $TempUProjectPath | ConvertFrom-Json
            $UProjectJsonOnTemp.EngineAssociation = $CurrentEngineVersion
            $UProjectJsonOnTemp | ConvertTo-Json -Depth 10 | Out-File -FilePath $TempUProjectPath -Encoding utf8

            & $UnrealEditorPath "$TempUProjectPath" -run=ResavePackages -allowcommandletrendering -autocheckout -projectonly | Tee-Object -FilePath $LogFile -Append
            if ($LASTEXITCODE -ne 0) { throw "Failed to resave/upgrade packages." }

            # --- 5. PACKAGE EXAMPLE PROJECT(S) ---
            $CurrentStage = "PACKAGE_EXAMPLE"
            Write-Host "[5/5] Packaging final example project(s)..."
            
            # C++ Example
            if ($Config.ExampleProject.GenerateCppExample) {
                # Prep for C++ packaging (minimal cleaning)
                "Binaries", "Intermediate", "Saved", ".vs", "DerivedDataCache", "Plugins" | ForEach-Object {
                    $pathToRemove = Join-Path $TempProjectDir $_
                    if(Test-Path $pathToRemove) { Remove-Item -Recurse -Force $pathToRemove -ErrorAction SilentlyContinue }
                }
                Compress-Archive -Path "$TempProjectDir\*" -DestinationPath $FinalCppZipPath -Force
                Write-Host "C++ example created at: $FinalCppZipPath" -ForegroundColor Green
            }

            # Blueprint Example
            if ($Config.ExampleProject.GenerateBlueprintExample) {
                # Prep for BP packaging (more cleaning)
                "Binaries", "Intermediate", "Saved", ".vs", "DerivedDataCache", "Source", "Plugins" | ForEach-Object {
                    $pathToRemove = Join-Path $TempProjectDir $_ 
                    if(Test-Path $pathToRemove) { Remove-Item -Recurse -Force $pathToRemove -ErrorAction SilentlyContinue }
                }
                Remove-Item -Path "$TempProjectDir\*.sln" -ErrorAction SilentlyContinue

                $UProjectJsonBP = Get-Content -Raw -Path $TempUProjectPath | ConvertFrom-Json
                if ($UProjectJsonBP.PSObject.Properties.Name -contains 'Modules') { $UProjectJsonBP.PSObject.Properties.Remove('Modules') }
                $UProjectJsonBP | ConvertTo-Json -Depth 10 | Out-File -FilePath $TempUProjectPath -Encoding utf8

                if ($Config.ExampleProject.ExcludePlugin) {
                    $PluginDirToRemove = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)"
                    if (Test-Path $PluginDirToRemove) { Remove-Item -Path $PluginDirToRemove -Recurse -Force }
                } else {
                    $PluginDir = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)"
                    Remove-Item -Path "$PluginDir\Source" -Recurse -Force -ErrorAction SilentlyContinue
                    $PluginUpluginPath = Join-Path -Path $PluginDir -ChildPath "$($Config.PluginName).uplugin"
                    if (Test-Path $PluginUpluginPath) {
                        $PluginJsonBP = Get-Content -Raw -Path $PluginUpluginPath | ConvertFrom-Json
                        if ($PluginJsonBP.PSObject.Properties.Name -contains 'Modules') { $PluginJsonBP.PSObject.Properties.Remove('Modules') }
                        $PluginJsonBP | ConvertTo-Json -Depth 10 | Out-File -FilePath $PluginUpluginPath -Encoding utf8
                    }
                }
                
                if ($Config.ExampleProject.BlueprintOnlyExcludeFolders) {
                    foreach ($ExcludeFolder in $Config.ExampleProject.BlueprintOnlyExcludeFolders) {
                        $FolderToRemove = Join-Path -Path $TempProjectDir -ChildPath $ExcludeFolder
                        if (Test-Path $FolderToRemove) { Remove-Item -Path $FolderToRemove -Recurse -Force }
                    }
                }
                
                Compress-Archive -Path "$TempProjectDir\*" -DestinationPath $FinalBpZipPath -Force
                Write-Host "Blueprint example created at: $FinalBpZipPath" -ForegroundColor Green
            }
        } else {
            Write-Host "[4/5] Skipping example project upgrade (disabled in config)." -ForegroundColor Gray
            Write-Host "[5/5] Skipping example project packaging (disabled in config)." -ForegroundColor Gray
        }

    } catch {
        Write-Error "`n!!!! FAST MODE FAILED for UE $CurrentEngineVersion at stage: $CurrentStage !!!!`n!!!! Error: $($_.Exception.Message)`n!!!! See log for details: $LogFile"
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

exit 0
