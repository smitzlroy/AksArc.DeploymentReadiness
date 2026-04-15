#Requires -Version 5.1
<#
.SYNOPSIS
    AksArc.DeploymentReadiness - Pre-deployment readiness validation for AKS Arc on Azure Local.

.DESCRIPTION
    Validates network connectivity, endpoint reachability, cluster health, ARB status, and RBAC
    before deploying AKS Arc. Includes a consolidated firewall endpoint reference and fleet-scale
    assessment capabilities. Follows the AzStackHci.ManageUpdates module pattern.

    This module is NOT a Microsoft supported service offering or product.
    Refer to the MIT license for further information.
#>

$script:ModuleRoot = $PSScriptRoot
$script:ApiVersion = '2025-10-01'
$script:LogFilePath = $null

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Warning','Error','Success','Header')]
        [string]$Level = 'Info'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
        'Header'  { 'Cyan' }
    }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
    if ($script:LogFilePath) {
        "[$ts] [$Level] $Message" | Out-File -Append -FilePath $script:LogFilePath -Encoding UTF8
    }
}

function Get-EndpointData {
    $jsonPath = Join-Path $script:ModuleRoot (Join-Path 'data' 'endpoints.json')
    if (-not (Test-Path $jsonPath)) {
        throw "Endpoint data file not found: $jsonPath"
    }
    $raw = Get-Content $jsonPath -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Test-TcpPort {
    param([string]$Hostname, [int]$Port, [int]$TimeoutMs = 5000)
    $result = [PSCustomObject]@{
        Hostname  = $Hostname
        Port      = $Port
        Connected = $false
        LatencyMs = -1
        Error     = $null
    }
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync($Hostname, $Port)
        $completed = $task.Wait($TimeoutMs)
        $sw.Stop()
        if ($completed -and $client.Connected) {
            $result.Connected = $true
            $result.LatencyMs = $sw.ElapsedMilliseconds
        } else {
            $result.Error = 'Connection timed out'
        }
        $client.Close()
    } catch {
        $result.Error = $_.Exception.InnerException.Message
        if (-not $result.Error) { $result.Error = $_.Exception.Message }
    }
    return $result
}

function Test-DnsName {
    param([string]$Hostname)
    $result = [PSCustomObject]@{
        Hostname = $Hostname
        Resolved = $false
        Addresses = @()
        Error    = $null
    }
    try {
        # Strip wildcard prefix for DNS resolution
        $testHost = $Hostname -replace '^\*\.', ''
        $dns = Resolve-DnsName -Name $testHost -Type A -DnsOnly -ErrorAction Stop
        $result.Resolved = $true
        $result.Addresses = @($dns | Where-Object { $_.QueryType -eq 'A' } | ForEach-Object { $_.IPAddress })
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Invoke-AzRestCall {
    param([string]$Uri, [string]$Method = 'GET')
    $fullUri = "https://management.azure.com${Uri}?api-version=$script:ApiVersion"
    $raw = az rest --method $Method --uri $fullUri 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        return $null
    }
    return ($raw | ConvertFrom-Json)
}

function New-ValidationResult {
    param(
        [string]$Gate,
        [string]$Check,
        [ValidateSet('Passed','Failed','Warning','Skipped')]
        [string]$Status,
        [string]$Message,
        [string]$Detail = '',
        [string]$Remediation = ''
    )
    return [PSCustomObject]@{
        Gate         = $Gate
        Check        = $Check
        Status       = $Status
        Message      = $Message
        Detail       = $Detail
        Remediation  = $Remediation
        Timestamp    = (Get-Date -Format 'o')
    }
}

function Export-Results {
    param(
        [object[]]$Results,
        [string]$Path
    )
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    switch ($ext) {
        '.csv' {
            $Results | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
        }
        '.json' {
            $Results | ConvertTo-Json -Depth 10 | Out-File -FilePath $Path -Encoding UTF8
        }
        '.xml' {
            # JUnit XML format for CI/CD
            $xml = '<?xml version="1.0" encoding="UTF-8"?>' + "`n"
            $total = $Results.Count
            $failures = @($Results | Where-Object { $_.Status -eq 'Failed' }).Count
            $warnings = @($Results | Where-Object { $_.Status -eq 'Warning' }).Count
            $xml += "<testsuites tests=`"$total`" failures=`"$failures`" errors=`"0`">`n"
            $xml += "  <testsuite name=`"AksArc.DeploymentReadiness`" tests=`"$total`" failures=`"$failures`" errors=`"0`">`n"
            foreach ($r in $Results) {
                $name = "$($r.Gate) - $($r.Check)" -replace '"', '&quot;'
                $xml += "    <testcase name=`"$name`" classname=`"$($r.Gate)`">`n"
                if ($r.Status -eq 'Failed') {
                    $msg = ($r.Message -replace '"', '&quot;') -replace '&', '&amp;'
                    $xml += "      <failure message=`"$msg`">$($r.Detail)`n$($r.Remediation)</failure>`n"
                } elseif ($r.Status -eq 'Warning') {
                    $msg = ($r.Message -replace '"', '&quot;') -replace '&', '&amp;'
                    $xml += "      <system-out>WARNING: $msg</system-out>`n"
                }
                $xml += "    </testcase>`n"
            }
            $xml += "  </testsuite>`n</testsuites>"
            $xml | Out-File -FilePath $Path -Encoding UTF8
        }
        default {
            throw "Unsupported export format: $ext. Use .csv, .json, or .xml"
        }
    }
    Write-Log "Results exported to: $Path" -Level Success
}

# =============================================================================
# TIER 1: SINGLE-SITE READINESS (on-node)
# =============================================================================

