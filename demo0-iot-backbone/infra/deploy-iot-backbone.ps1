#!/usr/bin/env pwsh
#Requires -Version 7
<#
.SYNOPSIS
    Deploys the GEOINT Demo 0 ΓÇö IoT Backbone module to an Azure Local cluster.

.DESCRIPTION
    Fully parameterized deployment script.  All cluster-specific values
    (subscription IDs, cluster names, credentials) are read from an .env file.
    No values are hardcoded in this script.

        Steps performed:
            1. Validate Azure CLI login and required extensions
            2. Create the 'azure-iot-operations' K8s namespace + RBAC
            3. Ensure cert-manager + trust-manager (installs if missing)
            4. Deploy Azure IoT Operations extension
            5. Wait for extension to reach Succeeded state
            6. Create K8s Secrets for MQTT credentials
            7. Apply MQTT broker, asset definitions, and pipeline manifests
            8. Build and push sensor-simulator Docker image to ACR
            9. Build and push alert-processor Docker image to ACR
         10. Apply simulator and processor K8s manifests
         11. Print summary

.PARAMETER EnvFile
    Path to the .env file containing all cluster-specific configuration.
    Default: .env (relative to repo root)

.PARAMETER DryRun
    Print all commands without executing them.

.PARAMETER Teardown
    Reverse all deployment steps and clean up resources.

.EXAMPLE
    # Deploy to staging cluster
    .\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.staging

.EXAMPLE
    # Dry-run to verify commands
    .\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.staging -DryRun

