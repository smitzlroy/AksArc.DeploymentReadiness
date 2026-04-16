# AksArc.DeploymentReadiness

<p align="center">
  <strong>Stop discovering AKS Arc deployment problems 45 minutes into the deploy</strong><br/>
  <em>Pre-flight validation: 8 readiness gates &bull; 86 firewall endpoints &bull; IP capacity math &bull; cross-VLAN port tests &bull; RBAC checks &bull; fleet scale</em>
</p>

<p align="center">
  <a href="https://www.powershellgallery.com/packages/AksArc.DeploymentReadiness"><img src="https://img.shields.io/powershellgallery/v/AksArc.DeploymentReadiness?label=PSGallery&color=blue" alt="PSGallery"></a>
  <a href="https://www.powershellgallery.com/packages/AksArc.DeploymentReadiness"><img src="https://img.shields.io/powershellgallery/dt/AksArc.DeploymentReadiness?color=green" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/smitzlroy/AksArc.DeploymentReadiness" alt="License"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> &bull;
  <a href="#function-reference">Function Reference</a> &bull;
  <a href="#examples">Examples</a> &bull;
  <a href="#endpoint-reference">Endpoints</a> &bull;
  <a href="#cicd-integration">CI/CD</a> &bull;
  <a href="#troubleshooting">Troubleshooting</a>
</p>

---

## Why does this exist?

Deploying AKS Arc on Azure Local fails for preventable reasons. The top causes:

1. **Not enough IPs** — You need 1 IP per node VM + 1 rolling upgrade IP + 1 control plane IP *per cluster*, plus load balancer IPs in the same subnet but outside the pool. Nobody does this math correctly the first time.
2. **Firewall blocking endpoints** — AKS Arc needs 86 endpoints open across 15 Azure components. Your security team will ask "which ones?" and the answer is scattered across 4 different Microsoft docs pages.
3. **DNS doesn't work on the logical network** — The LNET has DNS servers configured in Azure, but those servers can't actually resolve `mcr.microsoft.com` from the AKS subnet.
4. **Cross-VLAN ports closed** — Ports 22, 6443, 55000, 65000 need to be open between management and AKS subnets. Nobody tests these until deployment fails.
5. **Wrong RBAC role** — You discover you're missing `Microsoft.HybridContainerService/provisionedClusterInstances/write` midway through a 45-minute deployment.
6. **DHCP instead of static** — AKS Arc requires static IP allocation. Your LNET was created with the default.

This module catches all of these **before** you start deploying.

---

## What does it do?

**8 readiness gates** that validate everything AKS Arc needs:

| Gate | What it catches |
|:---|:---|
| 1 — Cluster Health | Azure Local cluster offline or failed provisioning |
| 2 — Arc Resource Bridge | ARB not running (prerequisite for all AKS Arc operations) |
| 3 — Custom Location | Missing custom location (required to place AKS clusters) |
| 4 — Network Connectivity | 86 endpoints unreachable from the node (firewall/proxy issues) |
| 5 — Logical Networks | Insufficient IPs, DHCP instead of static, broken DNS servers, missing gateway, no VLAN separation |
| 6 — Cross-Subnet Ports | Documents the 7 ports that must be open between VLANs |
| 7 — Active Port Testing | Real TCP tests on cross-VLAN ports when you provide target IPs |
| 8 — RBAC Permissions | Missing deployment permissions on the logged-in identity |

**Plus:**
- **IP capacity calculator** — Tell it "2 clusters × 5 workers with autoscale to 10" and it calculates exactly how many IPs you need from the pool and in the subnet
- **Firewall rule export** — Gives your security team a ready-to-submit CSV/Markdown with all 86 endpoints + 7 cross-subnet ports
- **Fleet assessment** — Validate 50+ clusters in parallel via Azure Resource Graph with configurable health thresholds
- **HTML reports** — Self-contained readiness report you can attach to a change request or email to your team
- **CI/CD ready** — JUnit XML export for Azure DevOps and GitHub Actions pipelines

> [!NOTE]
> **Community tool** — MIT License. Not a Microsoft-supported product. Designed by people who deploy AKS Arc and got tired of discovering problems 45 minutes into a deployment.

---

## Requirements

