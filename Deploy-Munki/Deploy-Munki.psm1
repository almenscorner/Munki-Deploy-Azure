<#
    .SYNOPSIS
    This script will deploy all parts needed to create the basic structure for a Munki setup on Azure.

    .NOTES
    Author: Tobias Almén (almenscorner)
    Version: 1.0

    .DESCRIPTION
    Running this script, a new Storage Account will be created that hosts the Munki repository as well as Intune profiles,
    scripts and runbooks. The location and subscription Id used will be based on the resource group

    The following resources will be deployed,
        Azure Storage
            New storage account
            Munki and Public containers
            Munkitools package uploaded to public container
            Middleware package uploaded to public container
            Munki repo structure
            SAS Token
        Intune
            Munki profile for clients to connect to Azure Storage
            Munki install script for clients to install Munkitools and middleware
        Azure Automation
            Munki-Manifest-Generator runbook with a template script
            Runbook to auto import all required Python packages, deleted upon completion

    Required modules to run:
    - Az.Accounts
    - Az.Storage
    - Az.Automation
    - Az.Resources
    - Microsoft.Graph.Authentication

    .EXAMPLE
    Deploy-Munki -resourceGroupName "munki" -automationAccountName "IntuneAutomation" -deployRunbook $True -storageAccountName "testingmunki"