function Initialize-AksArcValidation {
    <#
    .SYNOPSIS
        Auto-discovers the Azure Local environment and stages required tools.

    .DESCRIPTION
        Checks for Azure CLI and required extensions, discovers the Azure Local cluster,
        ARB, custom location, and logical networks in the current subscription.
        Returns a context object used by other functions.

    .PARAMETER SubscriptionId
        Azure subscription ID. If not specified, uses the current az CLI context.

    .PARAMETER ResourceGroupName
        Resource group containing the Azure Local cluster. Auto-discovered if not specified.

    .PARAMETER ClusterName
        Azure Local cluster name. Auto-discovered if there is exactly one in the resource group.

    .EXAMPLE
        $ctx = Initialize-AksArcValidation
        Test-AksArcDeploymentReadiness -Context $ctx
    #>
    [CmdletBinding()]
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$ClusterName
    )

    Write-Log '========================================' -Level Header
    Write-Log 'AKS Arc Deployment Readiness - Initialize' -Level Header
    Write-Log '========================================' -Level Header

    # Check Azure CLI
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is not installed or not in PATH. Install from https://aka.ms/installazurecli'
    }

    # Check login
    $accountRaw = az account show -o json 2>$null
    if (-not $accountRaw) {
        Write-Log 'Not logged in. Starting device-code login...' -Level Warning
        az login --use-device-code 2>$null
        $accountRaw = az account show -o json 2>$null
        if (-not $accountRaw) {
            throw 'Azure CLI login failed. Run "az login --use-device-code" manually.'
        }
    }
    $account = $accountRaw | ConvertFrom-Json

    if ($SubscriptionId) {
        az account set -s $SubscriptionId 2>$null
        $accountRaw = az account show -o json 2>$null
        $account = $accountRaw | ConvertFrom-Json
    }
    Write-Log "Subscription: $($account.name) ($($account.id))" -Level Info

    # Ensure required extensions
    foreach ($ext in @('stack-hci-vm', 'connectedk8s')) {
        $extCheck = az extension show --name $ext 2>$null
        if (-not $extCheck) {
            Write-Log "Installing az extension: $ext" -Level Info
            az extension add --name $ext --yes 2>$null
        }
    }

    # Discover cluster
    $clusters = @()
    if ($ResourceGroupName) {
        $raw = az stack-hci cluster list -g $ResourceGroupName -o json 2>$null
        if ($raw) { $clusters = $raw | ConvertFrom-Json }
    } else {
        $raw = az stack-hci cluster list -o json 2>$null
        if ($raw) { $clusters = $raw | ConvertFrom-Json }
    }

    $cluster = $null
    if ($ClusterName) {
        $cluster = $clusters | Where-Object { $_.name -eq $ClusterName } | Select-Object -First 1
    } elseif ($clusters.Count -eq 1) {
        $cluster = $clusters[0]
    } elseif ($clusters.Count -gt 1) {
        Write-Log "Found $($clusters.Count) clusters. Specify -ClusterName." -Level Warning
        $clusters | ForEach-Object { Write-Log "  $($_.name) (RG: $($_.resourceGroup))" -Level Info }
        throw "Multiple clusters found. Use -ClusterName to select one."
    } else {
        throw "No Azure Local clusters found in subscription $($account.id)."
    }

    $rg = $cluster.resourceGroup
    $region = $cluster.location
    Write-Log "Cluster: $($cluster.name) (RG: $rg, Region: $region)" -Level Success

    # Discover ARB
    $arbRaw = az arcappliance list -g $rg -o json 2>$null
    $arbs = if ($arbRaw) { $arbRaw | ConvertFrom-Json } else { @() }
    $arb = $arbs | Select-Object -First 1

    if ($arb) {
        Write-Log "ARB: $($arb.name) (status: $($arb.status))" -Level Success
    } else {
        Write-Log 'No Arc Resource Bridge found.' -Level Warning
    }

    # Discover Custom Location
    $clRaw = az customlocation list -g $rg -o json 2>$null
    $customLocations = if ($clRaw) { $clRaw | ConvertFrom-Json } else { @() }
    $customLoc = $customLocations | Select-Object -First 1

    if ($customLoc) {
        Write-Log "Custom Location: $($customLoc.name)" -Level Success
    } else {
        Write-Log 'No Custom Location found.' -Level Warning
    }

    # Discover logical networks
    $lnetRaw = az stack-hci-vm network lnet list -g $rg -o json 2>$null
    $lnets = if ($lnetRaw) { $lnetRaw | ConvertFrom-Json } else { @() }
    Write-Log "Logical Networks: $($lnets.Count) found" -Level Info

    # Build context
    $ctx = [PSCustomObject]@{
        SubscriptionId   = $account.id
        SubscriptionName = $account.name
        ResourceGroup    = $rg
        Region           = $region
        ClusterName      = $cluster.name
        ClusterId        = $cluster.id
        ArbName          = if ($arb) { $arb.name } else { $null }
        ArbId            = if ($arb) { $arb.id } else { $null }
        ArbStatus        = if ($arb) { $arb.status } else { $null }
        CustomLocation   = if ($customLoc) { $customLoc.name } else { $null }
        CustomLocationId = if ($customLoc) { $customLoc.id } else { $null }
        LogicalNetworks  = $lnets
        Timestamp        = (Get-Date -Format 'o')
    }

    Write-Log 'Initialization complete.' -Level Success
    return $ctx
}

