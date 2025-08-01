# Local CI/CD for Unreal Code Plugins 🚀

[![Discord](https://img.shields.io/badge/Discord-7289DA?style=for-the-badge&logo=discord&logoColor=white)](https://discord.com/invite/KBWmkCKv5U)
[![License: MIT](https://img.shields.io/badge/License-MIT-007EC7?style=for-the-badge)](LICENSE)

A powerful local CI/CD pipeline for building, testing, and packaging Unreal Engine code plugins across multiple engine versions with a single command.

This tool automates the tedious process of multi-version support, ensuring your plugin is robust and ready for distribution on marketplaces like Fab.com. We have actually use this repo in house to ship our own plugins to Fab store. 

> [!WARNING]  
> This plugin is still under development.
> 1) Do not use it without version control. ⚠️
> 2) Contributions are welcome, especially for non windows platforms.🤝

## The problem statement:
Here is snippet from [Fab.com](https://fab.com)'s submission [guidelines](https://support.fab.com/s/article/FAB-TECHNICAL-REQUIREMENTS?language=en_US):  
> 4.3.6.2 Compilation:

> 4.3.6.2.a Code plugins must generate no errors or consequential warnings.
> 
> 4.3.6.2.b Plugins will be <code style="color : orangered">distributed with the binaries built by Epic’s compilation toolchain</code>, so publishers must ensure that final debugging has been completed by clicking "Package..." on their plugin in the Plugins windows of the editor to test compilation before sending in a new  plugin version. Publishers can also run this command from installed binary builds of each Unreal Engine version they’d like to compile their  plugin for: Engine\Build\BatchFiles\RunUAT.bat BuildPlugin -Plugin=[Path to .uplugin file, must be outside engine directory] -Package=[Output > directory] -Rocket

This basically states that, we as developers need to upload the plugin as source files and not built binaries, then epic will build the binaries for us and ship it to buyers computers. 

## Compatibility

* **Engine Versions**: This tool supports **Unreal Engine 5.1 and newer**.
* **Platform**: Currently designed for **Windows** and packages for the **Win64** platform.

## Prerequisites

<p align="center">
  <img src="Docs/EngineVersions.png" alt="Different Engine Versions" width="450">
</p>

1.  **Windows & PowerShell**: Windows 10/11 with PowerShell 5.1+.
2.  **Unreal Engine**: All the required engine versions must be installed via the Epic Games Launcher.
3.  **Visual Studio 2022**: You must have Visual Studio 2022 installed. From the **Visual Studio Installer**, ensure you have the following components:
    * Under the **Workloads** tab, select **Game development with C++**.
    * Under the **Individual components** tab, you must select the specific MSVC toolchains required for each engine version you intend to build for. These include:
        * `MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.32-17.2)` - **Required for UE 5.1**
        * `MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.34-17.4)` - **Required for UE 5.2**
        * `MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.36-17.6)` - **Required for UE 5.3**
        * `MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.38-17.8)` or newer - **Required for UE 5.4+**
        * `Windows 11 SDK` or `Windows 10 SDK`

> **Note**: To support multiple versions of Unreal Engine, you **must** install the specific MSVC C++ toolchains listed. The build script automatically handles selecting the correct toolchain for each build, but they must be installed first. You can find the latest compatibility information in the [official Unreal Engine documentation](https://dev.epicgames.com/documentation/en-us/unreal-engine/setting-up-visual-studio-development-environment-for-cplusplus-projects-in-unreal-engine).

## Quick Start

### 1. Create Your Configuration

Copy the `config.example.json` file and rename the copy to `config.json`. This file is ignored by git and will contain your local settings.

Open `config.json` and edit the paths and settings to match your project:

```json
{
  "PluginName": "YourPluginName",
  "PluginSourceDirectory": "C:/Path/To/Your/PluginSource",
  "TemplateProjectDirectory": "./TemplateProject",
  "OutputDirectory": "./Builds",
  "UnrealEngineBasePath": "C:/Program Files/Epic Games",
  "EngineVersions": [
    "5.1",
    "5.2",
    "5.3",
    "5.4",
    "5.5",
    "5.6"
  ],
  "AutomationTestFilter": "Project.MyPlugin",
  "RunTests": false
}

```

### 2. Run the Pipeline

Once configured, simply run the main packaging script from a PowerShell terminal in the root of the repository:

```powershell
./package_fast.ps1
```

The script will now loop through each engine version in your config. For each version, it will create:
* A distributable `.zip` file in the `Builds_...` folder.
* A `TestProject` folder with the plugin installed, ready for verification.

## Features

* **Multi-Version Packaging:** Build your plugin for any number of specified Unreal Engine versions automatically.
* **Config-Driven:** All paths and settings are managed in a simple `config.json` file.
* **Dynamic Build Configuration:** The script automatically handles the complex task of forcing Unreal Build Tool to use the correct MSVC compiler toolchain for each engine version.
* **Automated Versioning:** Automatically updates the `.uplugin`'s `EngineVersion` for each build.
* **Clean Packaging & Zipping:** Creates clean, marketplace-ready zip archives for each version. Only the essential `Source`, `Content`, `Resources`, and `.uplugin` files are included as per the [marketplace guidelines](https://support.fab.com/s/article/FAB-TECHNICAL-REQUIREMENTS?language=en_US).
    > 4.3.7.3.a Plugin folders must not contain unused folders or local folders (such as Binaries, Build, Intermediate, or Saved),
* **Automatic Cleanup:** All temporary build files and intermediate projects are automatically deleted after each successful run, leaving only the final, clean artifacts.
* **Detailed Logging:** Generates a separate, detailed log file for each build in a `Logs` directory, making it easy to debug failures.
* **Intelligent Example Project Generation:** Creates a zipped, Blueprint-only example project with lightning speed. The script intelligently copies only the necessary project files, skipping all build artifacts and the main plugin's source folder from the start to ensure a fast and clean packaging process.

---

## Troubleshooting

Here are a few common issues you might encounter:

### 1. "Banned" C++ Compiler Error

When building for a new engine version (e.g., UE 5.5), you might see an error like this:
`UnrealBuildTool has banned the MSVC [version] toolchains due to compiler issues.`

* **Cause**: Epic Games occasionally discovers bugs in a specific version of the Microsoft C++ compiler (MSVC) and will explicitly block it in the Unreal Build Tool to prevent instability.
* **Solution**: Check the error message for the **recommended** toolchain version (e.g., `14.38.33130`). Open the **Visual Studio Installer**, go to the **Individual components** tab, and install that specific `MSVC v143` build tool version.

### 2. Zipping Fails with "Stream was too long"

The `package_example_project.ps1` script might fail with an error like:
`Exception calling "Write" with "3" argument(s): "Stream was too long."`

* **Cause**: This error occurs because PowerShell's built-in `Compress-Archive` command cannot create zip files that contain any single file **larger than 4GB**. Even if your project is small, temporary build artifacts or a large `.uasset` file can trigger this.
* **Solution**: The easiest fix is to use a more robust compression tool. We recommend **[7-Zip](https://www.7-zip.org/)**. Install it and ensure it's added to your system's PATH. Then, you can modify the zipping command in the PowerShell script to use `7z.exe`, which supports the Zip64 format and can handle large files without issue.

---

## Upcoming Features

* **Automated Testing:** The pipeline is structured to easily enable running Unreal's Automation Tests before packaging by setting `"RunTests": true` in the config. This feature is considered experimental.
* **Mac/Linux Support:** Expanding the script to be cross-platform.

## Example:
This repo is also internally used to ship an actual plugin to Fab store called, you can find it [here](https://www.fab.com/listings/68e7f092-1fea-4e6d-8d31-c6b96b06a02e).

After each iteration the output will look something like this:
<p align="center">
  <img src="Docs/OutputSample.png" alt="Output Sample" width="450">
</p>

## Contributing & Support

This project is open-source and contributions are welcome! For questions, bug reports, or feature requests, please open an issue on GitHub or contact us directly at: **mail@muddyterrain.com**

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
