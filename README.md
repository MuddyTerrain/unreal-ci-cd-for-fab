# Unreal Plugin Local CI/CD

A powerful local CI/CD pipeline for building, testing, and packaging Unreal Engine plugins across multiple engine versions with a single command.

This tool automates the tedious process of multi-version support, ensuring your plugin is robust and ready for distribution on marketplaces like Fab.

## Features

* **Multi-Version Packaging:** Build your plugin for any number of specified Unreal Engine versions automatically.
* **Config-Driven:** All paths and settings are managed in a simple `config.json` file.
* **Automated Project Generation:** Includes a one-time script to generate a minimal C++ project to serve as a build host.
* **Testable Project Creation:** For each engine version, the pipeline generates a clean, standalone host project with your plugin already installed, ready for manual testing or opening in an IDE.
* **Automated Versioning:** Automatically updates the `.uplugin`'s `EngineVersion` for each build.
* **Clean Packaging & Zipping:** Creates clean, marketplace-ready zip archives for each version, with `Binaries` and `Intermediate` folders removed.
* **Detailed Logging:** Generates a separate, detailed log file for each build in a `Logs` directory, making it easy to debug failures.

## Compatibility

* **Engine Versions:** This tool is confirmed to work with **Unreal Engine 5.2 and newer**. Due to C++ toolchain incompatibilities in older engine versions, UE 5.1 and below may fail to compile and are not officially supported by this script.
* **Platform:** Currently designed for **Windows**.

## Prerequisites

1.  **Windows & PowerShell:** This script is designed for Windows and uses PowerShell 5.1+, which comes pre-installed on Windows 10 and 11.
2.  **Unreal Engine Versions:** You must have the desired engine versions installed via the Epic Games Launcher in their default locations (e.g., `C:\Program Files\Epic Games\UE_5.3`).
3.  **Visual Studio:** The "Game development with C++" workload must be installed in Visual Studio.

## Quick Start

### 1. One-Time Template Project Generation

You need a minimal Unreal project to act as a host for building the plugin. This script generates it for you. This only needs to be done once.

Open a PowerShell terminal in the root of this repository and run:

```powershell
./Tools/CreateTemplateProject.ps1
```

This will create a `TemplateProject` folder in the root directory. This folder is ignored by git and is only used locally on your machine.

### 2. Create Your Configuration

Copy the `config.example.json` file and rename the copy to `config.json`. This file will not be committed to git.

Open `config.json` and edit the paths and settings to match your project:

```json
{
  "PluginName": "MyAwesomePlugin",
  "PluginSourceDirectory": "C:/Dev/MyAwesomePlugin",
  "TemplateProjectDirectory": "./TemplateProject",
  "OutputDirectory": "./Builds",
  "EngineVersions": [
    "5.2",
    "5.3",
    "5.4"
  ],
  "RunTests": false,
  "AutomationTestFilter": "Project.MyAwesomePlugin"
}
```

### 3. Run the Pipeline

Once configured, simply run the main packaging script from a PowerShell terminal:

```powershell
./package.ps1
```

The script will now loop through each engine version in your config, creating a testable host project and a distributable `.zip` file for each one in the `Builds` directory.

## Upcoming Features

* **Automated Testing:** The pipeline is structured to easily enable running Unreal's Automation Tests before packaging by setting `"RunTests": true` in the config. This feature is considered experimental.
* **Mac/Linux Support:** Expanding the script to be cross-platform.

## Contributing & Support

This project is open-source and contributions are welcome! For questions, bug reports, or feature requests, please open an issue on GitHub or contact us directly at: **mail@muddyterrain.com**

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