function Test-AksArcNetworkConnectivity {
    <#
    .SYNOPSIS
        Tests network connectivity to all required AKS Arc endpoints from the current node.

    .DESCRIPTION
        Tests TCP/HTTPS reachability and DNS resolution for all endpoints in the embedded
        endpoint reference. Returns structured results per endpoint with latency and status.

    .PARAMETER Component
        Filter by component: 'AKS Arc infra', 'ARB infra', 'Arc agent', 'Authentication', 'ARM', 'Monitoring', etc.

    .PARAMETER ArcGatewaySupported
        Filter to only endpoints covered by Arc Gateway ($true) or requiring direct firewall rules ($false).

    .PARAMETER Region
        Azure region to resolve region-specific endpoint URLs (e.g., 'eastus').

    .PARAMETER TimeoutMs
        TCP connection timeout in milliseconds (default: 5000).

    .PARAMETER PassThru
        Return result objects to the pipeline.

    .PARAMETER ExportPath
        Export results to CSV, JSON, or JUnit XML file.

    .EXAMPLE
        Test-AksArcNetworkConnectivity -Region eastus

    .EXAMPLE
        Test-AksArcNetworkConnectivity -Component 'AKS Arc infra' -ExportPath results.xml
    #>
    [CmdletBinding()]
    param(
        [string]$Component,
        [Nullable[bool]]$ArcGatewaySupported,
        [string]$Region,
        [int]$TimeoutMs = 5000,
        [switch]$PassThru,
        [string]$ExportPath
    )

    Write-Log '========================================' -Level Header
    Write-Log 'AKS Arc Network Connectivity Test' -Level Header
    Write-Log '========================================' -Level Header

    $data = Get-EndpointData
    $endpoints = $data.endpoints

    # Apply filters
    if ($Component) {
        $endpoints = @($endpoints | Where-Object { $_.component -eq $Component })
    }
    if ($null -ne $ArcGatewaySupported) {
        $endpoints = @($endpoints | Where-Object { $_.arcGatewaySupported -eq $ArcGatewaySupported })
    }

    Write-Log "Testing $($endpoints.Count) endpoint(s)..." -Level Info
    if ($Region) { Write-Log "Region: $Region" -Level Info }

    $results = @()
    $passed = 0
    $failed = 0

    foreach ($ep in $endpoints) {
        $url = $ep.url
        # Resolve region-specific URLs
        if ($Region -and $ep.regionSpecific -and $url -match '^\*\.') {
            $url = $url -replace '^\*', $Region
        }

        $testHost = $url -replace '^\*\.', ''
        $method = $ep.validation.method

        $status = 'Failed'
        $detail = ''
        $latency = -1

        switch ($method) {
            'tcp_connect' {
                $tcp = Test-TcpPort -Hostname $testHost -Port $ep.port -TimeoutMs $TimeoutMs
                if ($tcp.Connected) {
                    $status = 'Passed'
                    $latency = $tcp.LatencyMs
                    $detail = "${latency}ms"
                } else {
                    $detail = $tcp.Error
                }
            }
            'https_get' {
                $tcp = Test-TcpPort -Hostname $testHost -Port $ep.port -TimeoutMs $TimeoutMs
                if ($tcp.Connected) {
                    $status = 'Passed'
                    $latency = $tcp.LatencyMs
                    $detail = "${latency}ms"
                } else {
                    $detail = $tcp.Error
                }
            }
            'dns_resolve' {
                $dns = Test-DnsName -Hostname $testHost
                if ($dns.Resolved) {
                    $status = 'Passed'
                    $detail = ($dns.Addresses -join ', ')
                } else {
                    $detail = $dns.Error
                }
            }
            'manual' {
                $status = 'Skipped'
                $detail = 'Manual validation required'
            }
        }

        $icon = switch ($status) {
            'Passed'  { '[PASS]' }
            'Failed'  { '[FAIL]' }
            'Skipped' { '[SKIP]' }
        }
        $iconColor = switch ($status) {
            'Passed'  { 'Green' }
            'Failed'  { 'Red' }
            'Skipped' { 'DarkGray' }
        }
        Write-Host "  $icon " -ForegroundColor $iconColor -NoNewline
        Write-Host "$($ep.url):$($ep.port)" -NoNewline
        Write-Host " ($($ep.component)) " -ForegroundColor DarkGray -NoNewline
        Write-Host $detail -ForegroundColor DarkGray

        if ($status -eq 'Passed') { $passed++ } elseif ($status -eq 'Failed') { $failed++ }

        $results += [PSCustomObject]@{
            Id               = $ep.id
            Url              = $ep.url
            Port             = $ep.port
            Component        = $ep.component
            Status           = $status
            LatencyMs        = $latency
            Detail           = $detail
            ArcGateway       = $ep.arcGatewaySupported
            RequiredFor      = $ep.requiredFor
            ValidationMethod = $method
        }
    }

    # Summary
    Write-Host ''
    Write-Log "Results: $passed passed, $failed failed, $($results.Count - $passed - $failed) skipped" -Level $(if ($failed -gt 0) { 'Error' } else { 'Success' })

    if ($ExportPath) {
        Export-Results -Results $results -Path $ExportPath
    }

    if ($PassThru) { return $results }
}

