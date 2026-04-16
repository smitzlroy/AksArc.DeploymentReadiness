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
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [string]$ApiVersion = $script:ApiVersion,
        [switch]$ThrowOnError
    )
    $fullUri = "https://management.azure.com${Uri}?api-version=$ApiVersion"
    $errOutput = $null
    $raw = az rest --method $Method --uri $fullUri 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $errOutput = $_.ToString()
        } else {
            $_
        }
    }
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        $errMsg = if ($errOutput) { $errOutput } else { "HTTP $Method $Uri returned no data (exit code $LASTEXITCODE)" }
        Write-Log "  REST call failed: $errMsg" -Level Warning
        if ($ThrowOnError) {
            throw "Azure REST call failed: $errMsg"
        }
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

        When logical networks are found but -ManagementNetwork and -AksNetwork are not
        specified, the function lists all discovered LNETs and interactively prompts you
        to select which is management and which is AKS. In non-interactive sessions
        (CI/CD), use the parameters explicitly.

    .PARAMETER SubscriptionId
        Azure subscription ID. If not specified, uses the current az CLI context.

    .PARAMETER ResourceGroupName
        Resource group containing the Azure Local cluster. Auto-discovered if not specified.

    .PARAMETER ClusterName
        Azure Local cluster name. Auto-discovered if there is exactly one in the resource group.

    .PARAMETER ManagementNetwork
        Name of the logical network used for management traffic. Used to distinguish
        management vs AKS networks in Gate 5 validation. If not specified, you will be
        prompted to select from discovered networks.

    .PARAMETER AksNetwork
        Name of the logical network used for AKS Arc workload VMs. Used to distinguish
        management vs AKS networks in Gate 5 validation. If not specified, you will be
        prompted to select from discovered networks.

    .EXAMPLE
        $ctx = Initialize-AksArcValidation
        Test-AksArcDeploymentReadiness -Context $ctx

    .EXAMPLE
        $ctx = Initialize-AksArcValidation -ManagementNetwork 'mgmt-lnet' -AksNetwork 'aks-lnet'
        Test-AksArcDeploymentReadiness -Context $ctx
    #>
    [CmdletBinding()]
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$ClusterName,
        [string]$ManagementNetwork,
        [string]$AksNetwork,
        [string[]]$ManagementIPs,
        [string]$AksSubnetTestIP,
        [string]$ClusterIP
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

    # Detect if running on an Azure Local node
    $hostType = 'Unknown'
    try {
        $clusterNodes = Get-ClusterNode -ErrorAction SilentlyContinue
        if ($clusterNodes) {
            $localName = $env:COMPUTERNAME
            if ($clusterNodes.Name -contains $localName) {
                $hostType = 'AzureLocalNode'
                Write-Log "Running on Azure Local node: $localName" -Level Success
            } else {
                $hostType = 'RemoteHost'
            }
        } else {
            $hostType = 'RemoteHost'
        }
    } catch {
        $hostType = 'RemoteHost'
    }

    if ($hostType -ne 'AzureLocalNode') {
        Write-Log 'WARNING: Running from a remote host. Network connectivity tests validate from THIS machine, not from Azure Local nodes. For accurate firewall validation, run this module from an Azure Local node.' -Level Warning
    }

    # Discover logical networks
    $lnetRaw = az stack-hci-vm network lnet list -g $rg -o json 2>$null
    $lnets = if ($lnetRaw) { $lnetRaw | ConvertFrom-Json } else { @() }
    Write-Log "Logical Networks: $($lnets.Count) found" -Level Info

    # Identify management vs AKS networks - interactive selection when not specified
    if ($lnets.Count -gt 0 -and -not $ManagementNetwork -and -not $AksNetwork) {
        $isInteractive = [Environment]::UserInteractive -and -not $env:TF_BUILD -and -not $env:GITHUB_ACTIONS -and -not $env:SYSTEM_TEAMPROJECT

        Write-Log 'Discovered logical networks:' -Level Info
        for ($i = 0; $i -lt $lnets.Count; $i++) {
            $l = $lnets[$i]
            $subnet = if ($l.properties.subnets) { $l.properties.subnets[0].properties.addressPrefix } else { 'N/A' }
            $vlan = if ($l.properties.subnets -and $l.properties.subnets[0].properties.vlan) { $l.properties.subnets[0].properties.vlan } else { 'none' }
            $ipPools = if ($l.properties.subnets -and $l.properties.subnets[0].properties.ipPools) { $l.properties.subnets[0].properties.ipPools.Count } else { 0 }
            Write-Log "  [$($i + 1)] $($l.name) - Subnet: $subnet, VLAN: $vlan, IP Pools: $ipPools" -Level Info
        }

        if ($isInteractive -and $lnets.Count -ge 2) {
            Write-Host ''
            Write-Host 'Network role assignment is required for Gate 5 validation.' -ForegroundColor Cyan
            Write-Host 'Which logical network is used for management traffic?' -ForegroundColor Cyan
            $mgmtInput = Read-Host "Enter number [1-$($lnets.Count)] or press Enter to skip"
            if ($mgmtInput -match '^\d+$' -and [int]$mgmtInput -ge 1 -and [int]$mgmtInput -le $lnets.Count) {
                $ManagementNetwork = $lnets[[int]$mgmtInput - 1].name
                Write-Log "Management network: $ManagementNetwork" -Level Success
            }

            Write-Host 'Which logical network is used for AKS Arc workload VMs?' -ForegroundColor Cyan
            $aksInput = Read-Host "Enter number [1-$($lnets.Count)] or press Enter to skip"
            if ($aksInput -match '^\d+$' -and [int]$aksInput -ge 1 -and [int]$aksInput -le $lnets.Count) {
                $AksNetwork = $lnets[[int]$aksInput - 1].name
                Write-Log "AKS network: $AksNetwork" -Level Success
            }

            if (-not $ManagementNetwork -and -not $AksNetwork) {
                Write-Log 'No network roles assigned. Gate 5 will run basic validation only.' -Level Warning
            }
        } elseif ($isInteractive -and $lnets.Count -eq 1) {
            Write-Host ''
            Write-Host "Only one logical network found: $($lnets[0].name)" -ForegroundColor Cyan
            Write-Host 'Is this the AKS Arc workload network? (y/n)' -ForegroundColor Cyan
            $singleInput = Read-Host '[y/n]'
            if ($singleInput -match '^[yY]') {
                $AksNetwork = $lnets[0].name
                Write-Log "AKS network: $AksNetwork (single-subnet deployment)" -Level Success
            }
        } else {
            Write-Log 'Non-interactive session detected. Use -ManagementNetwork and -AksNetwork for full Gate 5 validation.' -Level Warning
        }
    }

    # Build context
    $ctx = [PSCustomObject]@{
        SubscriptionId     = $account.id
        SubscriptionName   = $account.name
        ResourceGroup      = $rg
        Region             = $region
        ClusterName        = $cluster.name
        ClusterId          = $cluster.id
        ArbName            = if ($arb) { $arb.name } else { $null }
        ArbId              = if ($arb) { $arb.id } else { $null }
        ArbStatus          = if ($arb) { $arb.status } else { $null }
        CustomLocation     = if ($customLoc) { $customLoc.name } else { $null }
        CustomLocationId   = if ($customLoc) { $customLoc.id } else { $null }
        LogicalNetworks    = $lnets
        ManagementNetwork  = $ManagementNetwork
        AksNetwork         = $AksNetwork
        ManagementIPs      = $ManagementIPs
        AksSubnetTestIP    = $AksSubnetTestIP
        ClusterIP          = $ClusterIP
        HostType           = $hostType
        Timestamp          = (Get-Date -Format 'o')
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
        Filter by component name (case-insensitive, supports wildcards): 'Azure Local AKS infra',
        'Azure Local ARB infra', 'Azure Local Arc agent', 'Azure Local authentication',
        'Azure Local deployment', 'Azure Local monitoring', 'Azure Local CRLs', etc.

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

    # Apply filters (case-insensitive component match)
    if ($Component) {
        $endpoints = @($endpoints | Where-Object { $_.component -like $Component })
    }
    if ($null -ne $ArcGatewaySupported) {
        $endpoints = @($endpoints | Where-Object { $_.arcGatewaySupported -eq $ArcGatewaySupported })
    }

    # Warn about region-specific endpoints when no Region specified
    $regionEndpoints = @($endpoints | Where-Object { $_.regionSpecific -eq $true })
    if (-not $Region -and $regionEndpoints.Count -gt 0) {
        Write-Log "WARNING: $($regionEndpoints.Count) endpoint(s) are region-specific but -Region was not specified. These will be tested as-is (eastus default) and may fail DNS if your cluster is in another region. Use -Region <yourRegion> for accurate results." -Level Warning
    }

    Write-Log "Testing $($endpoints.Count) endpoint(s)..." -Level Info
    if ($Region) { Write-Log "Region: $Region" -Level Info }

    $results = @()
    $passed = 0
    $failed = 0

    foreach ($ep in $endpoints) {
        $url = $ep.url
        # Resolve region-specific URLs (replace region prefix for explicit region endpoints)
        if ($Region -and $ep.regionSpecific) {
            foreach ($pattern in $data.regionUrlPatterns) {
                $regionPart = $pattern.pattern -replace '\{region\}', '([a-z0-9]+)'
                if ($url -match "^$regionPart$") {
                    $url = $pattern.pattern -replace '\{region\}', $Region
                    break
                }
            }
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

function New-AksArcDeploymentPlan {
    <#
    .SYNOPSIS
        Creates a deployment plan for IP capacity and resource validation.

    .DESCRIPTION
        Calculates total IP address requirements based on the planned AKS Arc deployment.
        The plan object is passed to Test-AksArcDeploymentReadiness to validate that the
        target logical network has sufficient IP capacity.

        IP math follows Microsoft documentation:
        - 1 IP per Kubernetes node VM (control plane + worker)
        - 1 IP per cluster for rolling upgrade operations
        - 1 IP per cluster for the control plane (KubeVIP)
        - Additional IPs for load balancer services (MetalLB)

    .PARAMETER PlannedClusters
        Number of AKS Arc clusters to deploy (default: 1).

    .PARAMETER ControlPlaneNodes
        Control plane nodes per cluster. Must be 1 or 3 (default: 3).

    .PARAMETER WorkerNodes
        Worker nodes per cluster (default: 3).

    .PARAMETER LoadBalancerIPs
        Number of IPs reserved for load balancer services such as MetalLB (default: 3).

    .PARAMETER EnableAutoScale
        Account for autoscaler headroom in IP calculations.

    .PARAMETER MaxAutoScaleNodes
        Maximum worker nodes when autoscaling is enabled. Used with -EnableAutoScale.

    .PARAMETER AksNetworkName
        Name of the logical network designated for AKS Arc workloads.

    .PARAMETER ManagementNetworkName
        Name of the logical network designated for management traffic.

    .EXAMPLE
        $plan = New-AksArcDeploymentPlan -PlannedClusters 2 -WorkerNodes 5

    .EXAMPLE
        $plan = New-AksArcDeploymentPlan -PlannedClusters 1 -ControlPlaneNodes 3 -WorkerNodes 5 -LoadBalancerIPs 5 -AksNetworkName 'aks-lnet'
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 50)]
        [int]$PlannedClusters,
        [ValidateSet(1, 3)]
        [int]$ControlPlaneNodes,
        [ValidateRange(1, 200)]
        [int]$WorkerNodes,
        [ValidateRange(0, 100)]
        [int]$LoadBalancerIPs,
        [switch]$EnableAutoScale,
        [ValidateRange(1, 500)]
        [int]$MaxAutoScaleNodes,
        [string]$AksNetworkName,
        [string]$ManagementNetworkName
    )

    # Interactive fallback: prompt for missing values when running interactively
    $isInteractive = [Environment]::UserInteractive -and -not $env:TF_BUILD -and -not $env:GITHUB_ACTIONS -and -not $env:SYSTEM_TEAMPROJECT

    if (-not $PSBoundParameters.ContainsKey('PlannedClusters')) {
        if ($isInteractive) {
            $input = Read-Host "How many AKS Arc clusters do you plan to deploy? [1]"
            $PlannedClusters = if ($input -match '^\d+$') { [int]$input } else { 1 }
        } else {
            $PlannedClusters = 1
        }
    }

    if (-not $PSBoundParameters.ContainsKey('ControlPlaneNodes')) {
        if ($isInteractive) {
            $input = Read-Host "Control plane nodes per cluster (1 or 3)? [3]"
            $ControlPlaneNodes = if ($input -eq '1') { 1 } else { 3 }
        } else {
            $ControlPlaneNodes = 3
        }
    }

    if (-not $PSBoundParameters.ContainsKey('WorkerNodes')) {
        if ($isInteractive) {
            $input = Read-Host "Worker nodes per cluster? [3]"
            $WorkerNodes = if ($input -match '^\d+$') { [int]$input } else { 3 }
        } else {
            $WorkerNodes = 3
        }
    }

    if (-not $PSBoundParameters.ContainsKey('LoadBalancerIPs')) {
        if ($isInteractive) {
            $input = Read-Host "IP addresses for load balancer services (MetalLB)? [3]"
            $LoadBalancerIPs = if ($input -match '^\d+$') { [int]$input } else { 3 }
        } else {
            $LoadBalancerIPs = 3
        }
    }

    # Calculate IP requirements per Microsoft documentation
    $nodesPerCluster = $ControlPlaneNodes + $WorkerNodes
    $totalNodeVMs = $nodesPerCluster * $PlannedClusters
    $totalUpgradeIPs = $PlannedClusters          # 1 rolling upgrade IP per cluster
    $totalControlPlaneIPs = $PlannedClusters      # 1 KubeVIP control plane IP per cluster

    # Autoscale headroom
    $autoScaleHeadroom = 0
    if ($EnableAutoScale -and $MaxAutoScaleNodes -gt $WorkerNodes) {
        $autoScaleHeadroom = ($MaxAutoScaleNodes - $WorkerNodes) * $PlannedClusters
    }

    $totalRequiredIPs = $totalNodeVMs + $totalUpgradeIPs + $totalControlPlaneIPs + $autoScaleHeadroom
    $totalWithLoadBalancer = $totalRequiredIPs + $LoadBalancerIPs

    Write-Log '========================================' -Level Header
    Write-Log 'AKS Arc Deployment Plan' -Level Header
    Write-Log '========================================' -Level Header
    Write-Log "Planned clusters:       $PlannedClusters" -Level Info
    Write-Log "Control plane nodes:    $ControlPlaneNodes per cluster" -Level Info
    Write-Log "Worker nodes:           $WorkerNodes per cluster" -Level Info
    Write-Log "Nodes per cluster:      $nodesPerCluster" -Level Info
    Write-Log '' -Level Info
    Write-Log 'IP Address Requirements (from logical network IP pool):' -Level Header
    Write-Log "  Node VMs:             $totalNodeVMs IPs ($nodesPerCluster nodes x $PlannedClusters clusters)" -Level Info
    Write-Log "  Rolling upgrade:      $totalUpgradeIPs IPs (1 per cluster)" -Level Info
    Write-Log "  Control plane:        $totalControlPlaneIPs IPs (1 KubeVIP per cluster)" -Level Info
    if ($autoScaleHeadroom -gt 0) {
        Write-Log "  Autoscale headroom:   $autoScaleHeadroom IPs (max $MaxAutoScaleNodes workers)" -Level Info
    }
    Write-Log "  -------------------------------------" -Level Info
    Write-Log "  IP pool required:     $totalRequiredIPs IPs" -Level Header
    Write-Log '' -Level Info
    Write-Log "Load balancer IPs:      $LoadBalancerIPs IPs (same subnet, OUTSIDE IP pool)" -Level Info
    Write-Log "Total IPs in subnet:    $totalWithLoadBalancer IPs" -Level Info

    $plan = [PSCustomObject]@{
        PlannedClusters       = $PlannedClusters
        ControlPlaneNodes     = $ControlPlaneNodes
        WorkerNodes           = $WorkerNodes
        NodesPerCluster       = $nodesPerCluster
        LoadBalancerIPs       = $LoadBalancerIPs
        EnableAutoScale       = [bool]$EnableAutoScale
        MaxAutoScaleNodes     = if ($EnableAutoScale) { $MaxAutoScaleNodes } else { 0 }
        AutoScaleHeadroom     = $autoScaleHeadroom
        TotalNodeVMs          = $totalNodeVMs
        TotalUpgradeIPs       = $totalUpgradeIPs
        TotalControlPlaneIPs  = $totalControlPlaneIPs
        TotalRequiredIPs      = $totalRequiredIPs
        TotalWithLoadBalancer = $totalWithLoadBalancer
        AksNetworkName        = $AksNetworkName
        ManagementNetworkName = $ManagementNetworkName
        Timestamp             = (Get-Date -Format 'o')
    }

    Write-Log '' -Level Info
    Write-Log 'Deployment plan created. Pass to Test-AksArcDeploymentReadiness -DeploymentPlan $plan' -Level Success
    return $plan
}

