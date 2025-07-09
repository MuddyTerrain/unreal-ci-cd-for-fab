#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a minimal, empty Unreal Engine C++ project to be used as a template for plugin packaging.
.DESCRIPTION
    This script creates a valid .uproject file and the necessary C# source files for a blank C++ project.
    This avoids the need for users to manually create a template project through the Unreal Editor.
    It should be run once from the root directory of the repository.
.EXAMPLE
    PS> ./Tools/CreateTemplateProject.ps1
#>

# --- Configuration ---
$ProjectName = "TemplateProject"
$EngineVersion = "5.2" # The script needs a base version, but the main build script will overwrite this later.

# --- Script Body ---
$RepoRoot = $PSScriptRoot | Split-Path -Parent
$TemplateDir = Join-Path -Path $RepoRoot -ChildPath $ProjectName
$SourceDir = Join-Path -Path $TemplateDir -ChildPath "Source"
$ProjectModuleDir = Join-Path -Path $SourceDir -ChildPath $ProjectName

# Create directories
Write-Host "Creating directories for '$ProjectName'..."
New-Item -Path $TemplateDir -ItemType Directory -Force | Out-Null
New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null
New-Item -Path $ProjectModuleDir -ItemType Directory -Force | Out-Null

# --- Create .uproject file ---
Write-Host "Generating $ProjectName.uproject..."
$UProjectContent = @{
    FileVersion = 3
    EngineAssociation = $EngineVersion
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
Write-Host "Generating Target.cs files..."
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
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_2;
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
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_2;
		ExtraModuleNames.Add("$ProjectName");
	}
}
"@
$EditorTargetCsContent | Out-File -FilePath (Join-Path $SourceDir "$($ProjectName)Editor.Target.cs") -Encoding utf8

# --- Create Build.cs file ---
Write-Host "Generating Build.cs file..."
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

# --- Create main C++ source file ---
Write-Host "Generating primary game module source file..."
$ModuleCppContent = @"
// Copyright Epic Games, Inc. All Rights Reserved.

#include "Modules/ModuleManager.h"

IMPLEMENT_PRIMARY_GAME_MODULE( FDefaultGameModuleImpl, $ProjectName, "$ProjectName" );
"@
$ModuleCppContent | Out-File -FilePath (Join-Path $ProjectModuleDir "$($ProjectName).cpp") -Encoding utf8

Write-Host "`nTemplate project '$ProjectName' created successfully in the root directory."
Write-Host "You can now run the main package.ps1 script."
# End of script