function Test-AksArcDeploymentReadiness {
    <#
    .SYNOPSIS
        Runs all pre-deployment readiness gates for AKS Arc on a single Azure Local cluster.

    .DESCRIPTION
        Validates cluster health, ARB status, custom location, network connectivity,
        logical networks, and RBAC. Returns structured pass/fail results per gate.

    .PARAMETER Context
        Context object from Initialize-AksArcValidation. If not provided, runs Initialize-AksArcValidation.

    .PARAMETER Region
        Azure region for endpoint testing. Auto-detected from context if available.

    .PARAMETER SkipNetworkTests
        Skip the network connectivity gate (useful for remote assessment).

    .PARAMETER PassThru
        Return result objects to the pipeline.

    .PARAMETER ExportPath
        Export results to CSV, JSON, or JUnit XML file.

    .EXAMPLE
        Test-AksArcDeploymentReadiness

    .EXAMPLE
        $ctx = Initialize-AksArcValidation -ClusterName 'mycluster'
        Test-AksArcDeploymentReadiness -Context $ctx -ExportPath results.xml
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [PSCustomObject]$Context,
        [string]$Region,
        [switch]$SkipNetworkTests,
        [switch]$PassThru,
        [string]$ExportPath
    )

    Write-Log '========================================' -Level Header
    Write-Log 'AKS Arc Deployment Readiness Assessment' -Level Header
    Write-Log '========================================' -Level Header

    if (-not $Context) {
        $Context = Initialize-AksArcValidation
    }
    if (-not $Region) { $Region = $Context.Region }

    $results = @()

    if ($PSCmdlet.ShouldProcess($Context.ClusterName, 'Run deployment readiness gates')) {

        # Gate 1: Azure Local Cluster Health
        Write-Log '' -Level Info
        Write-Log 'Gate 1: Azure Local Cluster Health' -Level Header
        $clusterInfo = Invoke-AzRestCall -Uri "/subscriptions/$($Context.SubscriptionId)/resourceGroups/$($Context.ResourceGroup)/providers/Microsoft.AzureStackHCI/clusters/$($Context.ClusterName)"

        if ($clusterInfo) {
            $connStatus = $clusterInfo.properties.connectivityStatus
            $provState = $clusterInfo.properties.provisioningState
            $lastSync = $clusterInfo.properties.lastSyncTimestamp

            if ($connStatus -eq 'Connected' -and $provState -eq 'Succeeded') {
                $results += New-ValidationResult -Gate 'ClusterHealth' -Check 'ConnectivityStatus' -Status 'Passed' -Message "Connected (provisioning: $provState)"
                Write-Log "  Connectivity: $connStatus, Provisioning: $provState" -Level Success
            } else {
                $results += New-ValidationResult -Gate 'ClusterHealth' -Check 'ConnectivityStatus' -Status 'Failed' `
                    -Message "Connectivity: $connStatus, Provisioning: $provState" `
                    -Remediation 'Ensure the cluster has internet connectivity and is registered with Azure.'
                Write-Log "  Connectivity: $connStatus, Provisioning: $provState" -Level Error
            }

            if ($lastSync) {
                $syncAge = (Get-Date) - [DateTime]$lastSync
                if ($syncAge.TotalHours -lt 24) {
                    $results += New-ValidationResult -Gate 'ClusterHealth' -Check 'LastSync' -Status 'Passed' -Message "Last sync: $([math]::Round($syncAge.TotalHours, 1)) hours ago"
                } else {
                    $results += New-ValidationResult -Gate 'ClusterHealth' -Check 'LastSync' -Status 'Warning' `
                        -Message "Last sync: $([math]::Round($syncAge.TotalDays, 1)) days ago" `
                        -Remediation 'Cluster has not synced recently. Check network connectivity.'
                }
            }
        } else {
            $results += New-ValidationResult -Gate 'ClusterHealth' -Check 'ClusterReachable' -Status 'Failed' `
                -Message 'Cannot query cluster via ARM API' `
                -Remediation 'Verify az CLI login and subscription context.'
        }

        # Gate 2: ARB Health
        Write-Log '' -Level Info
        Write-Log 'Gate 2: Arc Resource Bridge Health' -Level Header
        if ($Context.ArbId) {
            $arbInfo = Invoke-AzRestCall -Uri $Context.ArbId
            if ($arbInfo) {
                $arbStatus = $arbInfo.properties.status
                $arbProv = $arbInfo.properties.provisioningState

                if ($arbStatus -eq 'Running' -and $arbProv -eq 'Succeeded') {
                    $results += New-ValidationResult -Gate 'ARBHealth' -Check 'ARBStatus' -Status 'Passed' -Message "Running (provisioning: $arbProv)"
                    Write-Log "  ARB: $arbStatus, Provisioning: $arbProv" -Level Success
                } else {
                    $results += New-ValidationResult -Gate 'ARBHealth' -Check 'ARBStatus' -Status 'Failed' `
                        -Message "Status: $arbStatus, Provisioning: $arbProv" `
                        -Remediation 'ARB must be Running. See: https://learn.microsoft.com/azure/azure-local/manage/azure-arc-vm-management-troubleshooting'
                    Write-Log "  ARB: $arbStatus, Provisioning: $arbProv" -Level Error
                }
            } else {
                $results += New-ValidationResult -Gate 'ARBHealth' -Check 'ARBReachable' -Status 'Failed' -Message 'Cannot query ARB via ARM API'
            }
        } else {
            $results += New-ValidationResult -Gate 'ARBHealth' -Check 'ARBExists' -Status 'Failed' `
                -Message 'No Arc Resource Bridge found in resource group' `
                -Remediation 'Deploy ARB before AKS Arc.'
            Write-Log '  No ARB found.' -Level Error
        }

        # Gate 3: Custom Location
        Write-Log '' -Level Info
        Write-Log 'Gate 3: Custom Location' -Level Header
        if ($Context.CustomLocationId) {
            $clInfo = Invoke-AzRestCall -Uri $Context.CustomLocationId
            if ($clInfo -and $clInfo.properties.provisioningState -eq 'Succeeded') {
                $results += New-ValidationResult -Gate 'CustomLocation' -Check 'Provisioned' -Status 'Passed' -Message "Custom Location '$($Context.CustomLocation)' is provisioned"
                Write-Log "  Custom Location: $($Context.CustomLocation) - Provisioned" -Level Success
            } else {
                $prov = if ($clInfo) { $clInfo.properties.provisioningState } else { 'Unknown' }
                $results += New-ValidationResult -Gate 'CustomLocation' -Check 'Provisioned' -Status 'Failed' `
                    -Message "Provisioning state: $prov" `
                    -Remediation 'Custom Location must be in Succeeded state.'
            }
        } else {
            $results += New-ValidationResult -Gate 'CustomLocation' -Check 'Exists' -Status 'Failed' `
                -Message 'No Custom Location found' `
                -Remediation 'Create a Custom Location referencing the ARB.'
            Write-Log '  No Custom Location found.' -Level Error
        }

        # Gate 4: Network Connectivity
        Write-Log '' -Level Info
        Write-Log 'Gate 4: Network Connectivity' -Level Header
        if ($SkipNetworkTests) {
            $results += New-ValidationResult -Gate 'NetworkConnectivity' -Check 'EndpointReachability' -Status 'Skipped' -Message 'Network tests skipped via -SkipNetworkTests'
            Write-Log '  Skipped (use -SkipNetworkTests:$false to enable)' -Level Warning
        } else {
            $netResults = Test-AksArcNetworkConnectivity -Region $Region -PassThru
            $netFailed = @($netResults | Where-Object { $_.Status -eq 'Failed' })
            if ($netFailed.Count -eq 0) {
                $results += New-ValidationResult -Gate 'NetworkConnectivity' -Check 'EndpointReachability' -Status 'Passed' `
                    -Message "All $($netResults.Count) endpoints reachable"
            } else {
                $failedUrls = ($netFailed | Select-Object -First 5 | ForEach-Object { "$($_.Url):$($_.Port)" }) -join ', '
                $results += New-ValidationResult -Gate 'NetworkConnectivity' -Check 'EndpointReachability' -Status 'Failed' `
                    -Message "$($netFailed.Count) of $($netResults.Count) endpoints unreachable" `
                    -Detail "Failed: $failedUrls$(if ($netFailed.Count -gt 5) { '...' })" `
                    -Remediation 'Open firewall rules for failed endpoints. Run Get-AksArcEndpointReference for full list.'
            }
        }

        # Gate 5: Logical Networks
        Write-Log '' -Level Info
        Write-Log 'Gate 5: Logical Networks' -Level Header
        if ($Context.LogicalNetworks -and $Context.LogicalNetworks.Count -gt 0) {
            $results += New-ValidationResult -Gate 'LogicalNetworks' -Check 'LNETsExist' -Status 'Passed' `
                -Message "$($Context.LogicalNetworks.Count) logical network(s) found"
            Write-Log "  $($Context.LogicalNetworks.Count) logical network(s) found" -Level Success

            foreach ($lnet in $Context.LogicalNetworks) {
                $lnetDetail = az stack-hci-vm network lnet show -g $Context.ResourceGroup -n $lnet.name -o json 2>$null
                if ($lnetDetail) {
                    $lnetObj = $lnetDetail | ConvertFrom-Json
                    $provState = $lnetObj.properties.provisioningState
                    if ($provState -eq 'Succeeded') {
                        $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)" -Status 'Passed' -Message "Provisioned"
                    } else {
                        $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)" -Status 'Warning' -Message "Provisioning: $provState"
                    }
                }
            }
        } else {
            $results += New-ValidationResult -Gate 'LogicalNetworks' -Check 'LNETsExist' -Status 'Failed' `
                -Message 'No logical networks found' `
                -Remediation 'Create at least one logical network for AKS Arc VMs.'
            Write-Log '  No logical networks found.' -Level Error
        }

        # Gate 6: Cross-Subnet Ports (informational)
        Write-Log '' -Level Info
        Write-Log 'Gate 6: Cross-Subnet Ports (informational)' -Level Header
        $data = Get-EndpointData
        $portCount = $data.crossSubnetPorts.Count
        $results += New-ValidationResult -Gate 'CrossSubnetPorts' -Check 'PortReference' -Status 'Passed' `
            -Message "$portCount cross-subnet ports required (22, 443, 6443, 9440, 40343, 55000, 65000)" `
            -Detail 'Cross-subnet port testing requires access to both subnets. Use Test-AksArcNetworkConnectivity from each subnet.'
        Write-Log "  $portCount cross-subnet ports documented. Verify from both subnets." -Level Info
    }

    # Summary
    Write-Host ''
    Write-Log '========================================' -Level Header
    Write-Log 'Assessment Summary' -Level Header
    Write-Log '========================================' -Level Header

    $totalPassed = @($results | Where-Object { $_.Status -eq 'Passed' }).Count
    $totalFailed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
    $totalWarning = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $totalSkipped = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count

    Write-Log "Cluster: $($Context.ClusterName)" -Level Info
    Write-Log "Passed:  $totalPassed" -Level Success
    Write-Log "Failed:  $totalFailed" -Level $(if ($totalFailed -gt 0) { 'Error' } else { 'Info' })
    Write-Log "Warning: $totalWarning" -Level $(if ($totalWarning -gt 0) { 'Warning' } else { 'Info' })
    Write-Log "Skipped: $totalSkipped" -Level Info

    if ($totalFailed -eq 0) {
        Write-Host ''
        Write-Log 'READINESS CHECK PASSED - Cluster appears ready for AKS Arc deployment' -Level Success
    } else {
        Write-Host ''
        Write-Log 'READINESS CHECK FAILED - Resolve failed checks before deploying AKS Arc' -Level Error
        Write-Host ''
        $results | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object {
            Write-Log "  FAILED: $($_.Gate) / $($_.Check): $($_.Message)" -Level Error
            if ($_.Remediation) {
                Write-Log "          Remediation: $($_.Remediation)" -Level Warning
            }
        }
    }

    if ($ExportPath) {
        Export-Results -Results $results -Path $ExportPath
    }

    if ($PassThru) { return $results }
}

# =============================================================================
# TIER 2: ENDPOINT REFERENCE
# =============================================================================

function Get-AksArcEndpointReference {
    <#
    .SYNOPSIS
        Returns the consolidated AKS Arc + Azure Local endpoint reference as objects.

    .DESCRIPTION
        Reads the embedded endpoint data and returns it as filterable PowerShell objects.
        This is THE consolidated place for all firewall requirements.

    .PARAMETER Component
        Filter by component name.

    .PARAMETER ArcGatewaySupported
        Filter by Arc Gateway support ($true or $false).

    .PARAMETER RequiredFor
        Filter by phase: 'deployment', 'post-deployment', or 'both'.

    .PARAMETER Region
        Resolve region-specific wildcard URLs to a specific region.

    .PARAMETER IncludeCrossSubnetPorts
        Include cross-subnet port requirements in output.

    .PARAMETER CheckForUpdates
        Compare embedded data age against the upstream source and warn if stale.

    .EXAMPLE
        Get-AksArcEndpointReference | Format-Table

    .EXAMPLE
        Get-AksArcEndpointReference -Component 'AKS Arc infra' -ArcGatewaySupported $false
    #>
    [CmdletBinding()]
    param(
        [string]$Component,
        [Nullable[bool]]$ArcGatewaySupported,
        [ValidateSet('deployment','post-deployment','both')]
        [string]$RequiredFor,
        [string]$Region,
        [switch]$IncludeCrossSubnetPorts,
        [switch]$CheckForUpdates
    )

    $data = Get-EndpointData
    $endpoints = $data.endpoints

    if ($Component) {
        $endpoints = @($endpoints | Where-Object { $_.component -eq $Component })
    }
    if ($null -ne $ArcGatewaySupported) {
        $endpoints = @($endpoints | Where-Object { $_.arcGatewaySupported -eq $ArcGatewaySupported })
    }
    if ($RequiredFor) {
        $endpoints = @($endpoints | Where-Object { $_.requiredFor -eq $RequiredFor -or $_.requiredFor -eq 'both' })
    }

    # Resolve region URLs
    if ($Region) {
        $endpoints = $endpoints | ForEach-Object {
            $ep = $_
            if ($ep.regionSpecific -and $ep.url -match '^\*\.') {
                $resolved = $ep.url -replace '^\*', $Region
                $ep | Add-Member -NotePropertyName 'resolvedUrl' -NotePropertyValue $resolved -PassThru
            } else {
                $ep | Add-Member -NotePropertyName 'resolvedUrl' -NotePropertyValue $ep.url -PassThru
            }
        }
    }

    if ($CheckForUpdates) {
        $lastUpdated = $data.metadata.lastUpdated
        if ($lastUpdated) {
            $age = (Get-Date) - [DateTime]$lastUpdated
            if ($age.TotalDays -gt 90) {
                Write-Log "Endpoint data is $([math]::Round($age.TotalDays)) days old (last updated: $lastUpdated). Consider updating the module." -Level Warning
            } else {
                Write-Log "Endpoint data last updated: $lastUpdated ($([math]::Round($age.TotalDays)) days ago)" -Level Info
            }
        }
    }

    $output = @($endpoints)

    if ($IncludeCrossSubnetPorts -and $data.crossSubnetPorts) {
        Write-Host ''
        Write-Log 'Cross-Subnet Ports (AKS subnet <-> Management subnet):' -Level Header
        foreach ($p in $data.crossSubnetPorts) {
            Write-Host "  $($p.port)/$($p.protocol) ($($p.direction)) - $($p.purpose)" -ForegroundColor White
        }
    }

    return $output
}

function Export-AksArcFirewallRules {
    <#
    .SYNOPSIS
        Exports the endpoint reference as a formatted firewall request document.

    .DESCRIPTION
        Generates a CSV, JSON, or Markdown file suitable for handing to a network security
        team as a firewall change request.

    .PARAMETER Path
        Output file path. Format detected from extension (.csv, .json, .md).

    .PARAMETER Region
        Azure region to resolve wildcard URLs.

    .PARAMETER RequiredFor
        Filter by phase: 'deployment', 'post-deployment', or 'both'.

    .PARAMETER IncludeCrossSubnetPorts
        Include cross-subnet port table in the export.

    .EXAMPLE
        Export-AksArcFirewallRules -Path firewall-request.csv -Region eastus

    .EXAMPLE
        Export-AksArcFirewallRules -Path firewall-request.md -Region westeurope
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Region,
        [ValidateSet('deployment','post-deployment','both')]
        [string]$RequiredFor,
        [switch]$IncludeCrossSubnetPorts
    )

    $params = @{}
    if ($Region) { $params['Region'] = $Region }
    if ($RequiredFor) { $params['RequiredFor'] = $RequiredFor }

    $endpoints = Get-AksArcEndpointReference @params

    $ext = [System.IO.Path]::GetExtension($Path).ToLower()

    switch ($ext) {
        '.csv' {
            $rows = $endpoints | Select-Object id, url, port, protocol, component, notes, arcGatewaySupported, requiredFor, networkOrigin
            $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
            Write-Log "Firewall rules exported to CSV: $Path ($($rows.Count) rules)" -Level Success
        }
        '.json' {
            $data = Get-EndpointData
            $export = [PSCustomObject]@{
                generatedAt = (Get-Date -Format 'o')
                region      = $Region
                moduleVersion = (Get-Module AksArc.DeploymentReadiness -ErrorAction SilentlyContinue).Version.ToString()
                endpointCount = $endpoints.Count
                endpoints   = $endpoints
            }
            if ($IncludeCrossSubnetPorts) {
                $export | Add-Member -NotePropertyName 'crossSubnetPorts' -NotePropertyValue $data.crossSubnetPorts
            }
            $export | ConvertTo-Json -Depth 10 | Out-File -FilePath $Path -Encoding UTF8
            Write-Log "Firewall rules exported to JSON: $Path ($($endpoints.Count) rules)" -Level Success
        }
        '.md' {
            $md = "# AKS Arc Firewall Requirements`n`n"
            $md += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
            if ($Region) { $md += "Region: $Region`n" }
            $md += "Total Endpoints: $($endpoints.Count)`n`n"
            $md += "| # | URL | Port | Protocol | Component | Arc Gateway | Required For | Notes |`n"
            $md += "|---|-----|------|----------|-----------|-------------|--------------|-------|`n"
            foreach ($ep in $endpoints) {
                $agw = if ($ep.arcGatewaySupported) { 'Yes' } else { 'No' }
                $md += "| $($ep.id) | ``$($ep.url)`` | $($ep.port) | $($ep.protocol) | $($ep.component) | $agw | $($ep.requiredFor) | $($ep.notes) |`n"
            }

            if ($IncludeCrossSubnetPorts) {
                $data = Get-EndpointData
                $md += "`n## Cross-Subnet Ports`n`n"
                $md += "| Port | Protocol | Direction | Purpose |`n"
                $md += "|------|----------|-----------|---------|`n"
                foreach ($p in $data.crossSubnetPorts) {
                    $md += "| $($p.port) | $($p.protocol) | $($p.direction) | $($p.purpose) |`n"
                }
            }

            $md | Out-File -FilePath $Path -Encoding UTF8
            Write-Log "Firewall rules exported to Markdown: $Path ($($endpoints.Count) rules)" -Level Success
        }
        default {
            throw "Unsupported format: $ext. Use .csv, .json, or .md"
        }
    }
}