.EXAMPLE
    # Teardown
    .\demo0-iot-backbone\infra\deploy-iot-backbone.ps1 -EnvFile .env.staging -Teardown
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string]  $EnvFile = ".env",
    [switch]  $DryRun,
    [switch]  $Teardown
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ΓöÇΓöÇ Repo root (two levels up from this script) ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
$RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$Demo0Root  = Join-Path $RepoRoot "demo0-iot-backbone"

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Helper: Run or print a command depending on -DryRun
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Invoke-Step {
    <#
    .SYNOPSIS
        Execute a command, or print it if -DryRun is set.
    #>
    param(
        [string]   $Description,
        [string[]] $Command
    )
    Write-Host "`nΓû╢  $Description" -ForegroundColor Cyan
    $cmdStr = $Command -join " "
    Write-Host "   $cmdStr" -ForegroundColor DarkGray
    if (-not $DryRun) {
        & $Command[0] $Command[1..($Command.Length - 1)]
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed (exit $LASTEXITCODE): $cmdStr"
        }
    }
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Step 0 ΓÇö Load .env file
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Import-EnvFile {
    <#
    .SYNOPSIS
        Load key=value pairs from an .env file into the current process environment.
    #>
    param([string] $Path)

    $resolved = Resolve-Path $Path -ErrorAction Stop
    Write-Host "Loading environment from: $resolved" -ForegroundColor Green
    foreach ($line in Get-Content $resolved) {
        # Skip comments and blank lines
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^([^=]+)=(.*)$') {
            $key   = $Matches[1].Trim()
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
        }
    }
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Step 1 ΓÇö Validate Azure CLI + required extensions
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Assert-AzureCli {
    <#
    .SYNOPSIS
        Verify az CLI is logged in and the required extensions are installed.
    #>
    Write-Host "`n[1/10] Validating Azure CLI login..." -ForegroundColor Yellow

    $account = az account show --query id -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Not logged in to Azure CLI.  Run: az login"
    }
    Write-Host "   Subscription: $account" -ForegroundColor Green

    $requiredExtensions = @("azure-iot-ops", "connectedk8s", "k8s-extension")
    foreach ($ext in $requiredExtensions) {
        $installed = az extension list --query "[?name=='$ext'].name" -o tsv 2>&1
        if (-not $installed) {
            Write-Host "   Installing extension: $ext" -ForegroundColor Yellow
            if (-not $DryRun) {
                az extension add --name $ext --yes
            }
        } else {
            Write-Host "   Extension OK: $ext" -ForegroundColor Green
        }
    }
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Step 2+3 ΓÇö Create namespace and apply RBAC
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Deploy-Namespace {
    <#
    .SYNOPSIS
        Create the azure-iot-operations namespace and apply RBAC manifests.
    #>
    Write-Host "`n[2/10] Creating namespace azure-iot-operations..." -ForegroundColor Yellow

    Invoke-Step -Description "Create namespace (idempotent)" -Command @(
        "kubectl", "create", "namespace", "azure-iot-operations", "--dry-run=client", "-o", "yaml"
    )
    if (-not $DryRun) {
        kubectl create namespace azure-iot-operations --dry-run=client -o yaml | kubectl apply -f -
    }

    Invoke-Step -Description "Apply namespace RBAC" -Command @(
        "kubectl", "apply", "-f", (Join-Path $Demo0Root "infra\iot-namespace.yaml")
    )
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Step 4+5 ΓÇö Deploy Azure IoT Operations extension via Bicep
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Deploy-IotOpsExtension {
    <#
    .SYNOPSIS
        Install or update the Azure IoT Operations k8s extension, then
        poll until the extension reaches Succeeded state.
    #>
    Write-Host "`n[3/10] Deploying Azure IoT Operations extension..." -ForegroundColor Yellow

    $sub         = $env:AZURE_SUBSCRIPTION_ID
    $rg          = $env:AZURE_RESOURCE_GROUP
    $clusterName = $env:AKS_CLUSTER_NAME
    $extVersion  = $env:IOT_OPS_EXTENSION_VERSION ?? "latest"
    $extName     = "azure-iot-operations"

    if (-not $DryRun) {
        $existingState = az k8s-extension show `
            --cluster-name $clusterName `
            --cluster-type connectedClusters `
            --resource-group $rg `
            --name $extName `
            --subscription $sub `
            --query "provisioningState" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $existingState -eq "Succeeded") {
            Write-Host "   IoT Operations extension already installed." -ForegroundColor Green
            return
        }
    }

    $autoUpgrade = "true"
    $versionArgs = @()
    $releaseTrainArgs = @("--release-train", "stable")
    if ($extVersion -and $extVersion -ne "latest") {
        $autoUpgrade = "false"
        $versionArgs = @("--version", $extVersion)
        $releaseTrainArgs = @()  # explicit version does not need release train
    }

    $createArgs = @(
        "az", "k8s-extension", "create",
        "--subscription", $sub,
        "--resource-group", $rg,
        "--cluster-name", $clusterName,
        "--cluster-type", "connectedClusters",
        "--name", $extName,
        "--extension-type", "microsoft.iotoperations",
        "--auto-upgrade-minor-version", $autoUpgrade,
        "--configuration-settings",
            "schemaRegistry.namespace=azure-iot-operations",
            "mqttBroker.enabled=true",
            "dataProcessor.enabled=true"
    ) + $releaseTrainArgs + $versionArgs

    Invoke-Step -Description "Deploy IoT Operations extension" -Command $createArgs

    if (-not $DryRun) {
        Write-Host "`n[4/10] Waiting for IoT Operations extension to be ready..." -ForegroundColor Yellow
        $timeout  = 600
        $elapsed  = 0
        $pollSecs = 15

        while ($elapsed -lt $timeout) {
            $state = az k8s-extension show `
                --cluster-name $clusterName `
                --cluster-type connectedClusters `
                --resource-group $rg `
                --name $extName `
                --subscription $sub `
                --query "provisioningState" -o tsv 2>&1

            Write-Host "   State: $state ($elapsed s elapsed)"
            if ($state -eq "Succeeded") {
                Write-Host "   ✅ Extension ready." -ForegroundColor Green
                return
            }
            if ($state -eq "Failed") {
                throw "IoT Operations extension provisioning failed."
            }
            Start-Sleep $pollSecs
            $elapsed += $pollSecs
        }
        throw "Timed out waiting for IoT Operations extension after ${timeout}s."
    }
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Step 6 ΓÇö Create K8s Secrets
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Deploy-Secrets {
    <#
    .SYNOPSIS
        Create Kubernetes Secrets for MQTT credentials and simulator config.
        Secrets are created from env vars ΓÇö never written to disk.
    #>
    Write-Host "`n[5/10] Creating Kubernetes secrets..." -ForegroundColor Yellow

    $mqttHost     = $env:AKS_WORKER_IP    ?? "localhost"
    $mqttPort     = $env:MQTT_BROKER_NODEPORT ?? "31883"
    $mqttUser     = $env:MQTT_USERNAME    ?? "geoint-demo"
    $mqttPassword = $env:MQTT_PASSWORD    ?? ""

    if (-not $DryRun) {
        kubectl create secret generic mqtt-broker-secret `
            --namespace azure-iot-operations `
            --from-literal=MQTT_HOST=$mqttHost `
            --from-literal=MQTT_PORT=$mqttPort `
            --from-literal=MQTT_USERNAME=$mqttUser `
            --from-literal=MQTT_PASSWORD=$mqttPassword `
            --dry-run=client -o yaml | kubectl apply -f -
    } else {
        Write-Host "   [DRY-RUN] Would create secret: mqtt-broker-secret"
    }

    if (-not $DryRun) {
        kubectl create secret generic sensor-simulator-secret `
            --namespace azure-iot-operations `
            --from-literal=MQTT_HOST=$mqttHost `
            --from-literal=MQTT_PORT=$mqttPort `
            --from-literal=MQTT_USERNAME=$mqttUser `
            --from-literal=MQTT_PASSWORD=$mqttPassword `
            --dry-run=client -o yaml | kubectl apply -f -
    } else {
        Write-Host "   [DRY-RUN] Would create secret: sensor-simulator-secret"
    }

    $acrName = $env:ACR_NAME
    if (-not $acrName) {
        throw "ACR_NAME not set in .env file."
    }

    if (-not $DryRun) {
        $acrPassword = az acr credential show --name $acrName --query "passwords[0].value" -o tsv
        kubectl create secret docker-registry acr-credentials `
            --namespace azure-iot-operations `
            --docker-server="$acrName.azurecr.io" `
            --docker-username=$acrName `
            --docker-password=$acrPassword `
            --dry-run=client -o yaml | kubectl apply -f -
    } else {
        Write-Host "   [DRY-RUN] Would create secret: acr-credentials"
    }
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Step 7 ΓÇö Apply IoT Operations manifests
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Deploy-IotManifests {
    <#
    .SYNOPSIS
        Apply MQTT broker, asset definitions, and data pipeline manifests.
    #>
    Write-Host "`n[6/10] Applying IoT Operations manifests..." -ForegroundColor Yellow

    $manifests = @(
        (Join-Path $Demo0Root "iot-operations\mqtt-broker\broker.yaml"),
        (Join-Path $Demo0Root "iot-operations\dataflow-endpoints\default-broker.yaml"),
        (Join-Path $Demo0Root "iot-operations\asset-definitions\asset-endpoint-profile.yaml"),
        (Join-Path $Demo0Root "iot-operations\asset-definitions\weather-station.yaml"),
        (Join-Path $Demo0Root "iot-operations\asset-definitions\seismic-sensor.yaml"),
        (Join-Path $Demo0Root "iot-operations\asset-definitions\rf-detector.yaml"),
        (Join-Path $Demo0Root "iot-operations\data-pipelines\pipeline-sensors.yaml"),
        (Join-Path $Demo0Root "iot-operations\data-pipelines\pipeline-alerts.yaml")
    )

    $mqttNodePort = $env:MQTT_BROKER_NODEPORT ?? "31883"

    foreach ($manifest in $manifests) {
        $content = Get-Content $manifest -Raw
        $content = $content -replace '\$\{MQTT_BROKER_NODEPORT\}', $mqttNodePort

        if (-not $DryRun) {
            $content | kubectl apply -f -
        } else {
            Write-Host "   [DRY-RUN] Would apply: $([System.IO.Path]::GetFileName($manifest))"
        }
    }
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Step 8+9 ΓÇö Build and push Docker images to ACR
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Deploy-ContainerImages {
    <#
    .SYNOPSIS
        Build and push sensor-simulator and alert-processor images to ACR.
    #>
    Write-Host "`n[7/10] Building and pushing container images to ACR..." -ForegroundColor Yellow

    $acrName = $env:ACR_NAME
    if (-not $acrName) { throw "ACR_NAME not set in .env file." }

    if (-not $DryRun) {
        az acr login --name $acrName
    }

    $images = @(
        @{
            Name       = "geoint/sensor-simulator"
            Context    = (Join-Path $Demo0Root "sensor-simulator")
            Dockerfile = (Join-Path $Demo0Root "sensor-simulator\Dockerfile")
        },
        @{
            Name       = "geoint/alert-processor"
            Context    = (Join-Path $Demo0Root "event-triggers\alert-processor")
            Dockerfile = (Join-Path $Demo0Root "event-triggers\alert-processor\Dockerfile")
        }
    )

    foreach ($img in $images) {
        $tag = "$acrName.azurecr.io/$($img.Name):latest"
        Invoke-Step -Description "Build $($img.Name)" -Command @(
            "docker", "build", "-t", $tag, "-f", $img.Dockerfile, $img.Context
        )
        Invoke-Step -Description "Push $($img.Name)" -Command @(
            "docker", "push", $tag
        )
    }
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Step 10 ΓÇö Apply simulator and processor K8s manifests
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Deploy-Workloads {
    <#
    .SYNOPSIS
        Apply the simulator ConfigMap/Deployment and alert-processor manifests.
    #>
    Write-Host "`n[8/10] Deploying workloads..." -ForegroundColor Yellow

    $acrName      = $env:ACR_NAME
    $scenarioFile = $env:SCENARIO_FILE  ?? "scenarios/base_scenario.json"
    $sensorCount  = $env:SENSOR_COUNT   ?? "12"

    # Patch ACR_NAME placeholder in manifests before applying
    $manifests = @(
        (Join-Path $Demo0Root "sensor-simulator\k8s\configmap.yaml"),
        (Join-Path $Demo0Root "sensor-simulator\k8s\deployment.yaml"),
        (Join-Path $Demo0Root "event-triggers\alert-processor\k8s\deployment.yaml")
    )

    foreach ($manifest in $manifests) {
        $content = Get-Content $manifest -Raw
        $content = $content -replace '\$\{ACR_NAME\}', $acrName
        $content = $content -replace 'base_scenario\.json', $scenarioFile

        if (-not $DryRun) {
            $content | kubectl apply -f -
        } else {
            Write-Host "   [DRY-RUN] Would apply: $([System.IO.Path]::GetFileName($manifest))"
        }
    }
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Teardown ΓÇö reverse all steps
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Remove-Deployment {
    <#
    .SYNOPSIS
        Remove all demo0 resources: workloads, IoT Operations manifests,
        extension, and namespace.
    #>
    Write-Host "`nΓÜá  TEARDOWN: removing all demo0-iot-backbone resources..." -ForegroundColor Red

    $sub         = $env:AZURE_SUBSCRIPTION_ID
    $rg          = $env:AZURE_RESOURCE_GROUP
    $clusterName = $env:AKS_CLUSTER_NAME

    $manifests = @(
        (Join-Path $Demo0Root "event-triggers\alert-processor\k8s\deployment.yaml"),
        (Join-Path $Demo0Root "sensor-simulator\k8s\deployment.yaml"),
        (Join-Path $Demo0Root "sensor-simulator\k8s\configmap.yaml"),
        (Join-Path $Demo0Root "iot-operations\data-pipelines\pipeline-alerts.yaml"),
        (Join-Path $Demo0Root "iot-operations\data-pipelines\pipeline-sensors.yaml"),
        (Join-Path $Demo0Root "iot-operations\asset-definitions\rf-detector.yaml"),
        (Join-Path $Demo0Root "iot-operations\asset-definitions\seismic-sensor.yaml"),
        (Join-Path $Demo0Root "iot-operations\asset-definitions\weather-station.yaml"),
        (Join-Path $Demo0Root "iot-operations\mqtt-broker\broker.yaml")
    )

    foreach ($manifest in $manifests) {
        Invoke-Step -Description "Delete $([System.IO.Path]::GetFileName($manifest))" -Command @(
            "kubectl", "delete", "-f", $manifest, "--ignore-not-found"
        )
    }

    Invoke-Step -Description "Remove IoT Operations extension" -Command @(
        "az", "k8s-extension", "delete",
        "--cluster-name", $clusterName,
        "--cluster-type", "connectedClusters",
        "--resource-group", $rg,
        "--name", "azure-iot-operations",
        "--yes"
    )

    Invoke-Step -Description "Delete namespace azure-iot-operations" -Command @(
        "kubectl", "delete", "namespace", "azure-iot-operations", "--ignore-not-found"
    )

    Write-Host "`nΓ£à Teardown complete." -ForegroundColor Green
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Summary
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
function Write-Summary {
    <#
    .SYNOPSIS
        Print a post-deployment summary with URLs and next steps.
    #>
    $workerIp  = $env:AKS_WORKER_IP    ?? "<AKS_WORKER_IP>"
    $mqttPort  = $env:MQTT_BROKER_NODEPORT ?? "31883"
    $grafanaNs = $env:GRAFANA_NAMESPACE ?? "monitoring"

    Write-Host ""
    Write-Host "ΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉ" -ForegroundColor Green
    Write-Host "  Γ£à  GEOINT Demo 0 ΓÇö IoT Backbone Deployed"         -ForegroundColor Green
    Write-Host "ΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉΓòÉ" -ForegroundColor Green
    Write-Host ""
    Write-Host "  MQTT Broker (NodePort):  mqtt://${workerIp}:${mqttPort}"
    Write-Host "  Alert Processor:         kubectl port-forward svc/alert-processor 8080:8080 -n azure-iot-operations"
    Write-Host "  View alerts:             http://localhost:8080/alerts"
    Write-Host ""
    Write-Host "  Grafana Dashboard:"
    Write-Host "    1. kubectl port-forward svc/grafana 3000:3000 -n $grafanaNs"
    Write-Host "    2. Import: demo0-iot-backbone/dashboards/grafana-dashboard.json"
    Write-Host ""
    Write-Host "  To switch environments:  .\deploy-iot-backbone.ps1 -EnvFile .env.prod"
    Write-Host ""
}

# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
# Main entry point
# ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
$envPath = Join-Path $RepoRoot $EnvFile
Import-EnvFile -Path $envPath

if ($Teardown) {
    Remove-Deployment
    exit 0
}

if ($DryRun) {
    Write-Host "`n[DRY-RUN] Commands will be printed but NOT executed.`n" -ForegroundColor Magenta
}

Assert-AzureCli
Deploy-Namespace
Deploy-IotOpsExtension
Deploy-Secrets
Deploy-IotManifests
Deploy-ContainerImages
Deploy-Workloads

if (-not $DryRun) {
    Write-Summary
}

Write-Host "`nΓ£à Deploy complete." -ForegroundColor Green