function Test-AksArcDeploymentReadiness {
    <#
    .SYNOPSIS
        Runs all pre-deployment readiness gates for AKS Arc on a single Azure Local cluster.

    .DESCRIPTION
        Validates cluster health, ARB status, custom location, network connectivity,
        logical networks, and RBAC. Returns structured pass/fail results per gate.

        When a DeploymentPlan is provided (from New-AksArcDeploymentPlan), Gate 5 performs
        deep IP capacity validation against the logical network IP pools.

    .PARAMETER Context
        Context object from Initialize-AksArcValidation. If not provided, runs Initialize-AksArcValidation.

    .PARAMETER DeploymentPlan
        Deployment plan from New-AksArcDeploymentPlan. Enables IP capacity validation in Gate 5.

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
        $plan = New-AksArcDeploymentPlan -PlannedClusters 2 -WorkerNodes 5
        Test-AksArcDeploymentReadiness -Context $ctx -DeploymentPlan $plan -ExportPath results.xml
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [PSCustomObject]$Context,
        [PSCustomObject]$DeploymentPlan,
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

        # Gate 5: Logical Networks (deep validation)
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

                    # Determine role
                    $role = 'unknown'
                    if ($Context.ManagementNetwork -and $lnet.name -eq $Context.ManagementNetwork) {
                        $role = 'management'
                    } elseif ($Context.AksNetwork -and $lnet.name -eq $Context.AksNetwork) {
                        $role = 'aks'
                    }
                    $roleLabel = if ($role -ne 'unknown') { " ($role)" } else { '' }

                    if ($provState -eq 'Succeeded') {
                        $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)" -Status 'Passed' -Message "Provisioned$roleLabel"
                    } else {
                        $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)" -Status 'Warning' -Message "Provisioning: $provState$roleLabel"
                    }

                    # Validate subnet configuration
                    $subnets = $lnetObj.properties.subnets
                    if ($subnets -and $subnets.Count -gt 0) {
                        $subnet = $subnets[0]
                        $prefix = $subnet.properties.addressPrefix
                        $vlan = $subnet.properties.vlan
                        $gateway = $subnet.properties.gateway
                        $dnsServers = $subnet.properties.dnsServers

                        if (-not $prefix) {
                            $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-Subnet" -Status 'Failed' `
                                -Message "No address prefix configured$roleLabel" `
                                -Remediation 'Logical network must have a valid subnet address prefix.'
                        } else {
                            Write-Log "  $($lnet.name): Subnet=$prefix, VLAN=$(if ($vlan) { $vlan } else { 'none' })$roleLabel" -Level Info
                        }

                        # IP allocation method - AKS Arc requires static
                        $allocMethod = $subnet.properties.ipAllocationMethod
                        if ($allocMethod -and $allocMethod -ne 'Static') {
                            $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-AllocMethod" -Status 'Failed' `
                                -Message "IP allocation is '$allocMethod'$roleLabel - AKS Arc requires static IP allocation" `
                                -Remediation 'Recreate the logical network with ipAllocationMethod set to Static. DHCP is not supported.'
                        }

                        # Gateway validation
                        if (-not $gateway) {
                            $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-Gateway" -Status 'Warning' `
                                -Message "No default gateway configured$roleLabel" `
                                -Remediation 'A default gateway is typically required for AKS Arc nodes to reach Azure endpoints.'
                        }

                        # DNS server validation
                        if (-not $dnsServers -or $dnsServers.Count -eq 0) {
                            $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-DNS" -Status 'Warning' `
                                -Message "No DNS servers configured$roleLabel" `
                                -Remediation 'Configure DNS servers so AKS Arc nodes can resolve Azure endpoints.'
                        } else {
                            Write-Log "  $($lnet.name): DNS servers: $($dnsServers -join ', ')" -Level Info
                            # Test DNS resolution using configured DNS servers
                            $dnsTestTargets = @('mcr.microsoft.com', 'management.azure.com')
                            foreach ($dnsServer in $dnsServers) {
                                $allResolved = $true
                                foreach ($target in $dnsTestTargets) {
                                    try {
                                        $resolved = Resolve-DnsName -Name $target -Server $dnsServer -Type A -DnsOnly -ErrorAction Stop 2>$null
                                        if (-not $resolved) { $allResolved = $false }
                                    } catch {
                                        $allResolved = $false
                                    }
                                }
                                if ($allResolved) {
                                    $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-DNS-$dnsServer" -Status 'Passed' `
                                        -Message "DNS server $dnsServer resolves Azure endpoints"
                                    Write-Log "  DNS ${dnsServer}: resolves Azure endpoints" -Level Success
                                } else {
                                    $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-DNS-$dnsServer" -Status 'Failed' `
                                        -Message "DNS server $dnsServer cannot resolve Azure endpoints (mcr.microsoft.com, management.azure.com)$roleLabel" `
                                        -Remediation "Verify DNS server $dnsServer is reachable and can resolve public Azure endpoints."
                                    Write-Log "  DNS ${dnsServer}: FAILED to resolve Azure endpoints" -Level Error
                                }
                            }
                        }

                        # Deep IP pool validation for AKS network
                        $ipPools = $subnet.properties.ipPools
                        if ($role -eq 'aks') {
                            if (-not $ipPools -or $ipPools.Count -eq 0) {
                                $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-IPPool" -Status 'Failed' `
                                    -Message "AKS network has no IP pools defined$roleLabel" `
                                    -Remediation 'AKS logical network must have IP address pools for node VM allocation. Add an IP pool with sufficient addresses.'
                                Write-Log "  $($lnet.name): NO IP pools - deployment will fail" -Level Error
                            } else {
                                # Count total available IPs across all pools
                                $totalPoolIPs = 0
                                foreach ($pool in $ipPools) {
                                    $poolStart = $pool.start
                                    $poolEnd = $pool.end
                                    if (-not $poolStart) { $poolStart = $pool.properties.start }
                                    if (-not $poolEnd) { $poolEnd = $pool.properties.end }
                                    if ($poolStart -and $poolEnd) {
                                        try {
                                            $startBytes = [System.Net.IPAddress]::Parse($poolStart).GetAddressBytes()
                                            $endBytes = [System.Net.IPAddress]::Parse($poolEnd).GetAddressBytes()
                                            [Array]::Reverse($startBytes)
                                            [Array]::Reverse($endBytes)
                                            $startInt = [BitConverter]::ToUInt32($startBytes, 0)
                                            $endInt = [BitConverter]::ToUInt32($endBytes, 0)
                                            $poolSize = $endInt - $startInt + 1
                                            $totalPoolIPs += $poolSize
                                            Write-Log "  $($lnet.name): IP Pool $poolStart - $poolEnd ($poolSize IPs)" -Level Info
                                        } catch {
                                            Write-Log "  $($lnet.name): Could not parse IP pool range ($poolStart - $poolEnd)" -Level Warning
                                        }
                                    }
                                }

                                if ($totalPoolIPs -gt 0) {
                                    Write-Log "  $($lnet.name): Total IP pool capacity: $totalPoolIPs IPs" -Level Info

                                    if ($DeploymentPlan) {
                                        $required = $DeploymentPlan.TotalRequiredIPs
                                        if ($totalPoolIPs -ge $required) {
                                            $margin = $totalPoolIPs - $required
                                            $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-IPCapacity" -Status 'Passed' `
                                                -Message "IP pool has $totalPoolIPs IPs available, $required required ($margin margin)"
                                            Write-Log "  IP capacity: $totalPoolIPs available >= $required required (margin: $margin)" -Level Success
                                        } else {
                                            $deficit = $required - $totalPoolIPs
                                            $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-IPCapacity" -Status 'Failed' `
                                                -Message "INSUFFICIENT IPs: pool has $totalPoolIPs, but $required required (short by $deficit)" `
                                                -Detail "Need: $($DeploymentPlan.TotalNodeVMs) node VMs + $($DeploymentPlan.TotalUpgradeIPs) upgrade + $($DeploymentPlan.TotalControlPlaneIPs) control plane$(if ($DeploymentPlan.AutoScaleHeadroom -gt 0) { " + $($DeploymentPlan.AutoScaleHeadroom) autoscale" })" `
                                                -Remediation "Expand the IP pool by at least $deficit addresses, or reduce the number of planned clusters/nodes."
                                            Write-Log "  IP capacity: INSUFFICIENT - $totalPoolIPs available < $required required (deficit: $deficit)" -Level Error
                                        }

                                        # Warn about load balancer IPs needing to be in same subnet but outside pool
                                        if ($DeploymentPlan.LoadBalancerIPs -gt 0) {
                                            $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-LBIPs" -Status 'Warning' `
                                                -Message "$($DeploymentPlan.LoadBalancerIPs) load balancer IPs needed in same subnet but OUTSIDE the IP pool range" `
                                                -Remediation 'Ensure load balancer (MetalLB) IPs are in the same subnet but not overlapping with the IP pool.'
                                        }
                                    } else {
                                        # No deployment plan - just report pool size
                                        $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-IPPool" -Status 'Passed' `
                                            -Message "IP pool has $totalPoolIPs IPs available. Use -DeploymentPlan to validate capacity."
                                    }
                                } else {
                                    $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-IPPool" -Status 'Warning' `
                                        -Message "IP pools defined but could not calculate available IPs$roleLabel" `
                                        -Remediation 'Verify IP pool start and end addresses are configured correctly.'
                                }
                            }
                        } elseif ($role -ne 'management') {
                            # Non-designated network - just report IP pool presence
                            if ($ipPools -and $ipPools.Count -gt 0) {
                                Write-Log "  $($lnet.name): IP pools present" -Level Info
                            }
                        }
                    } else {
                        $results += New-ValidationResult -Gate 'LogicalNetworks' -Check "LNET-$($lnet.name)-Subnet" -Status 'Warning' `
                            -Message "No subnets configured$roleLabel" `
                            -Remediation 'Logical network should have at least one subnet.'
                    }
                }
            }

            # Check that both management and AKS networks are identified
            if ($Context.ManagementNetwork -and $Context.AksNetwork) {
                if ($Context.ManagementNetwork -eq $Context.AksNetwork) {
                    $results += New-ValidationResult -Gate 'LogicalNetworks' -Check 'NetworkSeparation' -Status 'Warning' `
                        -Message 'Management and AKS networks are the same logical network' `
                        -Detail 'Single-subnet deployment detected. Cross-subnet ports are not applicable.'
                } else {
                    $results += New-ValidationResult -Gate 'LogicalNetworks' -Check 'NetworkSeparation' -Status 'Passed' `
                        -Message "Management: $($Context.ManagementNetwork), AKS: $($Context.AksNetwork)"
                }
            } elseif (-not $Context.ManagementNetwork -and -not $Context.AksNetwork) {
                $results += New-ValidationResult -Gate 'LogicalNetworks' -Check 'NetworkRoles' -Status 'Warning' `
                    -Message 'Network roles not specified. Use -ManagementNetwork and -AksNetwork in Initialize-AksArcValidation.' `
                    -Remediation 'Specify -ManagementNetwork and -AksNetwork to enable detailed subnet validation.'
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

        # Gate 7: Active Cross-Subnet Port Testing
        Write-Log '' -Level Info
        Write-Log 'Gate 7: Active Cross-Subnet Port Testing' -Level Header

        if ($Context.AksSubnetTestIP -or $Context.ClusterIP) {
            $crossPorts = (Get-EndpointData).crossSubnetPorts
            foreach ($portEntry in $crossPorts) {
                $port = $portEntry.port
                $purpose = $portEntry.purpose
                $testDir = $portEntry.testDirection
                $conditional = $portEntry.conditional

                # Skip Arc Gateway port if not explicitly testing
                if ($conditional -and $port -eq 40343) {
                    $results += New-ValidationResult -Gate 'ActivePortTest' -Check "Port${port}" -Status 'Skipped' `
                        -Message "Port $port ($purpose) - skipped (conditional, Arc Gateway must be enabled)" `
                        -Detail 'Enable Arc Gateway and provide -ClusterIP to test this port.'
                    Write-Log "  SKIP Port $port ($purpose) - conditional" -Level Info
                    continue
                }

                # Determine target IP based on test direction
                $targetIP = $null
                $direction = ''
                if ($testDir -eq 'toAks' -and $Context.AksSubnetTestIP) {
                    $targetIP = $Context.AksSubnetTestIP
                    $direction = "current host -> $targetIP"
                } elseif ($testDir -eq 'toCluster' -and $Context.ClusterIP) {
                    $targetIP = $Context.ClusterIP
                    $direction = "current host -> $targetIP"
                }

                if (-not $targetIP) {
                    $missingParam = if ($testDir -eq 'toAks') { '-AksSubnetTestIP' } else { '-ClusterIP' }
                    $results += New-ValidationResult -Gate 'ActivePortTest' -Check "Port${port}" -Status 'Skipped' `
                        -Message "Port $port ($purpose) - skipped ($missingParam not provided)" `
                        -Detail "Provide $missingParam on Initialize-AksArcValidation to enable this test."
                    Write-Log "  SKIP Port $port ($purpose) - $missingParam not provided" -Level Info
                    continue
                }

                $portResult = Test-TcpPort -Hostname $targetIP -Port $port -TimeoutMs 5000
                if ($portResult.Connected) {
                    $results += New-ValidationResult -Gate 'ActivePortTest' -Check "Port${port}" -Status 'Passed' `
                        -Message "Port $port ($purpose) reachable ($direction)" `
                        -Detail "TCP connection to ${targetIP}:$port succeeded in $($portResult.ResponseTimeMs)ms"
                    Write-Log "  PASS Port $port ($purpose) - $direction" -Level Success
                } else {
                    $errDetail = if ($portResult.Error) { $portResult.Error } else { 'Connection timed out or refused' }
                    $results += New-ValidationResult -Gate 'ActivePortTest' -Check "Port${port}" -Status 'Failed' `
                        -Message "Port $port ($purpose) NOT reachable ($direction)" `
                        -Remediation "Ensure firewall rules allow TCP/$port ($purpose) between management and AKS subnets. Target: ${targetIP}:$port. Error: $errDetail"
                    Write-Log "  FAIL Port $port ($purpose) - $direction ($errDetail)" -Level Error
                }
            }
        } else {
            $results += New-ValidationResult -Gate 'ActivePortTest' -Check 'PortTestSkipped' -Status 'Skipped' `
                -Message 'Active cross-subnet port testing skipped - no target IPs provided' `
                -Detail 'Provide -AksSubnetTestIP and/or -ClusterIP on Initialize-AksArcValidation to enable active port testing.'
            Write-Log '  Skipped - provide -AksSubnetTestIP and/or -ClusterIP to enable active testing.' -Level Info
        }

        # Gate 8: RBAC Permission Validation
        Write-Log '' -Level Info
        Write-Log 'Gate 8: RBAC Permission Validation' -Level Header

        $rbacPassed = $true
        try {
            # Get current identity
            $callerRaw = az account show -o json 2>$null
            $caller = $callerRaw | ConvertFrom-Json
            $callerType = $caller.user.type  # 'user' or 'servicePrincipal'
            $callerName = $caller.user.name

            # Get role assignments at resource group scope
            $rgScope = "/subscriptions/$($Context.SubscriptionId)/resourceGroups/$($Context.ResourceGroup)"
            $assignmentsRaw = az role assignment list --scope $rgScope --assignee $callerName -o json 2>$null
            $assignments = if ($assignmentsRaw) { $assignmentsRaw | ConvertFrom-Json } else { @() }

            $roleNames = @($assignments | ForEach-Object { $_.roleDefinitionName }) | Select-Object -Unique

            Write-Log "  Identity: $callerName ($callerType)" -Level Info
            Write-Log "  Roles at RG scope: $($roleNames -join ', ')" -Level Info

            # Check for sufficient permissions via well-known roles
            $sufficientRoles = @('Owner', 'Contributor', 'Azure Kubernetes Service Arc Contributor')
            $hasSufficientRole = $false
            foreach ($role in $roleNames) {
                if ($role -in $sufficientRoles) {
                    $hasSufficientRole = $true
                    break
                }
            }

            if ($hasSufficientRole) {
                $matchedRole = ($roleNames | Where-Object { $_ -in $sufficientRoles }) -join ', '
                $results += New-ValidationResult -Gate 'RBAC' -Check 'DeploymentPermissions' -Status 'Passed' `
                    -Message "Identity '$callerName' has sufficient role: $matchedRole" `
                    -Detail "Roles: $($roleNames -join ', ')"
                Write-Log "  PASS Sufficient role: $matchedRole" -Level Success
            } else {
                # Check for specific permissions needed
                $requiredActions = @(
                    'Microsoft.Kubernetes/connectedClusters/write'
                    'Microsoft.ExtendedLocation/customLocations/read'
                    'Microsoft.AzureStackHCI/logicalNetworks/read'
                    'Microsoft.HybridContainerService/provisionedClusterInstances/write'
                )

                # Get detailed permissions for each assigned role
                $allPermissions = @()
                foreach ($assignment in $assignments) {
                    $roleDefRaw = az role definition list --name $assignment.roleDefinitionName -o json 2>$null
                    if ($roleDefRaw) {
                        $roleDef = $roleDefRaw | ConvertFrom-Json
                        foreach ($perm in $roleDef.permissions) {
                            $allPermissions += $perm.actions
                        }
                    }
                }

                $missingActions = @()
                foreach ($action in $requiredActions) {
                    $found = $false
                    foreach ($perm in $allPermissions) {
                        if ($perm -eq '*' -or $perm -eq $action) {
                            $found = $true
                            break
                        }
                        # Check wildcard patterns like Microsoft.Kubernetes/*
                        $pattern = $perm -replace '\*', '.*'
                        if ($action -match "^${pattern}$") {
                            $found = $true
                            break
                        }
                    }
                    if (-not $found) { $missingActions += $action }
                }

                if ($missingActions.Count -eq 0) {
                    $results += New-ValidationResult -Gate 'RBAC' -Check 'DeploymentPermissions' -Status 'Passed' `
                        -Message "Identity '$callerName' has all required permissions via custom roles" `
                        -Detail "Roles: $($roleNames -join ', ')"
                    Write-Log "  PASS All required permissions found via custom roles" -Level Success
                } else {
                    $rbacPassed = $false
                    $missingList = $missingActions -join ', '
                    $results += New-ValidationResult -Gate 'RBAC' -Check 'DeploymentPermissions' -Status 'Failed' `
                        -Message "Identity '$callerName' is missing permissions: $missingList" `
                        -Remediation "Assign 'Contributor' or 'Azure Kubernetes Service Arc Contributor' role on resource group '$($Context.ResourceGroup)'. Missing: $missingList"
                    Write-Log "  FAIL Missing permissions: $missingList" -Level Error
                }
            }

            # Check Reader role (warn - not sufficient for deployment)
            if ($roleNames -contains 'Reader' -and -not $hasSufficientRole) {
                $results += New-ValidationResult -Gate 'RBAC' -Check 'ReaderRoleWarning' -Status 'Warning' `
                    -Message "Identity has Reader role but this is insufficient for AKS Arc deployment" `
                    -Remediation "Upgrade to 'Contributor' or 'Azure Kubernetes Service Arc Contributor' role."
                Write-Log '  WARN Reader role alone is insufficient for deployment' -Level Warning
            }
        } catch {
            $results += New-ValidationResult -Gate 'RBAC' -Check 'RBACCheck' -Status 'Warning' `
                -Message "RBAC validation could not complete: $($_.Exception.Message)" `
                -Detail 'RBAC check requires az CLI authentication. Run az login first.'
            Write-Log "  WARN RBAC check failed: $($_.Exception.Message)" -Level Warning
        }
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
        $endpoints = @($endpoints | Where-Object { $_.component -like $Component })
    }
    if ($null -ne $ArcGatewaySupported) {
        $endpoints = @($endpoints | Where-Object { $_.arcGatewaySupported -eq $ArcGatewaySupported })
    }
    if ($RequiredFor) {
        $endpoints = @($endpoints | Where-Object { $_.requiredFor -eq $RequiredFor -or $_.requiredFor -eq 'both' })
    }

    # Resolve region URLs using regionUrlPatterns
    if ($Region) {
        $endpoints = $endpoints | ForEach-Object {
            $ep = $_
            if ($ep.regionSpecific) {
                $resolvedUrl = $ep.url
                foreach ($pattern in $data.regionUrlPatterns) {
                    $regionPart = $pattern.pattern -replace '\{region\}', '([a-z0-9]+)'
                    if ($ep.url -match "^$regionPart$") {
                        $resolvedUrl = $pattern.pattern -replace '\{region\}', $Region
                        break
                    }
                }
                $ep | Add-Member -NotePropertyName 'resolvedUrl' -NotePropertyValue $resolvedUrl -PassThru
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
        ARB health, custom location, extension health, logical network health, and AKS Arc
        cluster count. Supports tag-based scoping, batch processing, parallel collection,
        configurable health thresholds, and result export.

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

    .PARAMETER DeploymentPlan
        Deployment plan from New-AksArcDeploymentPlan for fleet-wide IP capacity validation.

    .PARAMETER MinReadyPercent
        Minimum percentage of clusters that must be ready for fleet to pass (default: 100).

    .PARAMETER MaxWarningPercent
        Maximum percentage of clusters with warnings before fleet assessment fails (default: 10).

    .PARAMETER ThrottleLimit
        Maximum parallel jobs for data collection (default: 4).

    .PARAMETER BatchSize
        Clusters per batch for ARG queries (default: 50).

    .PARAMETER PassThru
        Return result objects.

    .PARAMETER ExportPath
        Export to CSV, JSON, or JUnit XML.

    .EXAMPLE
        Test-AksArcFleetReadiness -ClusterNames @('cluster01', 'cluster02')

    .EXAMPLE
        Test-AksArcFleetReadiness -ScopeByTag -TagName 'Environment' -TagValue 'Production' -MinReadyPercent 80

    .EXAMPLE
        $plan = New-AksArcDeploymentPlan -PlannedClusters 2 -WorkerNodes 5
        Test-AksArcFleetReadiness -ScopeByTag -TagValue 'Wave1' -DeploymentPlan $plan
    #>
    [CmdletBinding()]
    param(
        [string[]]$ClusterNames,
        [string[]]$ClusterResourceIds,
        [switch]$ScopeByTag,
        [string]$TagName = 'ReadinessRing',
        [string]$TagValue,
        [string]$SubscriptionId,
        [PSCustomObject]$DeploymentPlan,
        [ValidateRange(0, 100)]
        [int]$MinReadyPercent = 100,
        [ValidateRange(0, 100)]
        [int]$MaxWarningPercent = 10,
        [ValidateRange(1, 20)]
        [int]$ThrottleLimit = 4,
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
    if ($DeploymentPlan) {
        Write-Log "Deployment plan: $($DeploymentPlan.PlannedClusters) clusters, $($DeploymentPlan.TotalRequiredIPs) IPs required from pool" -Level Info
    }

    $results = @()

    # Collect per-cluster data - parallel when multiple clusters
    $clusterAssessments = @()
    if ($clusters.Count -gt 1 -and $ThrottleLimit -gt 1) {
        Write-Log "Collecting fleet data in parallel (throttle: $ThrottleLimit)..." -Level Info
        $jobs = @()
        foreach ($cl in $clusters) {
            $rg = $cl.resourceGroup
            $sub = $cl.subscriptionId
            $clId = if ($cl.id) { $cl.id } else { '' }
            # Start background job for each cluster's supplementary queries
            $jobs += Start-Job -ScriptBlock {
                param($rg, $sub, $clId)
                $result = @{}

                # ARB
                $arbRaw = az graph query -q "resources | where type == 'microsoft.resourcebridge/appliances' | where resourceGroup =~ '$rg' | where subscriptionId == '$sub' | project name, properties.status, properties.provisioningState" --subscriptions $sub --first 1 -o json 2>$null
                $result['arbData'] = if ($arbRaw) { $arbRaw } else { '{"data":[]}' }

                # Custom Location
                $clRaw = az graph query -q "resources | where type == 'microsoft.extendedlocation/customlocations' | where resourceGroup =~ '$rg' | where subscriptionId == '$sub' | project name, properties.provisioningState" --subscriptions $sub --first 1 -o json 2>$null
                $result['clData'] = if ($clRaw) { $clRaw } else { '{"data":[]}' }

                # Extensions
                $extRaw = az graph query -q "resources | where type == 'microsoft.azurestackhci/clusters/arcextensions' or (type == 'microsoft.kubernetesconfiguration/extensions' and resourceGroup =~ '$rg') | where subscriptionId == '$sub' | project name, type, properties.provisioningState, properties.extensionType" --subscriptions $sub --first 50 -o json 2>$null
                $result['extData'] = if ($extRaw) { $extRaw } else { '{"data":[]}' }

                # Logical Networks
                $lnetRaw = az graph query -q "resources | where type == 'microsoft.azurestackhci/logicalnetworks' | where resourceGroup =~ '$rg' | where subscriptionId == '$sub' | project name, properties.provisioningState, properties.subnets" --subscriptions $sub --first 20 -o json 2>$null
                $result['lnetData'] = if ($lnetRaw) { $lnetRaw } else { '{"data":[]}' }

                # AKS clusters in this RG
                $aksRaw = az graph query -q "resources | where type == 'microsoft.kubernetes/connectedclusters' | where resourceGroup =~ '$rg' | where subscriptionId == '$sub' | project name, properties.provisioningState" --subscriptions $sub --first 50 -o json 2>$null
                $result['aksData'] = if ($aksRaw) { $aksRaw } else { '{"data":[]}' }

                return $result
            } -ArgumentList $rg, $sub, $clId
            # Throttle - wait if too many jobs running
            while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $ThrottleLimit) {
                $completed = $jobs | Where-Object { $_.State -eq 'Completed' } | Select-Object -First 1
                if ($completed) { break }
                Start-Sleep -Milliseconds 200
            }
        }
        # Wait for all jobs
        $jobs | Wait-Job | Out-Null
        $jobResults = $jobs | ForEach-Object { Receive-Job $_ }
        $jobs | Remove-Job -Force

        for ($i = 0; $i -lt $clusters.Count; $i++) {
            $clusterAssessments += @{ Cluster = $clusters[$i]; Data = $jobResults[$i] }
        }
    } else {
        # Sequential collection
        foreach ($cl in $clusters) {
            $rg = $cl.resourceGroup
            $sub = $cl.subscriptionId
            $data = @{}

            $arbRaw = az graph query -q "resources | where type == 'microsoft.resourcebridge/appliances' | where resourceGroup =~ '$rg' | where subscriptionId == '$sub' | project name, properties.status, properties.provisioningState" --subscriptions $sub --first 1 -o json 2>$null
            $data['arbData'] = if ($arbRaw) { $arbRaw } else { '{"data":[]}' }

            $clRaw = az graph query -q "resources | where type == 'microsoft.extendedlocation/customlocations' | where resourceGroup =~ '$rg' | where subscriptionId == '$sub' | project name, properties.provisioningState" --subscriptions $sub --first 1 -o json 2>$null
            $data['clData'] = if ($clRaw) { $clRaw } else { '{"data":[]}' }

            $extRaw = az graph query -q "resources | where type == 'microsoft.azurestackhci/clusters/arcextensions' or (type == 'microsoft.kubernetesconfiguration/extensions' and resourceGroup =~ '$rg') | where subscriptionId == '$sub' | project name, type, properties.provisioningState, properties.extensionType" --subscriptions $sub --first 50 -o json 2>$null
            $data['extData'] = if ($extRaw) { $extRaw } else { '{"data":[]}' }

            $lnetRaw = az graph query -q "resources | where type == 'microsoft.azurestackhci/logicalnetworks' | where resourceGroup =~ '$rg' | where subscriptionId == '$sub' | project name, properties.provisioningState, properties.subnets" --subscriptions $sub --first 20 -o json 2>$null
            $data['lnetData'] = if ($lnetRaw) { $lnetRaw } else { '{"data":[]}' }

            $aksRaw = az graph query -q "resources | where type == 'microsoft.kubernetes/connectedclusters' | where resourceGroup =~ '$rg' | where subscriptionId == '$sub' | project name, properties.provisioningState" --subscriptions $sub --first 50 -o json 2>$null
            $data['aksData'] = if ($aksRaw) { $aksRaw } else { '{"data":[]}' }

            $clusterAssessments += @{ Cluster = $cl; Data = $data }
        }
    }

    # Process assessment results
    foreach ($assessment in $clusterAssessments) {
        $cl = $assessment.Cluster
        $data = $assessment.Data
        $clName = $cl.name
        $connStatus = $cl.properties_connectivityStatus
        if (-not $connStatus) { $connStatus = $cl.'properties.connectivityStatus' }
        $provState = $cl.properties_provisioningState
        if (-not $provState) { $provState = $cl.'properties.provisioningState' }

        Write-Host "  Checking: $clName..." -NoNewline

        $clusterOk = ($connStatus -eq 'Connected') -and ($provState -eq 'Succeeded')

        # ARB
        $arbData = ($data['arbData'] | ConvertFrom-Json).data
        $arbOk = $false
        $arbStatus = 'NotFound'
        if ($arbData -and $arbData.Count -gt 0) {
            $arbStatus = $arbData[0].'properties.status'
            if (-not $arbStatus) { $arbStatus = $arbData[0].properties_status }
            $arbOk = ($arbStatus -eq 'Running')
        }

        # Custom Location
        $clData = ($data['clData'] | ConvertFrom-Json).data
        $clOk = $false
        if ($clData -and $clData.Count -gt 0) {
            $clProv = $clData[0].'properties.provisioningState'
            if (-not $clProv) { $clProv = $clData[0].properties_provisioningState }
            $clOk = ($clProv -eq 'Succeeded')
        }

        # Extensions
        $extDataParsed = ($data['extData'] | ConvertFrom-Json).data
        $extTotal = if ($extDataParsed) { $extDataParsed.Count } else { 0 }
        $extFailed = 0
        $failedExtNames = @()
        if ($extDataParsed) {
            foreach ($ext in $extDataParsed) {
                $extProv = $ext.'properties.provisioningState'
                if (-not $extProv) { $extProv = $ext.properties_provisioningState }
                if ($extProv -and $extProv -ne 'Succeeded') {
                    $extFailed++
                    $failedExtNames += $ext.name
                }
            }
        }
        $extOk = ($extFailed -eq 0)

        # Logical Networks
        $lnetDataParsed = ($data['lnetData'] | ConvertFrom-Json).data
        $lnetTotal = if ($lnetDataParsed) { $lnetDataParsed.Count } else { 0 }
        $lnetFailed = 0
        if ($lnetDataParsed) {
            foreach ($lnet in $lnetDataParsed) {
                $lnetProv = $lnet.'properties.provisioningState'
                if (-not $lnetProv) { $lnetProv = $lnet.properties_provisioningState }
                if ($lnetProv -and $lnetProv -ne 'Succeeded') { $lnetFailed++ }
            }
        }
        $lnetOk = ($lnetTotal -gt 0 -and $lnetFailed -eq 0)

        # AKS Clusters in this RG
        $aksDataParsed = ($data['aksData'] | ConvertFrom-Json).data
        $aksClusterCount = if ($aksDataParsed) { $aksDataParsed.Count } else { 0 }

        # Determine warnings
        $warnings = @()
        if (-not $extOk) { $warnings += "Extensions: $extFailed failed ($($failedExtNames -join ', '))" }
        if ($lnetTotal -eq 0) { $warnings += 'No logical networks found' }
        if ($lnetFailed -gt 0) { $warnings += "$lnetFailed logical network(s) not in Succeeded state" }

        $overallReady = $clusterOk -and $arbOk -and $clOk
        $hasWarnings = $warnings.Count -gt 0
        $statusText = if (-not $overallReady) { 'NotReady' } elseif ($hasWarnings) { 'Warning' } else { 'Ready' }
        $icon = if (-not $overallReady) { ' NotReady' } elseif ($hasWarnings) { ' Warning' } else { ' Ready' }
        $iconColor = if (-not $overallReady) { 'Red' } elseif ($hasWarnings) { 'Yellow' } else { 'Green' }
        Write-Host " $icon" -ForegroundColor $iconColor
        Write-Host "    Cluster: $connStatus/$provState | ARB: $arbStatus | CustomLoc: $(if ($clOk) {'OK'} else {'Missing'}) | Ext: $extTotal($extFailed failed) | LNETs: $lnetTotal | AKS: $aksClusterCount" -ForegroundColor DarkGray
        if ($warnings.Count -gt 0) {
            foreach ($w in $warnings) { Write-Host "    WARN: $w" -ForegroundColor Yellow }
        }

        $results += [PSCustomObject]@{
            ClusterName        = $clName
            ResourceGroup      = $cl.resourceGroup
            SubscriptionId     = $cl.subscriptionId
            Region             = $cl.location
            ClusterConnected   = ($connStatus -eq 'Connected')
            ClusterProvisioned = ($provState -eq 'Succeeded')
            ARBStatus          = $arbStatus
            ARBHealthy         = $arbOk
            CustomLocationOk   = $clOk
            ExtensionTotal     = $extTotal
            ExtensionFailed    = $extFailed
            FailedExtensions   = ($failedExtNames -join ', ')
            LogicalNetworks    = $lnetTotal
            LogicalNetworkOk   = $lnetOk
            AksClusterCount    = $aksClusterCount
            Warnings           = ($warnings -join '; ')
            ReadyForAksArc     = $overallReady
            Status             = $statusText
        }
    }

    # Summary
    Write-Host ''
    Write-Log '========================================' -Level Header
    Write-Log 'Fleet Summary' -Level Header
    Write-Log '========================================' -Level Header

    $totalCount = $results.Count
    $ready = @($results | Where-Object { $_.Status -eq 'Ready' }).Count
    $warning = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
    $notReady = @($results | Where-Object { $_.Status -eq 'NotReady' }).Count

    Write-Log "Total Clusters:  $totalCount" -Level Info
    Write-Log "Ready:           $ready" -Level Success
    Write-Log "Warning:         $warning" -Level $(if ($warning -gt 0) { 'Warning' } else { 'Info' })
    Write-Log "Not Ready:       $notReady" -Level $(if ($notReady -gt 0) { 'Error' } else { 'Info' })

    # Health gate thresholds
    if ($totalCount -gt 0) {
        $readyPct = [math]::Round(($ready + $warning) / $totalCount * 100, 1)
        $warningPct = [math]::Round($warning / $totalCount * 100, 1)
        Write-Log "Ready+Warning:   ${readyPct}% (threshold: >= ${MinReadyPercent}%)" -Level Info
        Write-Log "Warning only:    ${warningPct}% (threshold: <= ${MaxWarningPercent}%)" -Level Info

        if ($readyPct -lt $MinReadyPercent) {
            Write-Log "FLEET GATE FAILED: ${readyPct}% ready, minimum is ${MinReadyPercent}%" -Level Error
        } elseif ($warningPct -gt $MaxWarningPercent) {
            Write-Log "FLEET GATE WARNING: ${warningPct}% with warnings, maximum is ${MaxWarningPercent}%" -Level Warning
        } else {
            Write-Log "FLEET GATE PASSED: ${readyPct}% ready, ${warningPct}% warnings" -Level Success
        }
    }

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

# =============================================================================
# TIER 4: HTML REPORTING
# =============================================================================

function New-AksArcReadinessReport {
    <#
    .SYNOPSIS
        Generates a self-contained HTML readiness report.

    .DESCRIPTION
        Produces a styled HTML report from single-site readiness results, fleet results,
        or deployment plan data. The report includes executive summary cards, per-gate
        details, remediation items, and optional fleet/IP capacity sections.

    .PARAMETER Results
        Readiness results from Test-AksArcDeploymentReadiness -PassThru.

    .PARAMETER FleetResults
        Fleet results from Test-AksArcFleetReadiness -PassThru.

    .PARAMETER DeploymentPlan
        Deployment plan from New-AksArcDeploymentPlan.

    .PARAMETER Context
        Context from Initialize-AksArcValidation for metadata.

    .PARAMETER Title
        Report title (default: 'AKS Arc Deployment Readiness Report').

    .PARAMETER OutputPath
        Path for the HTML output file. Required.

    .PARAMETER PassThru
        Return HTML string to the pipeline.

    .EXAMPLE
        $ctx = Initialize-AksArcValidation -ManagementNetwork 'mgmt' -AksNetwork 'aks'
        $results = Test-AksArcDeploymentReadiness -Context $ctx -PassThru
        New-AksArcReadinessReport -Results $results -Context $ctx -OutputPath report.html

    .EXAMPLE
        $fleet = Test-AksArcFleetReadiness -ScopeByTag -TagValue 'Prod' -PassThru
        New-AksArcReadinessReport -FleetResults $fleet -OutputPath fleet-report.html
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$Results,
        [PSCustomObject[]]$FleetResults,
        [PSCustomObject]$DeploymentPlan,
        [PSCustomObject]$Context,
        [string]$Title = 'AKS Arc Deployment Readiness Report',
        [Parameter(Mandatory)]
        [string]$OutputPath,
        [switch]$PassThru
    )

    Write-Log 'Generating HTML readiness report...' -Level Info

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC'
    $clusterName = if ($Context) { $Context.ClusterName } else { 'Fleet Assessment' }

    # Count statuses
    $passed = 0; $failed = 0; $warnings = 0; $skipped = 0
    if ($Results) {
        $passed = @($Results | Where-Object { $_.Status -eq 'Passed' }).Count
        $failed = @($Results | Where-Object { $_.Status -eq 'Failed' }).Count
        $warnings = @($Results | Where-Object { $_.Status -eq 'Warning' }).Count
        $skipped = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count
    }

    $fleetReady = 0; $fleetWarning = 0; $fleetNotReady = 0
    if ($FleetResults) {
        $fleetReady = @($FleetResults | Where-Object { $_.Status -eq 'Ready' }).Count
        $fleetWarning = @($FleetResults | Where-Object { $_.Status -eq 'Warning' }).Count
        $fleetNotReady = @($FleetResults | Where-Object { $_.Status -eq 'NotReady' }).Count
    }

    $overallStatus = if ($failed -gt 0 -or $fleetNotReady -gt 0) { 'NOT READY' } elseif ($warnings -gt 0 -or $fleetWarning -gt 0) { 'READY WITH WARNINGS' } else { 'READY' }
    $statusColor = if ($overallStatus -eq 'NOT READY') { '#e74c3c' } elseif ($overallStatus -like '*WARNING*') { '#f39c12' } else { '#27ae60' }

    # Build HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$Title</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif; background: #f5f6fa; color: #2c3e50; line-height: 1.6; }
  .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
  .header { background: linear-gradient(135deg, #0078d4 0%, #005a9e 100%); color: white; padding: 30px; border-radius: 8px; margin-bottom: 20px; }
  .header h1 { font-size: 24px; margin-bottom: 5px; }
  .header .meta { font-size: 13px; opacity: 0.9; }
  .status-banner { text-align: center; padding: 15px; border-radius: 8px; margin-bottom: 20px; color: white; font-size: 20px; font-weight: 600; background: $statusColor; }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 15px; margin-bottom: 20px; }
  .card { background: white; border-radius: 8px; padding: 20px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
  .card .number { font-size: 36px; font-weight: 700; }
  .card .label { font-size: 13px; color: #7f8c8d; text-transform: uppercase; letter-spacing: 1px; }
  .card.passed .number { color: #27ae60; }
  .card.failed .number { color: #e74c3c; }
  .card.warning .number { color: #f39c12; }
  .card.skipped .number { color: #95a5a6; }
  .card.info .number { color: #0078d4; }
  .section { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
  .section h2 { font-size: 18px; margin-bottom: 15px; color: #0078d4; border-bottom: 2px solid #0078d4; padding-bottom: 8px; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  th { background: #f8f9fa; text-align: left; padding: 10px 12px; font-weight: 600; border-bottom: 2px solid #dee2e6; }
  td { padding: 8px 12px; border-bottom: 1px solid #eee; }
  tr:hover { background: #f8f9fa; }
  .status-badge { display: inline-block; padding: 3px 10px; border-radius: 12px; font-size: 12px; font-weight: 600; }
  .status-passed { background: #d4edda; color: #155724; }
  .status-failed { background: #f8d7da; color: #721c24; }
  .status-warning { background: #fff3cd; color: #856404; }
  .status-skipped { background: #e2e3e5; color: #383d41; }
  .remediation { background: #fff8f0; border-left: 4px solid #e74c3c; padding: 12px 15px; margin: 5px 0; border-radius: 0 4px 4px 0; font-size: 13px; }
  .remediation strong { color: #e74c3c; }
  .ip-table td:nth-child(n+2) { text-align: right; }
  .ip-table th:nth-child(n+2) { text-align: right; }
  .footer { text-align: center; color: #95a5a6; font-size: 12px; padding: 20px; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>$Title</h1>
    <div class="meta">Cluster: $clusterName | Generated: $timestamp | Module: AksArc.DeploymentReadiness v0.5.0</div>
  </div>
  <div class="status-banner">$overallStatus</div>
"@

    # Summary cards
    if ($Results) {
        $html += @"
  <div class="cards">
    <div class="card passed"><div class="number">$passed</div><div class="label">Passed</div></div>
    <div class="card failed"><div class="number">$failed</div><div class="label">Failed</div></div>
    <div class="card warning"><div class="number">$warnings</div><div class="label">Warnings</div></div>
    <div class="card skipped"><div class="number">$skipped</div><div class="label">Skipped</div></div>
  </div>
"@
    }

    if ($FleetResults) {
        $fleetTotal = $FleetResults.Count
        $html += @"
  <div class="cards">
    <div class="card info"><div class="number">$fleetTotal</div><div class="label">Clusters</div></div>
    <div class="card passed"><div class="number">$fleetReady</div><div class="label">Ready</div></div>
    <div class="card warning"><div class="number">$fleetWarning</div><div class="label">Warning</div></div>
    <div class="card failed"><div class="number">$fleetNotReady</div><div class="label">Not Ready</div></div>
  </div>
"@
    }

    # Deployment plan section
    if ($DeploymentPlan) {
        $html += @"
  <div class="section">
    <h2>IP Capacity Analysis</h2>
    <table class="ip-table">
      <tr><th>Metric</th><th>Value</th></tr>
      <tr><td>Planned Clusters</td><td>$($DeploymentPlan.PlannedClusters)</td></tr>
      <tr><td>Control Plane Nodes (per cluster)</td><td>$($DeploymentPlan.ControlPlaneNodes)</td></tr>
      <tr><td>Worker Nodes (per cluster)</td><td>$($DeploymentPlan.WorkerNodes)</td></tr>
      <tr><td>Node VMs (total)</td><td>$($DeploymentPlan.TotalNodeVMs)</td></tr>
      <tr><td>Rolling Upgrade IPs</td><td>$($DeploymentPlan.TotalUpgradeIPs)</td></tr>
      <tr><td>Control Plane IPs (KubeVIP)</td><td>$($DeploymentPlan.TotalControlPlaneIPs)</td></tr>
"@
        if ($DeploymentPlan.AutoScaleHeadroom -gt 0) {
            $html += "      <tr><td>Autoscale Headroom</td><td>$($DeploymentPlan.AutoScaleHeadroom)</td></tr>`n"
        }
        $html += @"
      <tr style="font-weight:600;background:#f0f7ff;"><td>IP Pool Required</td><td>$($DeploymentPlan.TotalRequiredIPs)</td></tr>
      <tr><td>Load Balancer IPs (outside pool)</td><td>$($DeploymentPlan.LoadBalancerIPs)</td></tr>
      <tr style="font-weight:600;background:#f0f7ff;"><td>Total IPs in Subnet</td><td>$($DeploymentPlan.TotalWithLoadBalancer)</td></tr>
    </table>
  </div>
"@
    }

    # Gate results detail
    if ($Results) {
        # Group by gate
        $gates = $Results | Group-Object -Property Gate
        $html += @"
  <div class="section">
    <h2>Gate Results</h2>
    <table>
      <tr><th>Gate</th><th>Check</th><th>Status</th><th>Details</th></tr>
"@
        foreach ($result in $Results) {
            $badgeClass = switch ($result.Status) {
                'Passed'  { 'status-passed' }
                'Failed'  { 'status-failed' }
                'Warning' { 'status-warning' }
                'Skipped' { 'status-skipped' }
                default   { 'status-skipped' }
            }
            $msgHtml = [System.Net.WebUtility]::HtmlEncode($result.Message)
            $html += "      <tr><td>$($result.Gate)</td><td>$($result.Check)</td><td><span class=`"status-badge $badgeClass`">$($result.Status)</span></td><td>$msgHtml</td></tr>`n"
        }
        $html += "    </table>`n  </div>`n"

        # Remediation items
        $remediations = @($Results | Where-Object { $_.Status -eq 'Failed' -and $_.Remediation })
        if ($remediations.Count -gt 0) {
            $html += "  <div class=`"section`">`n    <h2>Remediation Actions</h2>`n"
            foreach ($r in $remediations) {
                $remHtml = [System.Net.WebUtility]::HtmlEncode($r.Remediation)
                $html += "    <div class=`"remediation`"><strong>$($r.Gate) / $($r.Check):</strong> $remHtml</div>`n"
            }
            $html += "  </div>`n"
        }
    }

    # Fleet detail table
    if ($FleetResults) {
        $html += @"
  <div class="section">
    <h2>Fleet Cluster Status</h2>
    <table>
      <tr><th>Cluster</th><th>Resource Group</th><th>Region</th><th>Connected</th><th>ARB</th><th>Custom Loc</th><th>Extensions</th><th>LNETs</th><th>AKS Clusters</th><th>Status</th></tr>
"@
        foreach ($fc in $FleetResults) {
            $badgeClass = switch ($fc.Status) {
                'Ready'    { 'status-passed' }
                'Warning'  { 'status-warning' }
                'NotReady' { 'status-failed' }
                default    { 'status-skipped' }
            }
            $connIcon = if ($fc.ClusterConnected) { '&#10003;' } else { '&#10007;' }
            $arbIcon = if ($fc.ARBHealthy) { '&#10003;' } else { '&#10007;' }
            $clIcon = if ($fc.CustomLocationOk) { '&#10003;' } else { '&#10007;' }
            $extText = "$($fc.ExtensionTotal)"
            if ($fc.ExtensionFailed -gt 0) { $extText += " ($($fc.ExtensionFailed) failed)" }
            $html += "      <tr><td>$($fc.ClusterName)</td><td>$($fc.ResourceGroup)</td><td>$($fc.Region)</td><td>$connIcon</td><td>$arbIcon</td><td>$clIcon</td><td>$extText</td><td>$($fc.LogicalNetworks)</td><td>$($fc.AksClusterCount)</td><td><span class=`"status-badge $badgeClass`">$($fc.Status)</span></td></tr>`n"
        }
        $html += "    </table>`n  </div>`n"
    }

    # Footer
    $html += @"
  <div class="footer">
    Generated by AksArc.DeploymentReadiness v0.5.0 | <a href="https://github.com/smitzlroy/AksArc.DeploymentReadiness">GitHub</a> | MIT License
  </div>
</div>
</body>
</html>
"@

    # Write file
    $html | Out-File -FilePath $OutputPath -Encoding utf8 -Force
    Write-Log "HTML report saved to: $OutputPath" -Level Success

    if ($PassThru) { return $html }
}
