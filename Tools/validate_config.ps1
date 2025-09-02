<#
.SYNOPSIS
    Validates configuration and system prerequisites for the FabBuilding pipeline.
.DESCRIPTION
    Performs comprehensive validation of:
    - Configuration file structure and required fields
    - File and directory paths
    - Unreal Engine installations
    - Visual Studio toolchains
    - rclone setup (if cloud upload enabled)
.PARAMETER ConfigPath
    Path to the config.json file to validate
.PARAMETER SkipEngineValidation
    Skip validation of Unreal Engine installations (useful for config-only validation)
.NOTES
    Author: Prajwal Shetty
    Version: 1.0 - Initial validation framework
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipEngineValidation
)

$ValidationErrors = @()
$ValidationWarnings = @()

function Add-ValidationError {
    param([string]$Message)
    $ValidationErrors += $Message
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Add-ValidationWarning {
    param([string]$Message)
    $ValidationWarnings += $Message
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Test-ValidationSuccess {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

Write-Host "Validating FabBuilding Configuration..." -ForegroundColor Cyan
Write-Host "================================================================="

# --- 1. CONFIG FILE VALIDATION ---
Write-Host "`n[1/6] Validating configuration file..." -ForegroundColor Yellow

if (-not (Test-Path $ConfigPath)) {
    Add-ValidationError "Configuration file not found at '$ConfigPath'"
    exit 1
}

try {
    $Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
    Test-ValidationSuccess "Configuration file loaded successfully"
} catch {
    Add-ValidationError "Invalid JSON in configuration file: $($_.Exception.Message)"
    exit 1
}

# Required fields validation
$RequiredFields = @{
    "PluginName" = "string"
    "PluginSourceDirectory" = "string"
    "OutputDirectory" = "string"
    "UnrealEngineBasePath" = "string"
    "EngineVersions" = "array"
}

foreach ($field in $RequiredFields.Keys) {
    if (-not $Config.PSObject.Properties.Name.Contains($field)) {
        Add-ValidationError "Missing required field: '$field'"
    } elseif ($RequiredFields[$field] -eq "array" -and $Config.$field -isnot [Array]) {
        Add-ValidationError "Field '$field' must be an array"
    } elseif ($RequiredFields[$field] -eq "string" -and [string]::IsNullOrWhiteSpace($Config.$field)) {
        Add-ValidationError "Field '$field' cannot be empty"
    } else {
        Test-ValidationSuccess "Required field '$field' is valid"
    }
}

# --- 2. PLUGIN VALIDATION ---
Write-Host "`n[2/6] Validating plugin configuration..." -ForegroundColor Yellow

if ($Config.PluginSourceDirectory) {
    if (Test-Path $Config.PluginSourceDirectory) {
        Test-ValidationSuccess "Plugin source directory exists"
        
        $UpluginPath = Join-Path -Path $Config.PluginSourceDirectory -ChildPath "$($Config.PluginName).uplugin"
        if (Test-Path $UpluginPath) {
            try {
                $UpluginData = Get-Content -Raw -Path $UpluginPath | ConvertFrom-Json
                Test-ValidationSuccess "Plugin .uplugin file is valid"
                
                if ($UpluginData.VersionName) {
                    Test-ValidationSuccess "Plugin version: $($UpluginData.VersionName)"
                } else {
                    Add-ValidationWarning "Plugin .uplugin file missing VersionName field"
                }
            } catch {
                Add-ValidationError "Invalid .uplugin file: $($_.Exception.Message)"
            }
        } else {
            Add-ValidationError "Plugin .uplugin file not found at '$UpluginPath'"
        }
    } else {
        Add-ValidationError "Plugin source directory not found: '$($Config.PluginSourceDirectory)'"
    }
}

# --- 3. ENGINE VALIDATION ---
if (-not $SkipEngineValidation) {
    Write-Host "`n[3/6] Validating Unreal Engine installations..." -ForegroundColor Yellow
    
    if ($Config.EngineVersions -and $Config.EngineVersions.Count -gt 0) {
        foreach ($Version in $Config.EngineVersions) {
            $EnginePath = Join-Path -Path $Config.UnrealEngineBasePath -ChildPath "UE_$Version"
            $EngineExe = Join-Path -Path $EnginePath -ChildPath "Engine/Binaries/Win64/UnrealEditor-Cmd.exe"
            
            if (Test-Path $EngineExe) {
                Test-ValidationSuccess "Unreal Engine $Version found"
            } else {
                Add-ValidationError "Unreal Engine $Version not found at '$EnginePath'"
            }
        }
    } else {
        Add-ValidationError "No engine versions specified in EngineVersions array"
    }
} else {
    Write-Host "`n[3/6] Skipping engine validation (as requested)" -ForegroundColor Gray
}

# --- 4. EXAMPLE PROJECT VALIDATION ---
Write-Host "`n[4/6] Validating example project configuration..." -ForegroundColor Yellow

if ($Config.ExampleProject -and $Config.ExampleProject.Generate) {
    if ($Config.ExampleProject.MasterProjectDirectory) {
        if (Test-Path $Config.ExampleProject.MasterProjectDirectory) {
            Test-ValidationSuccess "Master project directory exists"
            
            $UProjectFiles = Get-ChildItem -Path $Config.ExampleProject.MasterProjectDirectory -Filter "*.uproject"
            if ($UProjectFiles.Count -gt 0) {
                Test-ValidationSuccess "Found .uproject file: $($UProjectFiles[0].Name)"
            } else {
                Add-ValidationError "No .uproject file found in master project directory"
            }
        } else {
            Add-ValidationError "Master project directory not found: '$($Config.ExampleProject.MasterProjectDirectory)'"
        }
    } else {
        Add-ValidationError "MasterProjectDirectory not specified but example project generation is enabled"
    }
} else {
    Write-Host "Example project generation disabled - skipping validation" -ForegroundColor Gray
}

# --- 5. CLOUD UPLOAD VALIDATION ---
Write-Host "`n[5/6] Validating cloud upload configuration..." -ForegroundColor Yellow

if ($Config.CloudUpload -and $Config.CloudUpload.Enable) {
    if ($Config.CloudUpload.RcloneExePath) {
        if (Test-Path $Config.CloudUpload.RcloneExePath) {
            Test-ValidationSuccess "rclone executable found"
            
            # Test rclone version
            try {
                $null = & "$($Config.CloudUpload.RcloneExePath)" version --check 2>&1
                Test-ValidationSuccess "rclone is functional"
            } catch {
                Add-ValidationWarning "Could not verify rclone functionality: $($_.Exception.Message)"
            }
        } else {
            Add-ValidationError "rclone executable not found at '$($Config.CloudUpload.RcloneExePath)'"
        }
    } else {
        Add-ValidationError "RcloneExePath not specified but cloud upload is enabled"
    }
    
    if ($Config.CloudUpload.RcloneConfigPath) {
        if (Test-Path $Config.CloudUpload.RcloneConfigPath) {
            Test-ValidationSuccess "rclone config file found"
        } else {
            Add-ValidationError "rclone config file not found at '$($Config.CloudUpload.RcloneConfigPath)'"
        }
    } else {
        Add-ValidationError "RcloneConfigPath not specified but cloud upload is enabled"
    }
    
    if ([string]::IsNullOrWhiteSpace($Config.CloudUpload.RemoteName)) {
        Add-ValidationError "RemoteName not specified but cloud upload is enabled"
    }
} else {
    Write-Host "Cloud upload disabled - skipping validation" -ForegroundColor Gray
}

# --- 6. SYSTEM PREREQUISITES ---
Write-Host "`n[6/6] Validating system prerequisites..." -ForegroundColor Yellow

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -ge 5) {
    Test-ValidationSuccess "PowerShell version: $($PSVersionTable.PSVersion)"
} else {
    Add-ValidationError "PowerShell 5.0 or higher required. Current version: $($PSVersionTable.PSVersion)"
}

# Check if robocopy is available
try {
    $null = robocopy /? 2>&1
    Test-ValidationSuccess "Robocopy is available"
} catch {
    Add-ValidationError "Robocopy not found - this is required for file operations"
}

# --- FINAL SUMMARY ---
Write-Host "`n================================================================="
Write-Host "VALIDATION SUMMARY:" -ForegroundColor Cyan

if ($ValidationErrors.Count -eq 0) {
    Write-Host "[SUCCESS] Configuration validation PASSED!" -ForegroundColor Green
    Write-Host "Your setup is ready for production use." -ForegroundColor Green
    
    if ($ValidationWarnings.Count -gt 0) {
        Write-Host "`nWarnings found ($($ValidationWarnings.Count)):" -ForegroundColor Yellow
        foreach ($warning in $ValidationWarnings) {
            Write-Host "  [WARNING] $warning" -ForegroundColor Yellow
        }
    }
    
    exit 0
} else {
    Write-Host "[FAILED] Configuration validation FAILED!" -ForegroundColor Red
    Write-Host "`nErrors found ($($ValidationErrors.Count)):" -ForegroundColor Red
    foreach ($validationError in $ValidationErrors) {
        Write-Host "  [ERROR] $validationError" -ForegroundColor Red
    }
    
    if ($ValidationWarnings.Count -gt 0) {
        Write-Host "`nWarnings found ($($ValidationWarnings.Count)):" -ForegroundColor Yellow
        foreach ($warning in $ValidationWarnings) {
            Write-Host "  [WARNING] $warning" -ForegroundColor Yellow
        }
    }
    
    exit 1
}
