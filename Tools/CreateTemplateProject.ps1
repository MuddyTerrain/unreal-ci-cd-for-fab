#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a minimal, empty Unreal Engine C++ project to be used as a template for plugin packaging and testing.
.DESCRIPTION
    This script creates a valid .uproject file and the necessary C# source files for a blank C++ project.
    It does not include any plugins, as they will be added dynamically during the build process.
.NOTES
    Author: Prajwal Shetty
    Version: 2.0
.EXAMPLE
    PS> ./Tools/CreateTemplateProject.ps1
#>

# --- Configuration ---
$ProjectName = "TemplateProject"
$DefaultEngineVersion = "5.1"  # Default engine version for the template

# --- Script Body ---
$RepoRoot = $PSScriptRoot | Split-Path -Parent
$TemplateDir = Join-Path -Path $RepoRoot -ChildPath $ProjectName

Write-Host "=================================================================" -ForegroundColor Green
Write-Host " Unreal Template Project Generator" -ForegroundColor Green
Write-Host "================================================================="

try {
    if (Test-Path $TemplateDir) {
        Write-Warning "Existing '$ProjectName' directory found. It will be overwritten."
    }

    Write-Host "[1/4] Creating directories for '$ProjectName'..."
    $SourceDir = Join-Path -Path $TemplateDir -ChildPath "Source"
    $ProjectModuleDir = Join-Path -Path $SourceDir -ChildPath $ProjectName
    New-Item -Path $ProjectModuleDir -ItemType Directory -Force | Out-Null

    # --- Create .uproject file ---
    Write-Host "[2/4] Generating $ProjectName.uproject..."
    $UProjectContent = @{
        FileVersion = 3
        EngineAssociation = $DefaultEngineVersion
        Category = ""
        Description = ""
        Modules = @(
            @{
                Name = $ProjectName
                Type = "Runtime"
                LoadingPhase = "Default"
            }
        )
    }
    $UProjectContent | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $TemplateDir "$ProjectName.uproject") -Encoding utf8

    # --- Create Target.cs files ---
    Write-Host "[3/4] Generating Target.cs files..."
    $TargetCsContent = @"
// Copyright Epic Games, Inc. All Rights Reserved.

using UnrealBuildTool;
using System.Collections.Generic;

public class $($ProjectName)Target : TargetRules
{
	public $($ProjectName)Target(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Game;
		DefaultBuildSettings = BuildSettingsVersion.V2;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_1;
		ExtraModuleNames.Add("$ProjectName");
	}
}
"@
    $TargetCsContent | Out-File -FilePath (Join-Path $SourceDir "$($ProjectName).Target.cs") -Encoding utf8

    $EditorTargetCsContent = @"
// Copyright Epic Games, Inc. All Rights Reserved.

using UnrealBuildTool;
using System.Collections.Generic;

public class $($ProjectName)EditorTarget : TargetRules
{
	public $($ProjectName)EditorTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Editor;
		DefaultBuildSettings = BuildSettingsVersion.V2;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_1;
		ExtraModuleNames.Add("$ProjectName");
	}
}
"@
    $EditorTargetCsContent | Out-File -FilePath (Join-Path $SourceDir "$($ProjectName)Editor.Target.cs") -Encoding utf8

    # --- Create Build.cs file ---
    Write-Host "[4/4] Generating Build.cs file..."
    $BuildCsContent = @"
// Copyright Epic Games, Inc. All Rights Reserved.

using UnrealBuildTool;

public class $ProjectName : ModuleRules
{
	public $ProjectName(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
	
		PublicDependencyModuleNames.AddRange(new string[] { "Core", "CoreUObject", "Engine", "InputCore" });

		PrivateDependencyModuleNames.AddRange(new string[] {  });
	}
}
"@
    $BuildCsContent | Out-File -FilePath (Join-Path $ProjectModuleDir "$($ProjectName).Build.cs") -Encoding utf8

    Write-Host "`n[SUCCESS] Template project '$ProjectName' created successfully." -ForegroundColor Green

} catch {
    Write-Error "`n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Error "!!!!    TEMPLATE CREATION FAILED    !!!!"
    Write-Error "!!!!    Error: $($_.Exception.Message)"
    Write-Error "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 1
}