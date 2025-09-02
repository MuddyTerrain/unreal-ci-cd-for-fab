# Gemini Project Overview: Local CI/CD for Unreal Engine Plugins

## Project Overview

This repository contains a powerful, modular local CI/CD pipeline designed to build, package, and distribute Unreal Engine code plugins and their example projects across multiple engine versions. It is a PowerShell-based toolchain that automates the process of multi-version support, ensuring plugins are ready for distribution on marketplaces like Fab.com.

The pipeline is driven by a central `config.json` file and orchestrated by a master PowerShell script, `run_pipeline.ps1`. It supports packaging the plugin source, generating version-specific example projects from a master project, and uploading the final artifacts to a cloud storage provider using `rclone`.

### Key Technologies

*   **Scripting:** PowerShell
*   **Engine:** Unreal Engine (versions 5.1+)
*   **Configuration:** JSON (`config.json`)
*   **Cloud Storage:** `rclone` (for optional uploads)

### Core Workflow

The pipeline follows a "Develop Low, Upgrade High" philosophy:

1.  **Develop in the Oldest Version:** The master example project is maintained in the oldest supported engine version (e.g., UE 5.1).
2.  **Automate Upgrades:** The `run_pipeline.ps1` script creates temporary copies of the master project and uses Unreal Engine's command-line tools to upgrade them for each newer target version.
3.  **Package and Distribute:** The script packages the plugin and the version-specific example projects into clean, marketplace-ready `.zip` files.

## Building and Running

This is a PowerShell-based project. The main entry point is the `run_pipeline.ps1` script.

1.  **Configuration:**
    *   Copy `config.example.json` to `config.json`.
    *   Edit `config.json` to specify paths to your plugin, example project, and Unreal Engine installations.

2.  **Validation:**
    *   Run the validation script to ensure your environment is set up correctly:
        ```powershell
        .\Tools\validate_config.ps1 -ConfigPath "config.json"
        ```

3.  **Execution:**
    *   Run the master pipeline script from a PowerShell terminal:
        ```powershell
        .\run_pipeline.ps1
        ```
    *   Use the `-DryRun` parameter to see what the script will do without actually performing any actions:
        ```powershell
        .\run_pipeline.ps1 -DryRun
        ```

## Development Conventions

*   **Project Structure:** The repository is structured around a main pipeline script (`run_pipeline.ps1`) and a `Tools` directory containing modular helper scripts.
*   **Configuration:** All project-specific settings are managed in a `config.json` file, which is ignored by git.
*   **Logging:** The pipeline generates detailed logs for each operation, which are stored in a timestamped output directory (e.g., `Builds_YYYYMMDD_HHMMSS/Logs`).
*   **Modularity:** The pipeline is designed to be modular. The main script calls other scripts in the `Tools` directory to perform specific tasks like packaging the plugin, packaging the example project, and uploading to the cloud.