| Requirement | Minimum Version | Notes |
|:---|:---|:---|
| **PowerShell** | 5.1 or 7+ | Server Core and Desktop both supported |
| **Azure CLI** | 2.60+ | [Install guide](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| **Az CLI Extensions** | `stack-hci-vm`, `connectedk8s` | Auto-installed by the module if missing |
| **Permissions** | Reader | On the resource group containing the Azure Local cluster |

---

## Installation

**From PowerShell Gallery:**
```powershell
Install-Module AksArc.DeploymentReadiness -Scope CurrentUser
```

**From source:**
```powershell
git clone https://github.com/smitzlroy/AksArc.DeploymentReadiness.git
Import-Module ./AksArc.DeploymentReadiness/AksArc.DeploymentReadiness.psd1
```

---

## Quick Start

### "Will my deployment work?" (run from an Azure Local node)

```powershell
Import-Module AksArc.DeploymentReadiness

# 1. Auto-discover your cluster infrastructure
$ctx = Initialize-AksArcValidation -ManagementNetwork 'mgmt-lnet' -AksNetwork 'aks-lnet'

# 2. Tell it what you plan to deploy
$plan = New-AksArcDeploymentPlan -PlannedClusters 2 -WorkerNodes 5 -LoadBalancerIPs 3

# 3. Get a pass/fail answer with specific fix guidance for every failure
Test-AksArcDeploymentReadiness -Context $ctx -DeploymentPlan $plan -ExportPath readiness-results.xml
```

### "I need the firewall rules for a change request"

```powershell
# One command — ready to paste into ServiceNow or email to your security team
Export-AksArcFirewallRules -Path firewall-request.csv -Region eastus -IncludeCrossSubnetPorts
```

### "I want the full picture" (all 8 gates including port tests and RBAC)

```powershell
$ctx = Initialize-AksArcValidation -ManagementNetwork 'mgmt-lnet' -AksNetwork 'aks-lnet' `
    -AksSubnetTestIP '10.0.2.10' -ClusterIP '10.0.1.5'

$plan = New-AksArcDeploymentPlan -PlannedClusters 2 -WorkerNodes 5 -LoadBalancerIPs 3
$results = Test-AksArcDeploymentReadiness -Context $ctx -DeploymentPlan $plan -PassThru

# Generate an HTML report to attach to your change request
New-AksArcReadinessReport -Results $results -DeploymentPlan $plan -Context $ctx -OutputPath readiness.html
```

### "How many IPs do I actually need?"

```powershell
# Just calculate — no cluster connection required
$plan = New-AksArcDeploymentPlan -PlannedClusters 3 -WorkerNodes 8 `
    -EnableAutoScale -MaxAutoScaleNodes 15 -LoadBalancerIPs 10
# Output: "Need 47 IPs in pool + 10 LB IPs = 57 IPs in subnet"
```

### "Are all 50 of my sites ready?" (run from any workstation)

```powershell
Connect-AksArcServicePrincipal -UseManagedIdentity
Test-AksArcFleetReadiness -ScopeByTag -TagName 'ReadinessRing' -TagValue 'Wave1' `
    -MinReadyPercent 90 -ExportPath fleet.xml
```

### Quick structural check (no deployment plan)

```powershell
# Still works without a plan — validates structure only, no IP capacity math
$ctx = Initialize-AksArcValidation -ManagementNetwork 'mgmt-lnet' -AksNetwork 'aks-lnet'
Test-AksArcDeploymentReadiness -Context $ctx -ExportPath readiness-results.xml
```

---

## Function Reference

### Tier 1 — Single-Site Readiness

#### `Initialize-AksArcValidation`

Auto-discovers the Azure Local cluster, Arc Resource Bridge, custom location, and logical networks. Returns a context object consumed by other functions.

```powershell
Initialize-AksArcValidation
    [-SubscriptionId <string>]
    [-ResourceGroupName <string>]
    [-ClusterName <string>]
    [-ManagementNetwork <string>]
    [-AksNetwork <string>]
    [-ManagementIPs <string[]>]
    [-AksSubnetTestIP <string>]
    [-ClusterIP <string>]
```

| Parameter | Description |
|:---|:---|
| `-SubscriptionId` | Azure subscription ID. Defaults to current `az account show`. |
| `-ResourceGroupName` | Resource group containing the Azure Local cluster. Auto-detected if omitted. |
| `-ClusterName` | Cluster name. Auto-detected via `az stack-hci cluster list` if omitted. |
| `-ManagementNetwork` | Name of the logical network used for management traffic. If omitted, discovered LNETs are listed so you can identify them. |
| `-AksNetwork` | Name of the logical network used for AKS workloads. If omitted, discovered LNETs are listed so you can identify them. |
| `-ManagementIPs` | IP addresses on the management subnet (e.g., ARB IP, cluster IP) for active cross-VLAN port testing. |
| `-AksSubnetTestIP` | An IP on the AKS subnet to test connectivity to (for Gate 7 active port tests on ports 22/443/6443/9440). |
| `-ClusterIP` | Azure Local cluster IP for testing ports 55000/65000 (gRPC/Auth from AKS subnet to cluster). |

**Output:** A context object containing cluster metadata, ARB status, custom location, LNET details, and `HostType` — passed to `Test-AksArcDeploymentReadiness` via `-Context`.

> [!NOTE]
> **On-node detection (v0.3.0):** The module detects whether it's running on an Azure Local node or a remote workstation. If running remotely, a warning is emitted because network connectivity tests (Gate 4) validate from the *current machine*, not from the Azure Local nodes where firewall rules actually matter. For accurate firewall validation, run this module from an Azure Local node.

---

#### `New-AksArcDeploymentPlan`

Creates a deployment plan that calculates IP address requirements for your planned AKS Arc deployment. The plan object feeds into `Test-AksArcDeploymentReadiness` to validate that your logical network IP pools have enough capacity.

```powershell
New-AksArcDeploymentPlan
    [-PlannedClusters <int>]       # Default: 1
    [-ControlPlaneNodes <int>]     # 1 or 3 (default: 3)
    [-WorkerNodes <int>]           # Default: 3
    [-LoadBalancerIPs <int>]       # Default: 0
    [-EnableAutoScale]             # Add headroom for autoscaler
    [-MaxAutoScaleNodes <int>]     # Max workers when autoscaling
    [-AksNetworkName <string>]     # LNET name for AKS traffic
    [-ManagementNetworkName <string>] # LNET name for management
    [-Context <object>]            # From Initialize-AksArcValidation
```

| Parameter | Description |
|:---|:---|
| `-PlannedClusters` | Number of AKS Arc clusters to deploy. Default: 1. |
| `-ControlPlaneNodes` | Control plane nodes per cluster (1 or 3). Default: 3. |
| `-WorkerNodes` | Worker nodes per cluster. Default: 3. |
| `-LoadBalancerIPs` | IPs for MetalLB / load balancer services. These must be in the same subnet but *outside* the IP pool. Default: 0. |
| `-EnableAutoScale` | Include headroom IPs for node autoscaler. Requires `-MaxAutoScaleNodes`. |
| `-MaxAutoScaleNodes` | Maximum worker nodes per cluster when autoscaling. |
| `-AksNetworkName` | Logical network name for AKS workloads. |
| `-ManagementNetworkName` | Logical network name for management traffic. |
| `-Context` | Context from `Initialize-AksArcValidation`. |

**IP Calculation Formula:**

```
Total IP pool required = (ControlPlaneNodes + WorkerNodes) × PlannedClusters
                       + PlannedClusters  (1 rolling upgrade IP per cluster)
                       + PlannedClusters  (1 control plane / KubeVIP per cluster)
                       + AutoscaleHeadroom (if enabled)

Load balancer IPs      = separate, same subnet but OUTSIDE the IP pool
Total IPs in subnet    = IP pool required + LoadBalancerIPs
```

**Example:**

```powershell
# 2 clusters × (3 CP + 5 workers) + 2 upgrade + 2 CP + 3 LB = 23 IPs in subnet
$plan = New-AksArcDeploymentPlan -PlannedClusters 2 -WorkerNodes 5 -LoadBalancerIPs 3

# With autoscale: adds headroom for max 10 workers per cluster
$plan = New-AksArcDeploymentPlan -PlannedClusters 1 -WorkerNodes 3 \
    -EnableAutoScale -MaxAutoScaleNodes 10 -LoadBalancerIPs 5
```

> [!TIP]
> **Interactive mode:** If you omit parameters when running interactively, the module prompts you with sensible defaults. In CI/CD pipelines (non-interactive), defaults are used silently.

---

#### `Test-AksArcDeploymentReadiness`

Runs **8 readiness gates** and reports pass/fail with remediation guidance:

| Gate | What it checks |
|:---|:---|
| 1 — Cluster Health | Azure Local cluster provisioning state and connectivity |
| 2 — Arc Resource Bridge | ARB provisioning state and running status |
| 3 — Custom Location | Custom location exists and is provisioned |
| 4 — Network Connectivity | TCP/DNS reachability to all 86 required endpoints |
| 5 — Logical Networks | **Deep validation**: IP pool capacity vs. deployment plan, DNS server resolution, gateway config, static IP enforcement, VLAN separation |
| 6 — Cross-Subnet Ports | Port requirements between management and AKS subnets (informational) |
| 7 — Active Port Testing | **Real TCP tests** on cross-VLAN ports when target IPs are provided via `-AksSubnetTestIP` / `-ClusterIP` |
| 8 — RBAC Permissions | Validates the logged-in identity has sufficient Azure RBAC roles for AKS Arc deployment |

```powershell
Test-AksArcDeploymentReadiness
    -Context <object>
    [-DeploymentPlan <object>]    # From New-AksArcDeploymentPlan
    [-Region <string>]
    [-SkipNetworkTests]
    [-PassThru]
    [-ExportPath <string>]    # .csv, .json, or .xml (JUnit)
```

| Parameter | Description |
|:---|:---|
| `-Context` | **Required.** Output from `Initialize-AksArcValidation`. |
| `-DeploymentPlan` | Output from `New-AksArcDeploymentPlan`. Enables IP capacity validation in Gate 5. |
| `-Region` | Azure region for resolving region-specific endpoints (e.g., `eastus`). Strongly recommended. |
| `-SkipNetworkTests` | Skip Gate 4 (network connectivity) for faster structural-only validation. |
| `-PassThru` | Return result objects to the pipeline. |
| `-ExportPath` | Export results to `.csv`, `.json`, or `.xml` (JUnit format). |

**Gate 5 Deep Validation (v0.3.0):**

When a `-DeploymentPlan` is provided, Gate 5 performs these additional checks on the AKS logical network:

| Check | Behavior |
|:---|:---|
| IP pool exists | **Fails** if no IP pool is configured on the AKS logical network |
| IP pool capacity | **Fails** if available IPs < required IPs from deployment plan; **warns** if < 20% headroom |
| IP allocation method | **Fails** if not `Static` (DHCP is not supported for AKS Arc) |
| DNS servers | **Fails** if no DNS servers configured; tests each DNS server can resolve `mcr.microsoft.com` and `management.azure.com` |
| Gateway | **Warns** if no default gateway is configured |
| Network separation | **Warns** if management and AKS use the same logical network (best practice is separate VLANs) |
| Load balancer guidance | Informational note that MetalLB IPs must be in same subnet but outside the IP pool range |

**Gate 7 Active Port Testing (v0.4.0):**

When `-AksSubnetTestIP` and/or `-ClusterIP` are provided to `Initialize-AksArcValidation`, Gate 7 performs real TCP connectivity tests:

| Port | Direction | Tested when |
|:---|:---|:---|
| 22, 443, 6443, 9440 | Current host → AKS subnet IP | `-AksSubnetTestIP` provided |
| 55000, 65000 | Current host → Cluster IP | `-ClusterIP` provided |
| 40343 | Current host → Cluster IP | Skipped (conditional — Arc Gateway only) |

If no target IPs are provided, Gate 7 is gracefully skipped with guidance on which parameters to add.

**Gate 8 RBAC Validation (v0.4.0):**

Gate 8 checks whether the current identity (user or service principal) has the required RBAC permissions for AKS Arc deployment at the resource group scope. It recognizes these built-in roles as sufficient:

- **Owner** / **Contributor** (full access)
- **Azure Kubernetes Service Arc Contributor** (purpose-built role)

For custom roles, it drills into the specific actions and checks for: `Microsoft.Kubernetes/connectedClusters/write`, `Microsoft.ExtendedLocation/customLocations/read`, `Microsoft.AzureStackHCI/logicalNetworks/read`, `Microsoft.HybridContainerService/provisionedClusterInstances/write`.

---

#### `Test-AksArcNetworkConnectivity`

Tests TCP/HTTPS/DNS reachability to all 86 required endpoints individually.

```powershell
Test-AksArcNetworkConnectivity
    [-Component <string>]
    [-Region <string>]
    [-TimeoutMs <int>]        # Default: 5000
    [-PassThru]
    [-ExportPath <string>]
```

| Parameter | Description |
|:---|:---|
| `-Component` | Filter by component name (case-insensitive substring match). See [Component Names](#component-names). |
| `-Region` | **Strongly recommended.** Resolves region-specific endpoints. If omitted, 11 region-specific endpoints are skipped with a warning. |
| `-TimeoutMs` | TCP connection timeout in milliseconds. Default: 5000. |
| `-PassThru` | Return per-endpoint result objects to the pipeline. |
| `-ExportPath` | Export results to `.csv`, `.json`, or `.xml`. |

---

### Tier 2 — Endpoint Reference

#### `Get-AksArcEndpointReference`

Returns the full endpoint list as filterable PowerShell objects.

```powershell
Get-AksArcEndpointReference
    [-Component <string>]
    [-ArcGatewaySupported <bool>]
    [-RequiredFor <string>]        # deployment | post-deployment | both
    [-Region <string>]
    [-IncludeCrossSubnetPorts]
    [-CheckForUpdates]
```

| Parameter | Description |
|:---|:---|
| `-Component` | Case-insensitive substring filter. E.g., `'AKS'` matches `Azure Local AKS infra`. |
| `-ArcGatewaySupported` | `$true` = endpoints covered by Arc Gateway. `$false` = require direct firewall rules. |
| `-RequiredFor` | `deployment`, `post-deployment`, or `both`. |
| `-Region` | Resolves region-specific URLs in the output. |
| `-IncludeCrossSubnetPorts` | Append cross-subnet port requirements to the output. |
| `-CheckForUpdates` | Warns if the embedded endpoint data is older than 90 days. |

---

#### `Export-AksArcFirewallRules`

Exports firewall rules as `.csv`, `.json`, or `.md` for change requests.

```powershell
Export-AksArcFirewallRules
    -Path <string>                 # Required. File extension determines format.
    [-Region <string>]
    [-RequiredFor <string>]
    [-IncludeCrossSubnetPorts]
```

---

### Tier 3 — Fleet Scale

#### `Test-AksArcFleetReadiness`

Batch readiness assessment across multiple clusters via Azure Resource Graph. Checks cluster connectivity, ARB health, custom location, extension health, logical network health, and AKS cluster count. Supports parallel data collection and configurable health gate thresholds.

```powershell
Test-AksArcFleetReadiness
    [-ClusterNames <string[]>]
    [-ClusterResourceIds <string[]>]
    [-ScopeByTag]
    [-TagName <string>]            # Default: 'ReadinessRing'
    [-TagValue <string>]
    [-SubscriptionId <string>]
    [-DeploymentPlan <object>]     # From New-AksArcDeploymentPlan
    [-MinReadyPercent <int>]       # Default: 100 (0-100)
    [-MaxWarningPercent <int>]     # Default: 10 (0-100)
    [-ThrottleLimit <int>]         # Default: 4 (1-20)
    [-BatchSize <int>]             # Default: 50
    [-PassThru]
    [-ExportPath <string>]
```

| Parameter | Description |
|:---|:---|
| `-DeploymentPlan` | Deployment plan for fleet-wide IP capacity reporting. |
| `-MinReadyPercent` | Minimum % of clusters that must be Ready+Warning for fleet gate to pass. Default: 100. |
| `-MaxWarningPercent` | Maximum % of clusters with warnings before fleet gate fails. Default: 10. |
| `-ThrottleLimit` | Max parallel `Start-Job` workers for data collection. Default: 4. Increase for large fleets. |

---

#### `Get-AksArcFleetProgress`

Fleet-wide dashboard: connected vs. disconnected clusters, AKS Arc cluster count.

```powershell
Get-AksArcFleetProgress
    [-ScopeByTag]
    [-TagName <string>]
    [-TagValue <string>]
    [-SubscriptionId <string>]
    [-Detailed]
```

---

### Tier 4 — Reporting

#### `New-AksArcReadinessReport`

Generates a self-contained HTML readiness report from single-site results, fleet results, or deployment plan data.

```powershell
New-AksArcReadinessReport
    [-Results <object[]>]          # From Test-AksArcDeploymentReadiness -PassThru
    [-FleetResults <object[]>]     # From Test-AksArcFleetReadiness -PassThru
    [-DeploymentPlan <object>]     # From New-AksArcDeploymentPlan
    [-Context <object>]            # From Initialize-AksArcValidation
    [-Title <string>]              # Default: 'AKS Arc Deployment Readiness Report'
    -OutputPath <string>           # Required. Path for .html output
    [-PassThru]                    # Return HTML string
```

**Report sections:**
- Executive summary cards (Passed / Failed / Warning / Skipped)
- IP capacity analysis table (when `-DeploymentPlan` provided)
- Per-gate results with status badges
- Remediation action items (failed checks with fix guidance)
- Fleet cluster status grid (when `-FleetResults` provided)

---

### Authentication

#### `Connect-AksArcServicePrincipal`

Logs into Azure for headless/CI scenarios.

```powershell
Connect-AksArcServicePrincipal
    [-UseManagedIdentity]
    [-ManagedIdentityClientId <string>]
    [-ServicePrincipalId <string>]
    [-ServicePrincipalSecret <string>]
    [-TenantId <string>]
```

Also supports environment variables: `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`.

---

## Examples

### Network connectivity with filtering

```powershell
# Test only AKS Arc infrastructure endpoints
Test-AksArcNetworkConnectivity -Component 'AKS infra' -Region eastus

# Find endpoints that still need direct firewall rules (not covered by Arc Gateway)
Get-AksArcEndpointReference -ArcGatewaySupported $false |
    Format-Table url, port, component

# Capture failures for analysis
$failed = Test-AksArcNetworkConnectivity -Region eastus -PassThru |
    Where-Object Status -eq 'Failed'
$failed | Format-Table Url, Port, Detail
```

### Full readiness with deployment plan

```powershell
$ctx = Initialize-AksArcValidation -ClusterName 'mycluster' `
    -ManagementNetwork 'mgmt-lnet' -AksNetwork 'aks-lnet'

# Plan: 3 AKS clusters, 5 workers each, MetalLB with 5 IPs
$plan = New-AksArcDeploymentPlan -PlannedClusters 3 -WorkerNodes 5 -LoadBalancerIPs 5

# Run full validation including IP capacity check
Test-AksArcDeploymentReadiness -Context $ctx -DeploymentPlan $plan -Region eastus -ExportPath results.xml

# JSON for programmatic consumption — filter to failures only
Test-AksArcDeploymentReadiness -Context $ctx -DeploymentPlan $plan -ExportPath results.json -PassThru |
    Where-Object Status -eq 'Failed'

# WhatIf — preview what gates would run
Test-AksArcDeploymentReadiness -Context $ctx -WhatIf
```

### IP capacity planning scenarios

```powershell
# Small dev/test: 1 cluster, 1 CP node, 2 workers — needs 4 IPs from pool
New-AksArcDeploymentPlan -PlannedClusters 1 -ControlPlaneNodes 1 -WorkerNodes 2

# Production: 2 clusters, 3 CP nodes, 8 workers, autoscale to 15, 10 LB IPs
New-AksArcDeploymentPlan -PlannedClusters 2 -WorkerNodes 8 `
    -EnableAutoScale -MaxAutoScaleNodes 15 -LoadBalancerIPs 10

# Just calculate — no validation needed
$plan = New-AksArcDeploymentPlan -PlannedClusters 5 -WorkerNodes 10
Write-Host "Need $($plan.TotalRequiredIPs) IPs in pool + $($plan.LoadBalancerIPs) LB IPs"
```

### Fleet operations

```powershell
# Assess specific clusters
Test-AksArcFleetReadiness -ClusterNames @('site-east-01', 'site-west-02') -ExportPath fleet.csv

# Assess by tag with health gate threshold (80% must be ready)
Test-AksArcFleetReadiness -ScopeByTag -TagName 'Environment' -TagValue 'Production' `
    -MinReadyPercent 80 -MaxWarningPercent 15

# Fleet dashboard
Get-AksArcFleetProgress -Detailed
```

### HTML reports

```powershell
# Single-site report
$ctx = Initialize-AksArcValidation -ManagementNetwork 'mgmt' -AksNetwork 'aks'
$plan = New-AksArcDeploymentPlan -PlannedClusters 2 -WorkerNodes 5 -LoadBalancerIPs 3
$results = Test-AksArcDeploymentReadiness -Context $ctx -DeploymentPlan $plan -PassThru
New-AksArcReadinessReport -Results $results -DeploymentPlan $plan -Context $ctx -OutputPath readiness.html

# Fleet report
$fleet = Test-AksArcFleetReadiness -ScopeByTag -TagValue 'Production' -PassThru
New-AksArcReadinessReport -FleetResults $fleet -OutputPath fleet-report.html
```

### Endpoint data freshness

```powershell
# Warns if embedded endpoint data is > 90 days old
Get-AksArcEndpointReference -CheckForUpdates
```

---

## Endpoint Reference

The module ships with **86 endpoints** and **7 cross-subnet ports** embedded in [`data/endpoints.json`](data/endpoints.json), sourced from [Azure/AzureStack-Tools commit 41f99d8](https://github.com/Azure/AzureStack-Tools/blob/41f99d8c8157225201ee31f0ccf93f2110391ec7/HCI/EastUSendpoints/eastus-hci-endpoints.md).

### Component Names

Component names match upstream exactly:

| Component | Endpoints |
|:---|:---:|
| Azure Local AKS infra | 22 |
| Azure Local ARB infra | 11 |
| Azure Local Arc agent | 9 |
| Azure Local monitoring | 9 |
| Azure Local authentication | 7 |
| Azure Local CRLs | 7 |
| Azure Local deployment | 7 |
| Azure Local diag and billing | 4 |
| Azure Local Updates | 3 |
| Azure Local benefits | 2 |
| Azure Local Arc gateway | 1 |
| Azure Local management | 1 |
| Azure Local WAC | 1 |
| Microsoft Defender | 1 |
| Microsoft Update | 1 |

### Cross-Subnet Ports (Management ↔ AKS subnet)

| Port | Protocol | Purpose |
|:---|:---|:---|
| 22 | TCP | SSH node access |
| 443 | TCP | HTTPS / API communication |
| 6443 | TCP | Kubernetes API server |
| 9440 | TCP | MOC cloud agent |
| 40343 | TCP | Arc Gateway (when enabled) |
| 55000 | TCP | gRPC / Cloud Agent |
| 65000 | TCP | Cloud Agent Authentication |

### Region-Specific Endpoints

11 of the 86 endpoints are region-specific (e.g., `eastus.dp.kubernetesconfiguration.azure.com`). Provide `-Region` to resolve them correctly. Without `-Region`, these are skipped with a warning.

### Customer-Specific Endpoints

Two endpoints require customer-specific values:
- **Key Vault**: `<your-keyvault-name>.vault.azure.net` — replace with your deployment Key Vault
- **Arc Gateway**: `<your-arc-gateway-id>.gw.arc.azure.com` — replace with your Arc Gateway endpoint ID

These are flagged with `"customerSpecific": true` in the JSON and skipped during automated testing.

---

## Export Formats

| Extension | Format | Best for |
|:---|:---|:---|
| `.csv` | Comma-separated values | Firewall change requests, Excel, ServiceNow |
| `.json` | JSON | Pipeline automation, programmatic consumption |
| `.xml` | JUnit XML | Azure DevOps / GitHub Actions test reporting |
| `.md` | Markdown table | Documentation, wiki pages, email |

---

## CI/CD Integration

Ready-to-use pipeline templates are in [`Automation-Pipeline-Examples/`](Automation-Pipeline-Examples/).

### GitHub Actions

```yaml
- name: AKS Arc Readiness
  shell: pwsh
  run: |
    Install-Module AksArc.DeploymentReadiness -Force -Scope CurrentUser
    Connect-AksArcServicePrincipal -UseManagedIdentity
    Test-AksArcFleetReadiness -ScopeByTag -TagValue 'Production' -ExportPath results.xml

- name: Publish Results
  if: always()
  uses: dorny/test-reporter@v1
  with:
    name: AKS Arc Readiness
    path: results.xml
    reporter: java-junit
```

### Azure DevOps

```yaml
- task: AzureCLI@2
  inputs:
    azureSubscription: '<your-service-connection>'
    scriptType: pscore
    scriptLocation: inlineScript
    inlineScript: |
      Install-Module AksArc.DeploymentReadiness -Force -Scope CurrentUser
      Test-AksArcFleetReadiness -ExportPath $(Build.ArtifactStagingDirectory)/results.xml

- task: PublishTestResults@2
  condition: always()
  inputs:
    testResultsFormat: JUnit
    testResultsFiles: '$(Build.ArtifactStagingDirectory)/results.xml'
```

See full examples: [GitHub Actions](Automation-Pipeline-Examples/github-actions-fleet-readiness.yml) | [Azure DevOps](Automation-Pipeline-Examples/azure-devops-fleet-readiness.yml)

---

## Troubleshooting

### Module not found after Install-Module

On machines with OneDrive folder redirection, PowerShell 5.1 may not include the OneDrive-redirected Documents path in `$env:PSModulePath`. Use **PowerShell 7** (`pwsh`) or import by full path:

```powershell
Import-Module "$env:USERPROFILE\OneDrive - Microsoft\Documents\PowerShell\Modules\AksArc.DeploymentReadiness\0.5.0\AksArc.DeploymentReadiness.psd1"
```

### Region-specific endpoints skipped

If you see warnings about skipped region-specific endpoints, add `-Region`:

```powershell
Test-AksArcNetworkConnectivity -Region eastus
```

### Logical network not identified as management or AKS

Use `-ManagementNetwork` and `-AksNetwork` on `Initialize-AksArcValidation`:

```powershell
$ctx = Initialize-AksArcValidation -ManagementNetwork 'infra-lnet' -AksNetwork 'workload-lnet'
```

If you're not sure which is which, omit both parameters — the module will list all discovered LNETs with their subnet, VLAN, and IP pool details.

### Customer-specific endpoints

Endpoints for Key Vault and Arc Gateway are customer-specific placeholders. They are skipped during automated testing. To validate them, test manually:

```powershell
Test-NetConnection yourvaultname.vault.azure.net -Port 443
Test-NetConnection yourid.gw.arc.azure.com -Port 443
```

---

## Module Structure

```
AksArc.DeploymentReadiness/
├── AksArc.DeploymentReadiness.psd1          # Module manifest (v0.5.0)
├── AksArc.DeploymentReadiness.psm1          # All functions (single-file module)
├── data/
│   └── endpoints.json                       # 86 endpoints + 7 cross-subnet ports
├── Tests/
│   └── AksArc.DeploymentReadiness.Tests.ps1 # Pester test suite (69 tests)
├── Automation-Pipeline-Examples/
│   ├── github-actions-fleet-readiness.yml   # GitHub Actions workflow
│   └── azure-devops-fleet-readiness.yml     # Azure DevOps pipeline
├── CHANGELOG.md
├── LICENSE                                  # MIT
└── README.md
```

---

## Contributing

Pull requests are welcome. Before submitting:

```powershell
# Run the Pester test suite
Invoke-Pester ./Tests/ -Output Detailed

# Run PSScriptAnalyzer
Invoke-ScriptAnalyzer ./AksArc.DeploymentReadiness.psm1

# Verify import
pwsh -c "Import-Module ./AksArc.DeploymentReadiness.psd1; Get-Command -Module AksArc.DeploymentReadiness"
```

---

## License

[MIT](LICENSE)

## Acknowledgments

- Module patterns inspired by [AzStackHci.ManageUpdates](https://github.com/NeilBird/Azure-Local/tree/main/AzStackHci.ManageUpdates) by Neil Bird
- Fleet-scale patterns influenced by [AzureLocal-LENS-Workbook](https://github.com/Azure/AzureLocal-LENS-Workbook) (Azure Resource Graph queries)
- Endpoint data sourced from [Azure/AzureStack-Tools](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/EastUSendpoints/eastus-hci-endpoints.md)
- IP address planning based on [AKS Arc IP address planning requirements](https://learn.microsoft.com/en-us/azure/aks/aksarc/aks-hci-ip-address-planning)