# =============================================================================
# TIER 3: FLEET SCALE (remote via ARM APIs)
# =============================================================================

function Connect-AksArcServicePrincipal {
    <#
    .SYNOPSIS
        Authenticates to Azure using a Service Principal or Managed Identity.

    .DESCRIPTION
        Supports the same authentication patterns as AzStackHci.ManageUpdates:
        Managed Identity, Service Principal with env vars, or explicit parameters.

    .PARAMETER UseManagedIdentity
        Use Managed Identity authentication.

    .PARAMETER ManagedIdentityClientId
        Client ID for user-assigned managed identity.

    .PARAMETER ServicePrincipalId
        Application (client) ID. Can also use AZURE_CLIENT_ID env var.

    .PARAMETER ServicePrincipalSecret
        Client secret. Can also use AZURE_CLIENT_SECRET env var.

    .PARAMETER TenantId
        Tenant ID. Can also use AZURE_TENANT_ID env var.

    .EXAMPLE
        Connect-AksArcServicePrincipal -UseManagedIdentity

    .EXAMPLE
        $env:AZURE_CLIENT_ID = 'your-app-id'
        $env:AZURE_CLIENT_SECRET = 'your-secret'
        $env:AZURE_TENANT_ID = 'your-tenant-id'
        Connect-AksArcServicePrincipal
    #>
    [CmdletBinding()]
    param(
        [switch]$UseManagedIdentity,
        [string]$ManagedIdentityClientId,
        [string]$ServicePrincipalId,
        [string]$ServicePrincipalSecret,
        [string]$TenantId
    )

    if ($UseManagedIdentity) {
        Write-Log 'Authenticating with Managed Identity...' -Level Info
        if ($ManagedIdentityClientId) {
            az login --identity --username $ManagedIdentityClientId 2>$null
        } else {
            az login --identity 2>$null
        }
    } else {
        $clientId = if ($ServicePrincipalId) { $ServicePrincipalId } else { $env:AZURE_CLIENT_ID }
        $clientSecret = if ($ServicePrincipalSecret) { $ServicePrincipalSecret } else { $env:AZURE_CLIENT_SECRET }
        $tenant = if ($TenantId) { $TenantId } else { $env:AZURE_TENANT_ID }

        if (-not $clientId -or -not $clientSecret -or -not $tenant) {
            throw 'Service Principal credentials not found. Set AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, and AZURE_TENANT_ID environment variables.'
        }

        Write-Log 'Authenticating with Service Principal...' -Level Info
        az login --service-principal -u $clientId -p $clientSecret --tenant $tenant 2>$null
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Log 'Authentication failed.' -Level Error
        return $false
    }

    $acct = az account show -o json 2>$null | ConvertFrom-Json
    Write-Log "Authenticated: $($acct.user.name) (Subscription: $($acct.name))" -Level Success
    return $true
}

