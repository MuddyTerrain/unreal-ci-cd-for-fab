<#
.SYNOPSIS
    Packages C++ and Blueprint example projects for multiple Unreal Engine versions.
.DESCRIPTION
    Uses a "Develop Low, Upgrade High" workflow. It takes a master project
    (developed in the oldest supported engine version), and for each version in the
    config, it:
    1. Creates a smart copy (excluding .git, build artifacts, etc.)
    2. Compiles the plugin for the target engine version first
    3. Upgrades the project to the target engine version
    4. Packages C++ and/or Blueprint-only versions
.NOTES
    Author: Prajwal Shetty
    Version: 3.1 - Fixed copying and compilation order
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$OutputDirectory
)

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$ConfigPath = Join-Path -Path $ScriptDir -ChildPath "../config.json"
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$MasterProjectDir = $Config.ExampleProject.MasterProjectDirectory
$LogsDir = Join-Path -Path $OutputDirectory -ChildPath "Logs"
New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null

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
    $TempProjectDir = Join-Path -Path $OutputDirectory -ChildPath "Temp_Example_$EngineVersion"
    
    Write-Host "`n-----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " [EXAMPLE] Processing for Unreal Engine $EngineVersion" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------------------------"

    try {
        if (-not (Test-Path $EnginePath)) { throw "[SKIP] Engine not found at '$EnginePath'" }

        # --- 1. COPY MASTER PROJECT (SMART COPY) ---
        $CurrentStage = "COPY"
        Write-Host "[1/4] Copying master project (excluding build artifacts and VCS)..."
        
        # Define directories to exclude during copy
        $ExcludeDirs = @(
            ".git",
            ".vs", 
            "Binaries",
            "Build", 
            "Intermediate",
            "Saved",
            "DerivedDataCache",
            "__pycache__",
            ".vscode",
            ".idea"
        )
        
        # Use Robocopy for efficient copying with exclusions
        $null = robocopy $MasterProjectDir $TempProjectDir /E /XD $ExcludeDirs /NFL /NDL /NJH /NJS /nc /ns /np
        # Note: Robocopy exit codes 0-7 are success, 8+ are errors
        if ($LASTEXITCODE -gt 7) { throw "Failed to copy master project." }

        # --- 2. COMPILE PLUGIN FOR THIS ENGINE VERSION ---
        $CurrentStage = "COMPILE_PLUGIN"
        Write-Host "[2/4] Compiling plugin for UE $EngineVersion before upgrade..."
        
        # Find the plugin directory in the copied project
        $PluginDir = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)"
        $PluginUpluginPath = Join-Path -Path $PluginDir -ChildPath "$($Config.PluginName).uplugin"
        
        if (-not (Test-Path $PluginUpluginPath)) {
            throw "Plugin .uplugin file not found at: $PluginUpluginPath"
        }
        
        # Update plugin's engine version association
        $PluginJson = Get-Content -Raw -Path $PluginUpluginPath | ConvertFrom-Json
        $PluginJson.EngineVersion = "$($EngineVersion).0"
        $PluginJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $PluginUpluginPath -Encoding utf8
        
        # Compile the plugin using RunUAT
        $RunUATPath = Join-Path -Path $EnginePath -ChildPath "Engine\Build\BatchFiles\RunUAT.bat"
        $PluginPackageDir = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)\Packages"
        
        & $RunUATPath BuildPlugin -Plugin="$PluginUpluginPath" -Package="$PluginPackageDir" -TargetPlatforms=Win64 -Rocket | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Failed to compile plugin for UE $EngineVersion." }

        # --- 3. UPGRADE PROJECT ---
        $CurrentStage = "UPGRADE"
        Write-Host "[3/4] Upgrading project and recompiling for UE $EngineVersion..."
        $TempUProjectPath = Join-Path -Path $TempProjectDir -ChildPath $MasterUProjectFile.Name
        $UnrealEditorPath = Join-Path -Path $EnginePath -ChildPath "Engine/Binaries/Win64/UnrealEditor-Cmd.exe"

        # Update the .uproject file to associate with the new engine version
        (Get-Content $TempUProjectPath).replace('"EngineAssociation": "5.1"', '"EngineAssociation": "' + $EngineVersion + '"') | Set-Content $TempUProjectPath

        # Resave all packages to upgrade them to the new version's format
        & $UnrealEditorPath "$TempUProjectPath" -run=ResavePackages -allowcommandletrendering -autocheckout -projectonly | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Failed to resave/upgrade packages." }

        # --- 4. PACKAGE C++ EXAMPLE (OPTIONAL) ---
        $CurrentStage = "PACKAGE_CPP"
        if ($Config.ExampleProject.GenerateCppExample) {
            Write-Host "[4/6] Packaging C++ Example..."
            $FinalZipPath = Join-Path -Path $OutputDirectory -ChildPath "$($MasterProjectName)_CPP_UE$($EngineVersion).zip"
            # Clean build artifacts before zipping (but keep the compiled plugin)
            "Binaries", "Intermediate", "Saved", ".vs", "DerivedDataCache" | ForEach-Object {
                $pathToRemove = Join-Path $TempProjectDir $_
                if(Test-Path $pathToRemove) { Remove-Item -Recurse -Force $pathToRemove }
            }
            # Also clean the plugin's temporary package directory
            $PluginPackageDir = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)\Packages"
            if(Test-Path $PluginPackageDir) { Remove-Item -Recurse -Force $PluginPackageDir }
            
            Compress-Archive -Path "$TempProjectDir\*" -DestinationPath $FinalZipPath -Force
            Write-Host "C++ example created at: $FinalZipPath" -ForegroundColor Green
        } else {
             Write-Host "[4/6] Skipping C++ example packaging." -ForegroundColor Gray
        }

        # --- 5. PACKAGE BLUEPRINT EXAMPLE (OPTIONAL) ---
        $CurrentStage = "PACKAGE_BP"
        if ($Config.ExampleProject.GenerateBlueprintExample) {
            Write-Host "[5/6] Creating and packaging Blueprint-only example..."
            # Now, strip the C++ source from the already-upgraded project
            Remove-Item -Path (Join-Path $TempProjectDir "Source") -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path (Join-Path $TempProjectDir "*.sln") -ErrorAction SilentlyContinue
            
            # Also remove the plugin's C++ source code
            $PluginSourceDir = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)\Source"
            if (Test-Path $PluginSourceDir) {
                Remove-Item -Path $PluginSourceDir -Recurse -Force
            }
            
            # Modify .uproject to remove C++ module dependencies
            $UProjectJson = Get-Content -Raw -Path $TempUProjectPath | ConvertFrom-Json
            if ($UProjectJson.PSObject.Properties.Name -contains 'Modules') {
                $UProjectJson.PSObject.Properties.Remove('Modules')
            }
            $UProjectJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $TempUProjectPath -Encoding utf8
            
            # Modify plugin .uplugin to remove C++ module dependencies
            $PluginJson = Get-Content -Raw -Path $PluginUpluginPath | ConvertFrom-Json
            if ($PluginJson.PSObject.Properties.Name -contains 'Modules') {
                $PluginJson.PSObject.Properties.Remove('Modules')
            }
            $PluginJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $PluginUpluginPath -Encoding utf8
            
            $FinalZipPath = Join-Path -Path $OutputDirectory -ChildPath "$($MasterProjectName)_BP_UE$($EngineVersion).zip"
            Compress-Archive -Path "$TempProjectDir\*" -DestinationPath $FinalZipPath -Force
            Write-Host "Blueprint example created at: $FinalZipPath" -ForegroundColor Green
        } else {
            Write-Host "[5/6] Skipping Blueprint example packaging." -ForegroundColor Gray
        }

    } catch {
        Write-Error "`n!!!! EXAMPLE PROJECT FAILED for UE $EngineVersion at stage: $CurrentStage !!!!"
        Write-Error "!!!! Error: $($_.Exception.Message)"
        Write-Error "!!!! See log for details: $LogFile"
        $Global:LASTEXITCODE = 1 # Signal failure to master script
    } finally {
        Write-Host "Cleaning up temporary files for UE $EngineVersion..."
        if (Test-Path $TempProjectDir) { Remove-Item -Recurse -Force -Path $TempProjectDir }
    }
}