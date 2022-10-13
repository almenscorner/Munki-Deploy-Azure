# Deploy Munki Azure

This script deploys a basic Munki setup on Azure so you don't have to go through the tedious steps of setting up Storage Accounts, creating scripts and profiles etc. to start using Munki for Intune managed macOS devices.

If running the script from a macOS device, you will have to first install [Powershell Core](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-macos?view=powershell-7.2).

## What is deployed?
- Azure Storage account
    - Public container to house Munki tools and middleware
    - Munki container to house the Munki repository. All needed folders are created as part of the deployment
- Intune
    - Profile the clients uses to connect to Azure Storage
    - Shell script for installing Munki tools
- Azure Automation (optional)
    - [Munki Manifest Generator tool script](https://github.com/almenscorner/munki-manifest-generator)
    - All needed Python packages will be imported as part of the deployment

## Required modules
If modules are missing, the script will automatically install them.

- Az.Accounts
- Az.Storage
- Az.Automation
- Az.Resources
- Microsoft.Graph.Authentication

## How do I use it?
First, download the [module](./Deploy-Munki/Deploy-Munki.psm1) in this repository and import it with Powershell,

```powershell
Import-Module "path/to/module.psm1"
```

Then execute with required parameters,

```powershell
Deploy-Munki -resourceGroupName "munki" -automationAccountName "IntuneAutomation" -deployRunbook $True -storageAccountName "testingmunki"
```

The Resource Group and Automation Account used should be existing resources. Everything else is created by the module.