function Test-AksArcFleetReadiness {
    <#
    .SYNOPSIS
        Batch readiness assessment across multiple Azure Local clusters.

    .DESCRIPTION
        Uses Azure Resource Graph to discover clusters and checks: cluster connectivity,
        ARB health, custom location, and AKS Arc cluster state. Supports tag-based scoping,
        batch processing, and result export.

    .PARAMETER ClusterNames
        Array of cluster names.

    .PARAMETER ClusterResourceIds
        Array of full Azure Resource IDs.

    .PARAMETER ScopeByTag
        Switch to scope by tag name/value.

    .PARAMETER TagName
        Tag name to filter by (default: 'ReadinessRing').

    .PARAMETER TagValue
        Tag value to match.

    .PARAMETER SubscriptionId
        Limit to a specific subscription.

    .PARAMETER BatchSize
        Clusters per batch for ARG queries (default: 50).

    .PARAMETER PassThru
        Return result objects.

    .PARAMETER ExportPath
        Export to CSV, JSON, or JUnit XML.

    .EXAMPLE
        Test-AksArcFleetReadiness -ClusterNames @('cluster01', 'cluster02')

    .EXAMPLE
        Test-AksArcFleetReadiness -ScopeByTag -TagName 'Environment' -TagValue 'Production'
    #>
    [CmdletBinding()]
    param(
        [string[]]$ClusterNames,
        [string[]]$ClusterResourceIds,
        [switch]$ScopeByTag,
        [string]$TagName = 'ReadinessRing',
        [string]$TagValue,
        [string]$SubscriptionId,
        [int]$BatchSize = 50,
        [switch]$PassThru,
        [string]$ExportPath
    )

    Write-Log '========================================' -Level Header
    Write-Log 'AKS Arc Fleet Readiness Assessment' -Level Header
    Write-Log '========================================' -Level Header

    # Ensure resource-graph extension
    $rgExt = az extension show --name resource-graph 2>$null
    if (-not $rgExt) {
        az extension add --name resource-graph --yes 2>$null
    }

    # Build ARG query to find clusters
    $query = "resources | where type == 'microsoft.azurestackhci/clusters'"

    if ($ClusterNames) {
        $nameFilter = ($ClusterNames | ForEach-Object { "'$_'" }) -join ', '
        $query += " | where name in~ ($nameFilter)"
    }

    if ($ScopeByTag -and $TagValue) {
        $query += " | where tags['$TagName'] =~ '$TagValue'"
    }

    $query += " | project name, resourceGroup, subscriptionId, location, properties.connectivityStatus, properties.provisioningState, properties.lastSyncTimestamp, id"

    Write-Log 'Querying Azure Resource Graph for clusters...' -Level Info

    $subParam = ''
    if ($SubscriptionId) { $subParam = "--subscriptions $SubscriptionId" }

    $argRaw = az graph query -q $query $subParam --first $BatchSize -o json 2>$null
    $argResult = if ($argRaw) { $argRaw | ConvertFrom-Json } else { $null }
    $clusters = if ($argResult -and $argResult.data) { $argResult.data } else { @() }

    if ($ClusterResourceIds) {
        # For resource IDs, query each directly
        $clusters = @()
        foreach ($rid in $ClusterResourceIds) {
            $c = Invoke-AzRestCall -Uri $rid
            if ($c) {
                $clusters += [PSCustomObject]@{
                    name = $c.name
                    resourceGroup = ($rid -split '/')[4]
                    subscriptionId = ($rid -split '/')[2]
                    location = $c.location
                    properties_connectivityStatus = $c.properties.connectivityStatus
                    properties_provisioningState = $c.properties.provisioningState
                    properties_lastSyncTimestamp = $c.properties.lastSyncTimestamp
                    id = $rid
                }
            }
        }
    }

    Write-Log "Found $($clusters.Count) cluster(s) to assess" -Level Info

    $results = @()

    foreach ($cl in $clusters) {
        $clName = $cl.name
        $connStatus = $cl.properties_connectivityStatus
        if (-not $connStatus) { $connStatus = $cl.'properties.connectivityStatus' }
        $provState = $cl.properties_provisioningState
        if (-not $provState) { $provState = $cl.'properties.provisioningState' }

        Write-Host "  Checking: $clName..." -NoNewline

        $clusterOk = ($connStatus -eq 'Connected') -and ($provState -eq 'Succeeded')

        # Check ARB in same RG
        $rg = $cl.resourceGroup
        $sub = $cl.subscriptionId
        $arbQuery = "resources | where type == 'microsoft.resourcebridge/appliances' | where resourceGroup =~ '$rg' | where subscriptionId == '$sub' | project name, properties.status, properties.provisioningState"
        $arbRaw = az graph query -q $arbQuery --subscriptions $sub --first 1 -o json 2>$null
        $arbData = if ($arbRaw) { ($arbRaw | ConvertFrom-Json).data } else { @() }
        $arbOk = $false
        $arbStatus = 'NotFound'
        if ($arbData -and $arbData.Count -gt 0) {
            $arbStatus = $arbData[0].'properties.status'
            if (-not $arbStatus) { $arbStatus = $arbData[0].properties_status }
            $arbOk = ($arbStatus -eq 'Running')
        }

        # Check Custom Location
        $clQuery = "resources | where type == 'microsoft.extendedlocation/customlocations' | where resourceGroup =~ '$rg' | where subscriptionId == '$sub' | project name, properties.provisioningState"
        $clRaw = az graph query -q $clQuery --subscriptions $sub --first 1 -o json 2>$null
        $clData = if ($clRaw) { ($clRaw | ConvertFrom-Json).data } else { @() }
        $clOk = $false
        if ($clData -and $clData.Count -gt 0) {
            $clProv = $clData[0].'properties.provisioningState'
            if (-not $clProv) { $clProv = $clData[0].properties_provisioningState }
            $clOk = ($clProv -eq 'Succeeded')
        }

        $overallReady = $clusterOk -and $arbOk -and $clOk
        $statusText = if ($overallReady) { 'Ready' } else { 'NotReady' }
        $icon = if ($overallReady) { ' Ready' } else { ' NotReady' }
        $iconColor = if ($overallReady) { 'Green' } else { 'Red' }
        Write-Host " $icon" -ForegroundColor $iconColor
        Write-Host "    Cluster: $connStatus/$provState | ARB: $arbStatus | CustomLoc: $(if ($clOk) {'OK'} else {'Missing'})" -ForegroundColor DarkGray

        $results += [PSCustomObject]@{
            ClusterName       = $clName
            ResourceGroup     = $rg
            SubscriptionId    = $sub
            Region            = $cl.location
            ClusterConnected  = ($connStatus -eq 'Connected')
            ClusterProvisioned = ($provState -eq 'Succeeded')
            ARBStatus         = $arbStatus
            ARBHealthy        = $arbOk
            CustomLocationOk  = $clOk
            ReadyForAksArc    = $overallReady
            Status            = $statusText
        }
    }

    # Summary
    Write-Host ''
    Write-Log '========================================' -Level Header
    Write-Log 'Fleet Summary' -Level Header
    Write-Log '========================================' -Level Header

    $ready = @($results | Where-Object { $_.ReadyForAksArc }).Count
    $notReady = $results.Count - $ready
    Write-Log "Total Clusters:  $($results.Count)" -Level Info
    Write-Log "Ready:           $ready" -Level Success
    Write-Log "Not Ready:       $notReady" -Level $(if ($notReady -gt 0) { 'Error' } else { 'Info' })

    if ($ExportPath) {
        Export-Results -Results $results -Path $ExportPath
    }

    if ($PassThru) { return $results }
}

