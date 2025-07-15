<#
.SYNOPSIS
    Packages the example project associated with the plugin.
.DESCRIPTION
    This script intelligently copies a source project to a temporary location,
    excluding the main plugin and all build artifacts. It then converts the
    project to be Blueprint-only, renames it, and creates a distributable .zip archive.
.NOTES
    Author: Prajwal Shetty
    Version: 2.4
#>

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$GlobalSuccess = $true

# Load configuration from the main packaging script's config
$ConfigPath = Join-Path -Path $ScriptDir -ChildPath "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file (config.json) not found at '$ConfigPath'. This script relies on it to find the source project."
    exit 1
}
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# --- Get Plugin Version from .uplugin file ---
$SourceUpluginPath = Join-Path -Path $Config.PluginSourceDirectory -ChildPath "$($Config.PluginName).uplugin"
if (-not (Test-Path $SourceUpluginPath)) {
    throw "Could not find source .uplugin file at '$SourceUpluginPath'. Check your 'PluginSourceDirectory' and 'PluginName' in config.json."
}
$PluginInfo = Get-Content -Raw -Path $SourceUpluginPath | ConvertFrom-Json
$PluginVersion = $PluginInfo.VersionName

# --- Create timestamped output directory ---
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputBuildsDir = Join-Path -Path $ScriptDir -ChildPath "ExampleProjectBuild_$Timestamp"
$LogFile = Join-Path -Path $OutputBuildsDir -ChildPath "Log_ExampleProject_$Timestamp.txt"
New-Item -Path $OutputBuildsDir -ItemType Directory -Force | Out-Null

# --- MAIN EXECUTION ---
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " STARTING EXAMPLE PROJECT PACKAGING SCRIPT" -ForegroundColor Cyan
Write-Host "================================================================="

$TempProjectDir = ""
$NewTempProjectDir = ""