#>
function Deploy-Munki {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$True)]
        [string]$resourceGroupName,

        [Parameter(Mandatory=$False)]
        [string]$automationAccountName,

        [Parameter(Mandatory=$False)]
        [System.Boolean]$deployRunbook,

        [Parameter(Mandatory=$True)]
        [string]$storageAccountName
    )
    
    # Check required modules
    $dependencies = @("Az.Accounts", "Az.Storage", "Az.Automation", "Az.Resources", "Microsoft.Graph.Authentication")

    foreach ($dependency in $dependencies) {
        if (!$(Get-Module -ListAvailable -Name $dependency)) {
            Write-Warning "Module $($dependency) is required, installing..."
            Install-Module -Name $dependency
        }
    }

    # Authenticate to Azure and Graph
    $authAz = Connect-AzAccount
    $authGraph = Connect-MgGraph -Scopes DeviceManagementConfiguration.ReadWrite.All

    # Set name and path variables
    $profileName = "Munki.mobileconfig"
    $scriptName = "installMunki.sh"
    $profilePath = "$($PSScriptRoot)/$($profileName)"
    $scriptPath = "$($PSScriptRoot)/$($scriptName)"
    $runbookTemplateName = "runbooktemplate.py"
    $templatePath = "$($PSScriptRoot)/$($runbookTemplateName)"
    $templateImportName = "import_py3package_from_pypi.py"
    $templateImportPath = "$($PSScriptRoot)/$($templateImportName)"
    $runbookName = "macOS-Munki-Manifest-Generator"

    # Set URI variables
    $munkiReleasesUri = "https://api.github.com/repos/munki/munki/releases/latest"
    $response = Invoke-RestMethod -Method "GET" -Uri $munkiReleasesUri
    $lastRelease = $response.assets | Where-Object name -like "munkitools-*.*.pkg"
    $pkgUri = $lastRelease.browser_download_url
    $middlewareUri = "https://raw.githubusercontent.com/okieselbach/Munki-Middleware-Azure-Storage/master/middleware_azure.py"
    $installScriptUri = "https://raw.githubusercontent.com/almenscorner/Munki-Deploy-Azure/main/$($scriptName)"
    $templateRunbookUri = "https://raw.githubusercontent.com/almenscorner/Munki-Deploy-Azure/main/$($runbookTemplateName)"
    $importRunbookUri = "https://raw.githubusercontent.com/azureautomation/runbooks/bb51e59aaa9d93c8662abae29745e4225a9d076f/Utility/Python/import_py3package_from_pypi.py"

    # Create Storage Account and containers
    function New-StorageAccount {

        try {
            $Location = $(Get-AzResourceGroup -Name $resourceGroupName).Location

            $storageAccounts = $(Get-AzStorageAccount -ResourceGroupName $resourceGroupName).StorageAccountName

            foreach ($storageAccount in $storageAccounts) {
                if ($storageAccount -eq $storageAccountName) {
                    Write-Warning "Storage account $($storageAccountName) already exists"
                    $storageAccountName = Read-Host "Enter a new Storage Account name and press Enter to continue"
                }
            }
            
            # Create storage account
            $storageAccount = New-AzStorageAccount -Name $storageAccountName `
                                                   -Kind StorageV2 `
                                                   -SkuName Standard_LRS `
                                                   -AccessTier Hot `
                                                   -resourceGroupName $resourceGroupName `
                                                   -Location $location

            $key = Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $storageAccountName
            $context = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $key.Value[0]

            # Create munki container and get SAS token
            $munkiContainer = New-AzStorageContainer -Context $context -Name "munki" -Permission Off | `
                            New-AzStorageContainerSASToken -ExpiryTime $(Get-Date).AddDays(180) -Permission rl -Protocol HttpsOnly
            # Create public container
            $publicContainer = New-AzStorageContainer -Context $context -Name "public" -Permission Blob
        }
        catch{
            Write-Warning "Failed to create storage account with error: $($Error[0])`n"
            throw
        }

        Write-Host -ForegroundColor Cyan "Creating munki repo structure"

        # Create munki repo on blob storage
        $tempFile = New-Item -Path $PSScriptRoot -Name "temp.txt" -Force
        $repoFolders = @("manifests", "pkgs", "pkginfo", "icons", "catalogs")

        try {
            foreach ($folder in $repoFolders) {
                $Blob = @{
                    File             = $tempFile.FullName
                    Container        = "munki"
                    Blob             = "$($folder)/$($tempFile.Name)"
                    Context          = $context
                    StandardBlobTier = 'Hot'
                }

                $uploadFile = Set-AzStorageBlobContent @Blob

                Write-Host -ForegroundColor Green "$($folder) created"
            }
        }
        catch{
            Write-Warning "Failed to create structure with error: $($Error[0])`n"
            throw
        }

        Remove-Item -Path $tempFile.FullName

        Write-Host -ForegroundColor Cyan "Downloading munkitools and middleware"

        # Download and upload munkitools and middleware to blob
        $pkgName = $pkgUri.Split("/")[-1]
        $middlewareName = $middlewareUri.Split("/")[-1]
        $uploads = @($pkgName, $middlewareName)
        $pkg = Invoke-WebRequest -Uri $pkgUri -OutFile "$($PSScriptRoot)/$($pkgName)"
        $middleware = Invoke-WebRequest -Uri $middlewareUri -OutFile "$($PSScriptRoot)/$($middlewareName)"
        $installScript = Invoke-WebRequest -Uri $installScriptUri


        Write-Host -ForegroundColor Cyan "Uploading munkitools and middleware to public container"

        try {
            foreach ($upload in $uploads) {
                $Blob = @{
                    File             = "$($PSScriptRoot)/$($upload)"
                    Container        = "public"
                    Blob             = $upload
                    Context          = $context
                    StandardBlobTier = 'Hot'
                }

                $uploadFile = Set-AzStorageBlobContent @Blob

                Write-Host -ForegroundColor Green "$($upload) uploaded"

                Remove-Item -Path "$($PSScriptRoot)/$($upload)"
            }
        }
        catch{
            Write-Warning "Failed to upload with error: $($Error[0])`n"
            throw
        }
        
        # Create Intune Munki profile with Storage Account URI and escaped SAS token
        $mobileconfig = "<?xml version=""1.0"" encoding=""utf-8""?>
<!DOCTYPE plist PUBLIC ""-//Apple//DTD PLIST 1.0//EN"" ""http://www.apple.com/DTDs/PropertyList-1.0.dtd"">
<plist version=""1.0"">
    <dict>
        <key>PayloadContent</key>
        <array>
            <dict>
                <key>PayloadDisplayName</key>
                <string>Munki</string>
                <key>PayloadIdentifier</key>
                <string>ManagedInstalls</string>
                <key>PayloadType</key>
                <string>ManagedInstalls</string>
                <key>PayloadUUID</key>
                <string>d81b0444-0710-11ec-9a03-0242ac130003</string>
                <key>PayloadVersion</key>
                <integer>1</integer>
                <key>SoftwareRepoURL</key>
                <string>https://$($storageAccountName).blob.core.windows.net/munki</string>
                <key>SharedAccessSignature</key>
                <string>$([Security.SecurityElement]::Escape($munkiContainer))</string>
            </dict>
        </array>
        <key>PayloadIdentifier</key>
        <string>ec9a605e-0710-11ec-9a03-0242ac130003</string>
        <key>PayloadType</key>
        <string>Configuration</string>
        <key>PayloadUUID</key>
        <string>f5f2fa80-0710-11ec-9a03-0242ac130003</string>
        <key>PayloadVersion</key>
        <integer>1</integer>
    </dict>
</plist>" | Out-File -FilePath $profilePath

        # Create Intune Munki install script replacing variables in script to point to the newly created storage account
        (($installScript) -replace 'weburl=""', 
                                   "weburl=""https://$($storageAccountName).blob.core.windows.net/public/$($pkgName)"" " `
                          -replace 'weburl_middleware=""', 
                                   "weburl_middleware=""https://$($storageAccountName).blob.core.windows.net/public/$($middlewareName)"" " `
                          -replace 'appname=""', 
                                   "appname=""$($pkgName)"" ") | Out-File $scriptPath

    }

    # Create Munki Intune profile and script
    function New-IntuneSetup {
        
        # Base64 encode previosly created mobileconfig
        $payload = (Get-Content $profilePath -raw) -replace "`r`n","`n"
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))

        $Body = @{
            '@odata.type' = "#microsoft.graph.macOSCustomConfiguration";
            description = "Configures Munki on macOS clients to connect to Azure Storage";
            displayName = "macOS-Munki-Deploy-MunkiConf";
            payloadName = "Munki";
            payloadFileName = "Munki.mobileconfig";
            payload = $payload
        }

        try {
            # Create Munki profile in Intune
            $request = Invoke-MgGraphRequest -Method POST -Uri "v1.0/deviceManagement/deviceConfigurations" -Body $Body | ConvertTo-Json
            Remove-Item $profilePath
            Write-Host -ForegroundColor Green "Profile created"
        }
        catch{
            Write-Warning "Failed to create profile with error: $($Error[0])`n"
            throw
        }

        # Base64 encode Munki install script previously created
        $scriptContent = (Get-Content $scriptPath -raw) -replace "`r`n","`n"
        $scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptContent))

        $Body = @{
            description = "Script to install Munki tools on clients";
            displayName = "macOS-Munki-Deploy-InstallScript";
            runAsAccount = "system";
            fileName = "installMunki.sh";
            scriptContent = $scriptContent
            executionFrequency = "PT0S"
            retryCount = 3
            blockExecutionNotifications = $True
        }

        try {
            # Create Munki install script in Intune
            $request = Invoke-MgGraphRequest -Method POST -Uri "beta/deviceManagement/deviceShellScripts" -Body $Body | ConvertTo-Json
            Remove-Item $scriptPath
            Write-Host -ForegroundColor Green "Shell script created"
        }
        catch{
            Write-Warning "Failed to create shell script with error: $($Error[0])`n"
            throw
        }
    }

    # Create Runbook
    function New-Runbook {

        try{
            $runbooks = $(Get-AzAutomationRunbook -AutomationAccountName $automationAccountName `
                                                  -ResourceGroupName $resourceGroupName).Name

            foreach ($runbook in $runbooks) {
                if ($runbook -eq $runbookName) {
                    Write-Warning "Runbook $($runbookName) already exists"
                    $overwrite = Read-Host "Do you want to overwrite the existing runbook? (y/n)"
                }
            }

            if ($overwrite -eq "y") {
                Remove-AzAutomationRunbook -AutomationAccountName $automationAccountName `
                -ResourceGroupName $resourceGroupName `
                -Name $runbookName
            }
            else {
                Write-Host -ForegroundColor Yellow "Runbook $($runbookName) not overwritten"
                return
            }

            Write-Host -ForegroundColor Cyan "Getting runbook Munki manifest template"

            $getRunbookTemplate = Invoke-WebRequest -Uri $templateRunbookUri `
                                                    -OutFile "$($PSScriptRoot)/$($runbookTemplateName)"

            Write-Host -ForegroundColor Cyan "Getting runbook import python package template"

            $getImportPackageScript = Invoke-WebRequest -Uri $importRunbookUri `
                                                       -OutFile "$($PSScriptRoot)/$($templateImportName)"

            $createRunbook = Import-AzAutomationRunbook -Path $templatePath `
                                    -Name $runbookName -AutomationAccountName $automationAccountName `
                                    -ResourceGroupName $resourceGroupName `
                                    -Type Python3

            $importScriptContent = Get-Content -Path $templateImportPath
            $importScriptContent.Replace("pip.main(['download', '-d', download_dir, packagename])", 
                                         "pip.main(['download', '-d', download_dir, '--no-deps', packagename])") | `
                                          Set-Content -Path $templateImportPath

            $createImportRunbook = Import-AzAutomationRunbook -Path $templateImportPath `
                                    -Name "Python3importpackage" -AutomationAccountName $automationAccountName `
                                    -ResourceGroupName $resourceGroupName `
                                    -Type Python3 `
                                    -Published

            Write-Host -ForegroundColor Green "Runbook created"
            Write-Host -ForegroundColor Cyan "Importing Python packages"

            $subscriptionId = $(Get-AzResourceGroup -Name $resourceGroupName).ResourceId.Split("/")[2]

            $modules = @("Munki-Manifest-Generator", "msrest", "azure-storage-blob", "azure-core", "adal", "typing_extensions")

            foreach ($module in $modules) {
                $params = @{"params" = "-s $($subscriptionId) -g $($resourceGroupName) -a $($automationAccountName) -m $($module)"}
                $startImportRunbook = Start-AzAutomationRunbook -AutomationAccountName $automationAccountName `
                                                                -Name "Python3importpackage" `
                                                                -ResourceGroupName $resourceGroupName `
                                                                -Parameters $params `
                                                                -Wait

                Write-Host -ForegroundColor Green "Starting import of $($module)"
            }

            Remove-AzAutomationRunbook -Name "Python3importpackage" -ResourceGroupName $resourceGroupName -AutomationAccountName $automationAccountName -Confirm:$false -Force

            Remove-Item -Path $templatePath
            Remove-Item -Path $templateImportPath
        }
        catch{
            Write-Warning "Unable to create runbook with error: $($Error[0])`n"
            throw
        }

    }

    Write-Host -ForegroundColor DarkGray "#-------------------------------------------------------------#"
    Write-Host -ForegroundColor DarkGray "                          Azure Storage                        "
    Write-Host -ForegroundColor DarkGray "#-------------------------------------------------------------#"
    Write-Host -ForegroundColor Cyan "Creating Storage Account"
    New-StorageAccount -storageAccountName $storageAccountName


    Write-Host -ForegroundColor DarkGray "#-------------------------------------------------------------#"
    Write-Host -ForegroundColor DarkGray "                             Intune                            "
    Write-Host -ForegroundColor DarkGray "#-------------------------------------------------------------#"
    Write-Host -ForegroundColor Cyan "Creating Profile and Shell script"
    New-IntuneSetup

    if ($deployRunbook -ne $False) {
        Write-Host -ForegroundColor DarkGray "#-------------------------------------------------------------#"
        Write-Host -ForegroundColor DarkGray "                        Azure Automation                       "
        Write-Host -ForegroundColor DarkGray "#-------------------------------------------------------------#"
        Write-Host -ForegroundColor Cyan "Creating Munki Manifest Generator Runbook"
        New-Runbook -resourceGroupName $resourceGroupName -automationAccountName $automationAccountName
    }

}