<#
.SYNOPSIS
    Packages the example project associated with the plugin.
.DESCRIPTION
    This script finds the root project directory based on the plugin's location,
    copies it to a temporary location, converts it to a clean Blueprint-only
    project by removing the C++ source and the plugin itself, cleans all
    intermediate files, renames the project, and creates a distributable .zip archive.
.NOTES
    Author: Prajwal Shetty
    Version: 1.7
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

    # --- 2. COPY PROJECT TO TEMPORARY LOCATION ---
    $CurrentStage = "COPY_PROJECT"
    Write-Host "[2/5] [COPY] Copying source project to a temporary location..."
    
    $TempProjectDir = Join-Path -Path $OutputBuildsDir -ChildPath "Temp_$($ProjectName)"
    Copy-Item -Path $SourceProjectRoot -Destination $TempProjectDir -Recurse -Force -Exclude "Builds_*", "Logs", "ExampleProjectBuild_*"
    Write-Host "Project copied to: $TempProjectDir"

    # --- 3. CLEAN AND CONVERT COPIED PROJECT ---
    $CurrentStage = "CLEAN_AND_CONVERT"
    Write-Host "[3/5] [CONVERT] Converting to Blueprint-only project and cleaning..."

    # Define paths within the temporary copy
    $TempUProjectPath = Join-Path -Path $TempProjectDir -ChildPath $UProjectFile.Name
    $TempPluginPath = Join-Path -Path $TempProjectDir -ChildPath "Plugins\$($Config.PluginName)"
    $TempSourcePath = Join-Path -Path $TempProjectDir -ChildPath "Source"
    
    # a) Remove the plugin itself
    if (Test-Path $TempPluginPath) {
        Write-Host "Removing plugin folder: $($Config.PluginName)"
        Remove-Item -Path $TempPluginPath -Recurse -Force
    }

    # b) Remove the C++ Source folder
    if (Test-Path $TempSourcePath) {
        Write-Host "Removing C++ Source folder..."
        Remove-Item -Path $TempSourcePath -Recurse -Force
    }

    # c) Modify the .uproject file to remove module and plugin dependencies
    Write-Host "Modifying .uproject file to remove dependencies..."
    $UProjectJson = Get-Content -Raw -Path $TempUProjectPath | ConvertFrom-Json
    
    if ($UProjectJson.PSObject.Properties.Name -contains 'Modules') {
        $UProjectJson.PSObject.Properties.Remove('Modules')
        Write-Host " - Removed 'Modules' section."
    }

    if ($UProjectJson.PSObject.Properties.Name -contains 'Plugins') {
        $UProjectJson.Plugins = @($UProjectJson.Plugins | Where-Object { $_.Name -ne $Config.PluginName })
        Write-Host " - Removed '$($Config.PluginName)' from 'Plugins' section."
    }
    
    $UProjectJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $TempUProjectPath -Encoding utf8

    # d) Remove local build artifacts and IDE folders
    "Binaries", "Intermediate", "Saved", "DerivedDataCache", ".vs", ".vscode", ".idea", "Content\Developers" | ForEach-Object {
        $PathToDelete = Join-Path -Path $TempProjectDir -ChildPath $_
        if (Test-Path $PathToDelete) {
            Write-Host "Removing local artifact folder: $_"
            Remove-Item -Path $PathToDelete -Recurse -Force
        }
    }
    
    # e) Remove other unnecessary files
    Get-ChildItem -Path $TempProjectDir -Filter ".vsconfig" -Recurse | Remove-Item -Force
    Get-ChildItem -Path $TempProjectDir -Filter "*.sln.DotSettings.user" -Recurse | Remove-Item -Force
    Get-ChildItem -Path $TempProjectDir -Filter "*.sln" -Recurse | Remove-Item -Force
    Write-Host "Removed solution, user settings, and vsconfig files."

    Write-Host "Conversion and cleaning complete." -ForegroundColor Green

    # --- 4. RENAME PROJECT ---
    $CurrentStage = "RENAME_PROJECT"
    Write-Host "[4/5] [RENAME] Renaming project files and folders..."

    # Shorten plugin name to 8 characters
    $ShortPluginName = if ($Config.PluginName.Length -gt 8) { $Config.PluginName.Substring(0, 8) } else { $Config.PluginName }
    $NewProjectName = "${ShortPluginName}_Example"
    Write-Host "New project name will be: $NewProjectName"

    $OldUProjectFile = Get-ChildItem -Path $TempProjectDir -Filter "*.uproject" | Select-Object -First 1
    if ($OldUProjectFile) {
        Rename-Item -Path $OldUProjectFile.FullName -NewName "$($NewProjectName).uproject"
        Write-Host "Renamed .uproject file to: $($NewProjectName).uproject"
    }

    $ParentDir = (Get-Item $TempProjectDir).Parent.FullName
    $NewTempProjectDir = Join-Path -Path $ParentDir -ChildPath $NewProjectName
    Rename-Item -Path $TempProjectDir -NewName $NewProjectName
    Write-Host "Renamed project folder to: $NewProjectName"


    # --- 5. ZIP THE CLEANED PROJECT ---
    $CurrentStage = "ZIP_PROJECT"
    Write-Host "[5/5] [ZIP] Creating final distributable zip file..."
    $FinalZipPath = Join-Path -Path $OutputBuildsDir -ChildPath "$($NewProjectName)_v$($PluginVersion).zip"
    Compress-Archive -Path $NewTempProjectDir -DestinationPath $FinalZipPath -Force
    
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
    if (Test-Path -Path $NewTempProjectDir) {
        Write-Host "Cleaning up temporary files..."
        Remove-Item -Recurse -Force -Path $NewTempProjectDir
    } elseif (Test-Path -Path $TempProjectDir) { 
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