function Get-AksArcFleetProgress {
    <#
    .SYNOPSIS
        Gets readiness status summary for a fleet of Azure Local clusters.

    .DESCRIPTION
        Queries Azure Resource Graph for cluster connectivity, ARB status, and AKS Arc
        cluster counts. Returns aggregated statistics and optional per-cluster detail.

    .PARAMETER ScopeByTag
        Filter clusters by tag.

    .PARAMETER TagName
        Tag name (default: 'ReadinessRing').

    .PARAMETER TagValue
        Tag value to match.

    .PARAMETER SubscriptionId
        Limit to a specific subscription.

    .PARAMETER Detailed
        Show per-cluster status.

    .EXAMPLE
        Get-AksArcFleetProgress -ScopeByTag -TagValue 'Wave1' -Detailed
    #>
    [CmdletBinding()]
    param(
        [switch]$ScopeByTag,
        [string]$TagName = 'ReadinessRing',
        [string]$TagValue,
        [string]$SubscriptionId,
        [switch]$Detailed
    )

    Write-Log '========================================' -Level Header
    Write-Log 'Fleet Readiness Progress' -Level Header
    Write-Log '========================================' -Level Header

    # Query clusters
    $query = "resources | where type == 'microsoft.azurestackhci/clusters'"
    if ($ScopeByTag -and $TagValue) {
        $query += " | where tags['$TagName'] =~ '$TagValue'"
    }
    $query += " | project name, resourceGroup, subscriptionId, location, properties.connectivityStatus, properties.provisioningState"

    $subParam = ''
    if ($SubscriptionId) { $subParam = "--subscriptions $SubscriptionId" }

    $rgExt = az extension show --name resource-graph 2>$null
    if (-not $rgExt) { az extension add --name resource-graph --yes 2>$null }

    $raw = az graph query -q $query $subParam --first 500 -o json 2>$null
    $data = if ($raw) { ($raw | ConvertFrom-Json).data } else { @() }

    $total = $data.Count
    $connected = @($data | Where-Object {
        $status = $_.'properties.connectivityStatus'
        if (-not $status) { $status = $_.properties_connectivityStatus }
        $status -eq 'Connected'
    }).Count
    $disconnected = $total - $connected

    # Count AKS clusters
    $aksQuery = "resources | where type == 'microsoft.kubernetes/connectedclusters' | summarize count()"
    $aksRaw = az graph query -q $aksQuery $subParam --first 1 -o json 2>$null
    $aksCount = 0
    if ($aksRaw) {
        $aksData = ($aksRaw | ConvertFrom-Json).data
        if ($aksData -and $aksData.Count -gt 0) {
            $aksCount = $aksData[0].count_
            if (-not $aksCount) { $aksCount = $aksData[0].'count_' }
        }
    }

    $progress = [PSCustomObject]@{
        Timestamp     = (Get-Date -Format 'o')
        TotalClusters = $total
        Connected     = $connected
        Disconnected  = $disconnected
        AksArcClusters = $aksCount
    }

    Write-Log "Total Clusters:      $total" -Level Info
    Write-Log "Connected:           $connected" -Level $(if ($connected -eq $total) { 'Success' } else { 'Warning' })
    Write-Log "Disconnected:        $disconnected" -Level $(if ($disconnected -gt 0) { 'Error' } else { 'Info' })
    Write-Log "AKS Arc Clusters:    $aksCount" -Level Info

    if ($Detailed -and $data.Count -gt 0) {
        Write-Host ''
        Write-Log 'Per-Cluster Status:' -Level Header
        foreach ($cl in $data) {
            $connSt = $cl.'properties.connectivityStatus'
            if (-not $connSt) { $connSt = $cl.properties_connectivityStatus }
            $icon = if ($connSt -eq 'Connected') { '[OK]' } else { '[!!]' }
            $color = if ($connSt -eq 'Connected') { 'Green' } else { 'Red' }
            Write-Host "  $icon $($cl.name) ($connSt)" -ForegroundColor $color
        }
    }

    return $progress
}
