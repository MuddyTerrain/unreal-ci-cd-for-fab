# Unreal Plugin Local CI/CD

A powerful local CI/CD pipeline for building, testing, and packaging Unreal Engine plugins across multiple engine versions with a single command.

This tool automates the tedious process of multi-version support, ensuring your plugin is robust and ready for distribution on marketplaces like Fab.

## Compatibility

* **Engine Versions**: This tool currently only supports **Unreal Engine 5.1 and newer** as it has only been tested with these versions.
* **Platform**: Currently designed for **Windows**.

## Prerequisites

1.  **Windows & PowerShell**: Windows 10/11 with PowerShell 5.1+.

2.  **Unreal Engine**: The required engine versions must be installed from the Epic Games Launcher.

3.  **Visual Studio 2022**: You must have Visual Studio 2022 installed. From the **Visual Studio Installer**, ensure you have the following components:
    * Under the **Workloads** tab, select **Game development with C++**.
    * Under the **Individual components** tab, select the following items:
        * `MSVC v143 - VS 2022 C++ x64/x86 build tools (Latest)`
        * `MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.36-17.6)` - **Required for UE 5.3**
        * `MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.34-17.4)` - **Required for UE 5.2**
        * `MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.32-17.2)` - **Required for UE 5.1**
        * `Windows 11 SDK` or `Windows 10 SDK`

> **Note**: To support multiple versions of Unreal Engine, you must install the specific MSVC C++ toolchains listed above. Relying only on the `(Latest)` toolchain will cause build failures on older engine versions. You can find the latest compatibility information in the [official Unreal Engine documentation](https://dev.epicgames.com/documentation/en-us/unreal-engine/setting-up-visual-studio-development-environment-for-cplusplus-projects-in-unreal-engine).

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

## Features

* **Multi-Version Packaging:** Build your plugin for any number of specified Unreal Engine versions automatically.
* **Config-Driven:** All paths and settings are managed in a simple `config.json` file.
* **Automated Project Generation:** Includes a one-time script to generate a minimal C++ project to serve as a build host.
* **Testable Project Creation:** For each engine version, the pipeline generates a clean, standalone host project with your plugin already installed, ready for manual testing or opening in an IDE.
* **Automated Versioning:** Automatically updates the `.uplugin`'s `EngineVersion` for each build.
* **Clean Packaging & Zipping:** Creates clean, marketplace-ready zip archives for each version, with `Binaries` and `Intermediate` folders removed.
* **Detailed Logging:** Generates a separate, detailed log file for each build in a `Logs` directory, making it easy to debug failures.

## Upcoming Features

* **Automated Testing:** The pipeline is structured to easily enable running Unreal's Automation Tests before packaging by setting `"RunTests": true` in the config. This feature is considered experimental.
* **Mac/Linux Support:** Expanding the script to be cross-platform.

## Contributing & Support

This project is open-source and contributions are welcome! For questions, bug reports, or feature requests, please open an issue on GitHub or contact us directly at: **mail@muddyterrain.com**

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