try {
    # --- 1. FIND AND VALIDATE SOURCE PROJECT ---
    $CurrentStage = "VALIDATE_PROJECT"
    Write-Host "[1/5] [VALIDATE] Finding and validating source project..."

    $PluginSourceParent = (Get-Item -Path $Config.PluginSourceDirectory).Parent
    if ($PluginSourceParent.Name -ne "Plugins") {
        throw "Expected 'PluginSourceDirectory' to be inside a 'Plugins' folder, but its parent is '$($PluginSourceParent.Name)'."
    }
    $SourceProjectRoot = $PluginSourceParent.Parent.FullName
    
    $UProjectFile = Get-ChildItem -Path $SourceProjectRoot -Filter "*.uproject" | Select-Object -First 1
    if (-not $UProjectFile) {
        throw "Could not find a .uproject file in the determined root directory: '$SourceProjectRoot'."
    }
    $ProjectName = $UProjectFile.BaseName
    Write-Host "Found project '$ProjectName' at: $SourceProjectRoot" -ForegroundColor Green

    # --- 2. COPY PROJECT TO TEMPORARY LOCATION (INTELLIGENTLY) ---
    $CurrentStage = "COPY_PROJECT"
    Write-Host "[2/5] [COPY] Copying source project to a temporary location..."
    
    $TempProjectDir = Join-Path -Path $OutputBuildsDir -ChildPath "Temp_$($ProjectName)"
    New-Item -Path $TempProjectDir -ItemType Directory -Force | Out-Null
    
    $FoldersToExclude = @( "Build", "Binaries", "Intermediate", "Saved", "DerivedDataCache", ".vs", ".vscode", ".idea", "Logs", "ExampleProjectBuild_*", "Builds_*" )

    Get-ChildItem -Path $SourceProjectRoot | ForEach-Object {
        if ($FoldersToExclude -notcontains $_.Name -and $_.Name -ne "Plugins") {
            Write-Host "Copying top-level item: $($_.Name)..."
            Copy-Item -Path $_.FullName -Destination $TempProjectDir -Recurse -Force
        } else {
            Write-Host "Skipping top-level folder: $($_.Name)" -ForegroundColor Gray
        }
    }

    $SourcePluginsDir = Join-Path -Path $SourceProjectRoot -ChildPath "Plugins"
    if (Test-Path $SourcePluginsDir) {
        $DestPluginsDir = Join-Path -Path $TempProjectDir -ChildPath "Plugins"
        New-Item -Path $DestPluginsDir -ItemType Directory -Force | Out-Null

        Get-ChildItem -Path $SourcePluginsDir | ForEach-Object {
            $CurrentPluginFolder = $_
            if ($CurrentPluginFolder.Name -ne $Config.PluginName) {
                Write-Host "Copying other plugin: $($CurrentPluginFolder.Name)..."
                Copy-Item -Path $CurrentPluginFolder.FullName -Destination $DestPluginsDir -Recurse -Force
            } else {
                Write-Host "Skipping main plugin folder: $($CurrentPluginFolder.Name)" -ForegroundColor Yellow
            }
        }
    }
    Write-Host "Intelligent project copy complete." -ForegroundColor Green

    # --- 3. CLEAN AND CONVERT COPIED PROJECT ---
    $CurrentStage = "CLEAN_AND_CONVERT"
    Write-Host "[3/5] [CONVERT] Converting to Blueprint-only project and cleaning..."

    $TempUProjectPath = Join-Path -Path $TempProjectDir -ChildPath $UProjectFile.Name
    $TempSourcePath = Join-Path -Path $TempProjectDir -ChildPath "Source"
    
    if (Test-Path $TempSourcePath) { Write-Host "Removing C++ Source folder..."; Remove-Item -Path $TempSourcePath -Recurse -Force }

    Write-Host "Modifying .uproject file to remove C++ module dependencies..."
    $UProjectJson = Get-Content -Raw -Path $TempUProjectPath | ConvertFrom-Json
    if ($UProjectJson.PSObject.Properties.Name -contains 'Modules') { $UProjectJson.PSObject.Properties.Remove('Modules'); Write-Host " - Removed 'Modules' section." }
    if ($UProjectJson.PSObject.Properties.Name -contains 'Plugins') { $UProjectJson.Plugins = @($UProjectJson.Plugins | Where-Object { $_.Name -ne $Config.PluginName }); Write-Host " - Ensured '$($Config.PluginName)' is not in 'Plugins' section." }
    $UProjectJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $TempUProjectPath -Encoding utf8

    $DevFolderPath = Join-Path -Path $TempProjectDir -ChildPath "Content\Developers"
    if (Test-Path $DevFolderPath) { Write-Host "Removing Content\Developers folder"; Remove-Item -Path $DevFolderPath -Recurse -Force }
    
    # <<<< THE FIX IS HERE: Changed -Filter to -Include >>>>
    Get-ChildItem -Path $TempProjectDir -Include ".vsconfig", "*.sln*", "*.sln.DotSettings.user" -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "Removed solution, user settings, and vsconfig files."
    Write-Host "Conversion and cleaning complete." -ForegroundColor Green

    # --- 4. RENAME PROJECT ---
    $CurrentStage = "RENAME_PROJECT"
    Write-Host "[4/5] [RENAME] Renaming project files and folders..."
    $ShortPluginName = if ($Config.PluginName.Length -gt 8) { $Config.PluginName.Substring(0, 8) } else { $Config.PluginName }
    $NewProjectName = "${ShortPluginName}_Example"
    Write-Host "New project name will be: $NewProjectName"
    $OldUProjectFile = Get-ChildItem -Path $TempProjectDir -Filter "*.uproject" | Select-Object -First 1
    if ($OldUProjectFile) { Rename-Item -Path $OldUProjectFile.FullName -NewName "$($NewProjectName).uproject"; Write-Host "Renamed .uproject file to: $($NewProjectName).uproject" }
    $ParentDir = (Get-Item $TempProjectDir).Parent.FullName
    $NewTempProjectDir = Join-Path -Path $ParentDir -ChildPath $NewProjectName
    Rename-Item -Path $TempProjectDir -NewName $NewProjectName
    Write-Host "Renamed project folder to: $NewProjectName"

    # --- 5. ZIP THE CLEANED PROJECT ---
    $CurrentStage = "ZIP_PROJECT"
    Write-Host "[5/5] [ZIP] Creating final distributable zip file..."
    $FinalZipPath = Join-Path -Path $OutputBuildsDir -ChildPath "$($NewProjectName)_v$($PluginVersion).zip"
    Compress-Archive -Path "$NewTempProjectDir\*" -DestinationPath $FinalZipPath -Force
    Write-Host "`n[SUCCESS] Example project packaged successfully!" -ForegroundColor Green
    Write-Host "Your zip file is ready at: $FinalZipPath" -ForegroundColor Green

} catch {
    $GlobalSuccess = $false
    Write-Error "`n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Error "!!!! SCRIPT FAILED at stage: $CurrentStage !!!!`n"
    Write-Error "!!!! Error: $($_.Exception.Message)"
    Write-Error "!!!! Full details have been saved to the log file: $LogFile"
    Write-Error "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    $_.Exception.ToString() | Out-File -FilePath $LogFile -Append
} finally {
    # --- Cleanup ---
    if ((-not [string]::IsNullOrEmpty($NewTempProjectDir)) -and (Test-Path -Path $NewTempProjectDir)) {
        Write-Host "Cleaning up temporary files..."
        Remove-Item -Recurse -Force -Path $NewTempProjectDir
    } elseif ((-not [string]::IsNullOrEmpty($TempProjectDir)) -and (Test-Path -Path $TempProjectDir)) { 
        Write-Host "Cleaning up temporary files..."
        Remove-Item -Recurse -Force -Path $TempProjectDir
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