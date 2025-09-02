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
    [string]$FinalOutputDir   # This is the final /Builds directory
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

# --- MAIN EXECUTION LOOP ---
foreach ($EngineVersion in $Config.EngineVersions) {
    $CurrentStage = "SETUP"
    $LogFile = Join-Path -Path $LogsDir -ChildPath "Log_ExampleProject_UE_${EngineVersion}.txt"
    $EnginePath = Join-Path -Path $Config.UnrealEngineBasePath -ChildPath "UE_$EngineVersion"
    $TempProjectDir = Join-Path -Path $OutputDirectory -ChildPath "Ex$($EngineVersion)"
    
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
    Write-Host " [EXAMPLE] Processing UE $EngineVersion for Project v$ProjectVersion" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------------------------"

    try {
        if (-not (Test-Path $EnginePath)) { throw "[SKIP] Engine not found at '$EnginePath'" }

        # --- 1. COPY MASTER PROJECT (SMART COPY) ---
        $CurrentStage = "COPY"
        Write-Host "[1/6] Copying master project..."
        
        # Exclude IDE files and other non-distributable artifacts.
        # The plugin IS included at this stage so the project can compile.
        $ExcludeDirs = @( ".git", ".vs", ".idea", ".vscode", "Binaries", "Build", "Intermediate", "Saved", "DerivedDataCache", "__pycache__", "Platforms" )
        $ExcludeFiles = @( "*.sln", "*.suo", "*.VC.db", "*.DotSettings.user", ".vsconfig", "GEMINI.md", ".gitignore", ".gitmodules" )
        if ($Config.ExampleProject.ExcludeFiles) {
            $ExcludeFiles += $Config.ExampleProject.ExcludeFiles
        }

        robocopy $MasterProjectDir $TempProjectDir /E /XD $ExcludeDirs /XF $ExcludeFiles /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "Failed to copy master project." }

        $TempUProjectPath = Join-Path -Path $TempProjectDir -ChildPath $MasterUProjectFile.Name
        
        # --- 2. COMPILE PLUGIN (if included) ---
        # This step is now only for projects that are shipped WITH the plugin.
        # If ExcludePlugin is true, we assume the user has the plugin installed in the engine.
        if (-not $Config.ExampleProject.ExcludePlugin) {
            $CurrentStage = "COMPILE_PLUGIN"
            Write-Host "[2/6] Compiling plugin for UE $EngineVersion..."
            
            $PluginDir = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)"
            $PluginUpluginPath = Join-Path -Path $PluginDir -ChildPath "$($Config.PluginName).uplugin"
            if (-not (Test-Path $PluginUpluginPath)) { throw "Plugin .uplugin file not found at: $PluginUpluginPath" }
            
            $PluginJson = Get-Content -Raw -Path $PluginUpluginPath | ConvertFrom-Json
            $PluginJson.EngineVersion = "$($EngineVersion).0"
            $PluginJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $PluginUpluginPath -Encoding utf8
            
            $RunUATPath = Join-Path -Path $EnginePath -ChildPath "Engine\Build\BatchFiles\RunUAT.bat"
            & $RunUATPath BuildPlugin -Plugin="$PluginUpluginPath" -Package="$PluginDir\Packages" -TargetPlatforms=Win64 -Rocket | Tee-Object -FilePath $LogFile -Append
            if ($LASTEXITCODE -ne 0) { throw "Failed to compile plugin for UE $EngineVersion." }
        } else {
            Write-Host "[2/6] Skipping plugin compilation (plugin will be excluded from final package)." -ForegroundColor Gray
        }

        # --- 3. BUILD PROJECT (to avoid popups) ---
        $CurrentStage = "BUILD_PROJECT"
        Write-Host "[3/6] Building project editor targets for UE $EngineVersion..."
        $UnrealBuildToolPath = Join-Path -Path $EnginePath -ChildPath "Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.dll"
        & "dotnet" $UnrealBuildToolPath ($MasterProjectName + "Editor") Win64 Development -Project="$TempUProjectPath" -iwyu -noubtmakefiles | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Failed to build project editor targets for UE $EngineVersion." }

        # --- 4. UPGRADE PROJECT ---
        $CurrentStage = "UPGRADE"
        Write-Host "[4/6] Upgrading project assets for UE $EngineVersion..."
        $UnrealEditorPath = Join-Path -Path $EnginePath -ChildPath "Engine/Binaries/Win64/UnrealEditor-Cmd.exe"

        # Robustly update the engine association in the .uproject file
        $UProjectJson = Get-Content -Raw -Path $TempUProjectPath | ConvertFrom-Json
        $UProjectJson.EngineAssociation = $EngineVersion
        $UProjectJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $TempUProjectPath -Encoding utf8

        & $UnrealEditorPath "$TempUProjectPath" -run=ResavePackages -allowcommandletrendering -autocheckout -projectonly | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Failed to resave/upgrade packages." }

        # --- 5. PACKAGE C++ EXAMPLE (OPTIONAL) ---
        $CurrentStage = "PACKAGE_CPP"
        if ($Config.ExampleProject.GenerateCppExample) {
            Write-Host "[5/6] Packaging C++ Example..."
            
            # --- Pre-Zip Cleanup ---
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
            
            $FinalZipPath = Join-Path -Path $FinalOutputDir -ChildPath "$($MasterProjectName)_v$($ProjectVersion)_CPP_UE$($EngineVersion).zip"
            Compress-Archive -Path "$TempProjectDir\*" -DestinationPath $FinalZipPath -Force
            Write-Host "C++ example created at: $FinalZipPath" -ForegroundColor Green
        } else {
             Write-Host "[5/6] Skipping C++ example packaging." -ForegroundColor Gray
        }

        # --- 6. PACKAGE BLUEPRINT EXAMPLE (OPTIONAL) ---
        $CurrentStage = "PACKAGE_BP"
        if ($Config.ExampleProject.GenerateBlueprintExample) {
            Write-Host "[6/6] Creating and packaging Blueprint-only example..."
            
            # --- Pre-Zip Cleanup ---
            "Binaries", "Intermediate", "Saved", ".vs", "DerivedDataCache", "Source" | ForEach-Object {
                $pathToRemove = Join-Path $TempProjectDir $_ 
                if(Test-Path $pathToRemove) { Remove-Item -Recurse -Force $pathToRemove -ErrorAction SilentlyContinue }
            }
            Remove-Item -Path "$TempProjectDir\*.sln" -ErrorAction SilentlyContinue

            # Clean up the project file
            $UProjectJson = Get-Content -Raw -Path $TempUProjectPath | ConvertFrom-Json
            if ($UProjectJson.PSObject.Properties.Name -contains 'Modules') { $UProjectJson.PSObject.Properties.Remove('Modules') }
            $UProjectJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $TempUProjectPath -Encoding utf8

            # If plugin was included, clean it up for BP-only distribution. If excluded, remove the whole folder.
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
            
            $FinalZipPath = Join-Path -Path $FinalOutputDir -ChildPath "$($MasterProjectName)_v$($ProjectVersion)_BP_UE$($EngineVersion).zip"
            Compress-Archive -Path "$TempProjectDir\*" -DestinationPath $FinalZipPath -Force
            Write-Host "Blueprint example created at: $FinalZipPath" -ForegroundColor Green
        } else {
            Write-Host "[6/6] Skipping Blueprint example packaging." -ForegroundColor Gray
        }

    } catch {
        Write-Error "`n!!!! EXAMPLE PROJECT FAILED for UE $EngineVersion at stage: $CurrentStage !!!!`n!!!! Error: $($_.Exception.Message)`n!!!! See log for details: $LogFile"
        $Global:LASTEXITCODE = 1
    } finally {
        Write-Host "Cleaning up temporary project for UE $EngineVersion..."
        if (Test-Path $TempProjectDir) { Remove-Item -Recurse -Force -Path $TempProjectDir }
    }
}stinationPath $FinalZipPath -Force
            Write-Host "Blueprint example created at: $FinalZipPath" -ForegroundColor Green
        } else {
            Write-Host "[6/6] Skipping Blueprint example packaging." -ForegroundColor Gray
        }

    } catch {
        Write-Error "`n!!!! EXAMPLE PROJECT FAILED for UE $EngineVersion at stage: $CurrentStage !!!!`n!!!! Error: $($_.Exception.Message)`n!!!! See log for details: $LogFile"
        $Global:LASTEXITCODE = 1
    } finally {
        Write-Host "Cleaning up temporary project for UE $EngineVersion..."
        if (Test-Path $TempProjectDir) { Remove-Item -Recurse -Force -Path $TempProjectDir }
    }
}