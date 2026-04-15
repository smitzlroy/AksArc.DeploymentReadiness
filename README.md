# AksArc.DeploymentReadiness

<p align="center">
  <strong>Pre-deployment readiness validation for AKS Arc on Azure Local</strong><br/>
  <em>v0.2.0 — 86 endpoints &bull; 7 cross-subnet ports &bull; 15 components</em>
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

## What is this?

A PowerShell module that answers: **"Is my Azure Local cluster ready for AKS Arc?"**

It validates network connectivity, endpoint reachability, cluster health, Arc Resource Bridge status, and logical network configuration — then gives you a clear pass/fail report you can hand to your team or pipe into CI/CD.

It ships with a **consolidated firewall endpoint reference** (86 endpoints + 7 cross-subnet ports) sourced from [Azure/AzureStack-Tools](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/EastUSendpoints/eastus-hci-endpoints.md) that you can export as CSV, JSON, or Markdown for your network security team.

> [!NOTE]
> This is a **community tool** distributed under the [MIT License](LICENSE). Not a Microsoft-supported product.

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

### Single-site readiness check (run from an Azure Local node)

```powershell
Import-Module AksArc.DeploymentReadiness

# Auto-discover cluster, ARB, custom location, and logical networks
# Use -ManagementNetwork / -AksNetwork to tag which LNET is which
$ctx = Initialize-AksArcValidation -ManagementNetwork 'mgmt-lnet' -AksNetwork 'aks-lnet'

# Run all 6 readiness gates — export JUnit XML for your pipeline
Test-AksArcDeploymentReadiness -Context $ctx -ExportPath readiness-results.xml
```

### Get the firewall rules for your security team

```powershell
# Markdown table (great for wiki/email)
Export-AksArcFirewallRules -Path firewall-request.md -Region eastus -IncludeCrossSubnetPorts

# CSV for Excel / ServiceNow
Export-AksArcFirewallRules -Path firewall-request.csv -Region eastus
```

### Fleet-wide assessment (run from any workstation)

```powershell
Connect-AksArcServicePrincipal -UseManagedIdentity
Test-AksArcFleetReadiness -ScopeByTag -TagName 'ReadinessRing' -TagValue 'Wave1' -ExportPath fleet.xml
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
```

| Parameter | Description |
|:---|:---|
| `-SubscriptionId` | Azure subscription ID. Defaults to current `az account show`. |
| `-ResourceGroupName` | Resource group containing the Azure Local cluster. Auto-detected if omitted. |
| `-ClusterName` | Cluster name. Auto-detected via `az stack-hci cluster list` if omitted. |
| `-ManagementNetwork` | Name of the logical network used for management traffic. If omitted, discovered LNETs are listed so you can identify them. |
| `-AksNetwork` | Name of the logical network used for AKS workloads. If omitted, discovered LNETs are listed so you can identify them. |

**Output:** A context hashtable containing cluster metadata, ARB status, custom location, and LNET details — passed to `Test-AksArcDeploymentReadiness` via `-Context`.

---

#### `Test-AksArcDeploymentReadiness`

Runs **6 readiness gates** and reports pass/fail with remediation guidance:

| Gate | What it checks |
|:---|:---|
| 1 — Cluster Health | Azure Local cluster provisioning state and connectivity |
| 2 — Arc Resource Bridge | ARB provisioning state and running status |
| 3 — Custom Location | Custom location exists and is provisioned |
| 4 — Network Connectivity | TCP/DNS reachability to all 86 required endpoints |
| 5 — Logical Networks | LNET provisioning state, subnet, VLAN, IP pool config; management vs. AKS classification |
| 6 — Cross-Subnet Ports | Port requirements between management and AKS subnets |

```powershell
Test-AksArcDeploymentReadiness
    -Context <hashtable>
    [-Region <string>]
    [-SkipNetworkTests]
    [-PassThru]
    [-ExportPath <string>]    # .csv, .json, or .xml (JUnit)
```

| Parameter | Description |
|:---|:---|
| `-Context` | **Required.** Output from `Initialize-AksArcValidation`. |
| `-Region` | Azure region for resolving region-specific endpoints (e.g., `eastus`). Strongly recommended. |
| `-SkipNetworkTests` | Skip Gate 4 (network connectivity) for faster structural-only validation. |
| `-PassThru` | Return result objects to the pipeline. |
| `-ExportPath` | Export results to `.csv`, `.json`, or `.xml` (JUnit format). |

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

Batch readiness assessment across multiple clusters via Azure Resource Graph.

```powershell
Test-AksArcFleetReadiness
    [-ClusterNames <string[]>]
    [-ClusterResourceIds <string[]>]
    [-ScopeByTag]
    [-TagName <string>]            # Default: 'ReadinessRing'
    [-TagValue <string>]
    [-SubscriptionId <string>]
    [-BatchSize <int>]             # Default: 50
    [-PassThru]
    [-ExportPath <string>]
```

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

### Full readiness with export

```powershell
$ctx = Initialize-AksArcValidation -ClusterName 'mycluster' `
    -ManagementNetwork 'mgmt-lnet' -AksNetwork 'aks-lnet'

# JUnit XML for pipeline test reporters
Test-AksArcDeploymentReadiness -Context $ctx -Region eastus -ExportPath results.xml

# JSON for programmatic consumption — filter to failures only
Test-AksArcDeploymentReadiness -Context $ctx -ExportPath results.json -PassThru |
    Where-Object Status -eq 'Failed'

# WhatIf — preview what gates would run
Test-AksArcDeploymentReadiness -Context $ctx -WhatIf
```

### Fleet operations

```powershell
# Assess specific clusters
Test-AksArcFleetReadiness -ClusterNames @('site-east-01', 'site-west-02') -ExportPath fleet.csv

# Assess by tag
Test-AksArcFleetReadiness -ScopeByTag -TagName 'Environment' -TagValue 'Production'

# Fleet dashboard
Get-AksArcFleetProgress -Detailed
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
Import-Module "$env:USERPROFILE\OneDrive - Microsoft\Documents\PowerShell\Modules\AksArc.DeploymentReadiness\0.2.0\AksArc.DeploymentReadiness.psd1"
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
├── AksArc.DeploymentReadiness.psd1          # Module manifest (v0.2.0)
├── AksArc.DeploymentReadiness.psm1          # All functions (single-file module)
├── data/
│   └── endpoints.json                       # 86 endpoints + 7 cross-subnet ports
├── Tests/
│   └── AksArc.DeploymentReadiness.Tests.ps1 # Pester test suite (28 tests)
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
- Endpoint data sourced from [Azure/AzureStack-Tools](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/EastUSendpoints/eastus-hci-endpoints.md)
