# AksArc.DeploymentReadiness

<p align="center">
  <strong>Pre-deployment readiness validation for AKS Arc on Azure Local</strong>
</p>

<p align="center">
  <a href="#-quick-start">Quick Start</a> &bull;
  <a href="#-functions">Functions</a> &bull;
  <a href="#-examples">Examples</a> &bull;
  <a href="#-cicd-integration">CI/CD</a> &bull;
  <a href="#-endpoint-reference">Endpoints</a> &bull;
  <a href="#-contributing">Contributing</a>
</p>

---

## What is this?

A PowerShell module that answers the question: **"Is my Azure Local cluster ready for AKS Arc?"**

It validates network connectivity, endpoint reachability, cluster health, Arc Resource Bridge status, and logical network configuration — then gives you a clear pass/fail report you can hand to your team or pipe into CI/CD.

It also includes a **consolidated firewall endpoint reference** (45 endpoints + 7 cross-subnet ports) that you can export as CSV, JSON, or Markdown to hand directly to your network security team.

> [!NOTE]
> This module is **not** a Microsoft-supported product. It is a community tool distributed under the [MIT License](LICENSE).

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

**From PowerShell Gallery** *(once published)*:
```powershell
Install-Module AksArc.DeploymentReadiness -Scope CurrentUser
```

**From this repo** *(clone and import)*:
```powershell
git clone https://github.com/smitzlroy/AksArc.DeploymentReadiness.git
Import-Module ./AksArc.DeploymentReadiness/AksArc.DeploymentReadiness.psd1
```

---

## 🚀 Quick Start

### Scenario 1 — Single-site readiness check (run from an Azure Local node)

```powershell
Import-Module AksArc.DeploymentReadiness

# Step 1: Auto-discover cluster, ARB, custom location, and logical networks
$ctx = Initialize-AksArcValidation

# Step 2: Run all 6 readiness gates — export JUnit XML for your pipeline
Test-AksArcDeploymentReadiness -Context $ctx -ExportPath readiness-results.xml
```

### Scenario 2 — Get the firewall rules for your security team

```powershell
# Markdown table (great for wiki/email)
Export-AksArcFirewallRules -Path firewall-request.md -Region eastus -IncludeCrossSubnetPorts

# CSV for Excel / ServiceNow
Export-AksArcFirewallRules -Path firewall-request.csv -Region eastus
```

### Scenario 3 — Fleet-wide assessment (run from any workstation)

```powershell
# Authenticate with managed identity or service principal
Connect-AksArcServicePrincipal -UseManagedIdentity

# Assess all clusters tagged for Wave 1
Test-AksArcFleetReadiness -ScopeByTag -TagName 'ReadinessRing' -TagValue 'Wave1' -ExportPath fleet.xml
```

---

## 📦 Functions

The module is organized into three tiers based on where you run them and what they do.

### Tier 1 — Single-Site Readiness *(run from an Azure Local node)*

| Function | What it does |
|:---|:---|
| `Initialize-AksArcValidation` | Auto-discovers the Azure Local cluster, ARB, custom location, and logical networks. Returns a context object used by other functions. |
| `Test-AksArcDeploymentReadiness` | Runs **6 readiness gates**: cluster health, ARB, custom location, network connectivity, logical networks, cross-subnet ports. Outputs pass/fail per gate with remediation guidance. |
| `Test-AksArcNetworkConnectivity` | Tests TCP/HTTPS/DNS reachability to all 45 required endpoints. Reports latency and errors per endpoint. |

### Tier 2 — Endpoint Reference *(run from anywhere)*

| Function | What it does |
|:---|:---|
| `Get-AksArcEndpointReference` | Returns the full endpoint list as filterable PowerShell objects. Filter by `-Component`, `-ArcGatewaySupported`, `-RequiredFor`. |
| `Export-AksArcFirewallRules` | Exports firewall rules as `.csv`, `.json`, or `.md` — ready to attach to a change request. |

### Tier 3 — Fleet Scale *(run from any workstation, queries ARM/ARG)*

| Function | What it does |
|:---|:---|
| `Test-AksArcFleetReadiness` | Batch readiness assessment across multiple clusters via Azure Resource Graph. Supports tag-based scoping and batch processing. |
| `Get-AksArcFleetProgress` | Fleet-wide summary: connected vs. disconnected clusters, AKS Arc cluster count, optional per-cluster detail. |

### Authentication

| Function | What it does |
|:---|:---|
| `Connect-AksArcServicePrincipal` | Logs into Azure using Service Principal, Managed Identity, or environment variables (`AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`). |

---

## 📖 Examples

### Network connectivity test with filtering

```powershell
# Test only AKS Arc infrastructure endpoints
Test-AksArcNetworkConnectivity -Component 'AKS Arc infra' -Region eastus

# Find which endpoints still need direct firewall rules (not covered by Arc Gateway)
Get-AksArcEndpointReference -ArcGatewaySupported $false | Format-Table url, port, component

# Pipe failures for further analysis
$failed = Test-AksArcNetworkConnectivity -Region eastus -PassThru |
    Where-Object Status -eq 'Failed'
$failed | Format-Table Url, Port, Detail
```

### Full readiness with export

```powershell
$ctx = Initialize-AksArcValidation -ClusterName 'mycluster'

# JUnit XML — integrates with Azure DevOps and GitHub Actions test reporters
Test-AksArcDeploymentReadiness -Context $ctx -ExportPath results.xml

# JSON — for programmatic consumption
Test-AksArcDeploymentReadiness -Context $ctx -ExportPath results.json -PassThru |
    Where-Object Status -eq 'Failed'

# WhatIf — preview what gates would run without executing
Test-AksArcDeploymentReadiness -Context $ctx -WhatIf
```

### Fleet operations

```powershell
# Assess specific clusters by name
Test-AksArcFleetReadiness -ClusterNames @('site-east-01', 'site-west-02') -ExportPath fleet.csv

# Assess by tag
Test-AksArcFleetReadiness -ScopeByTag -TagName 'Environment' -TagValue 'Production'

# Quick fleet dashboard
Get-AksArcFleetProgress -Detailed
```

### Endpoint data freshness check

```powershell
# Check if embedded endpoint data is getting stale (warns if > 90 days old)
Get-AksArcEndpointReference -CheckForUpdates
```

---

## Common Parameters

These parameters follow the same conventions as the [AzStackHci.ManageUpdates](https://github.com/NeilBird/Azure-Local/tree/main/AzStackHci.ManageUpdates) module:

| Parameter | Available on | Description |
|:---|:---|:---|
| `-PassThru` | `Test-*`, `Get-*` | Returns result objects to the pipeline instead of just console output |
| `-ExportPath` | `Test-*` | Exports results to `.csv`, `.json`, or `.xml` (JUnit format) |
| `-WhatIf` | `Test-AksArcDeploymentReadiness` | Previews which gates would run without executing them |
| `-Region` | Network & endpoint functions | Resolves region-specific wildcard URLs (e.g., `*.his.arc.azure.com` → `eastus.his.arc.azure.com`) |
| `-Component` | Network & endpoint functions | Filters endpoints by component (`AKS Arc infra`, `ARB infra`, `Arc agent`, etc.) |
| `-ScopeByTag` | Fleet functions | Scopes cluster discovery by Azure resource tag |

---

## 🔥 Endpoint Reference

The module ships with a consolidated endpoint reference embedded at [`data/endpoints.json`](data/endpoints.json).

| Category | Count |
|:---|:---|
| Required endpoints | 45 |
| Cross-subnet ports | 7 |
| Components covered | AKS Arc infra, ARB infra, Arc agent, Authentication, ARM, Monitoring, HCI infra, Azure services |

**Sourced from**: [Microsoft Learn — AKS Arc network requirements](https://learn.microsoft.com/azure/aks/aksarc/aks-hci-network-requirements) and [Azure/AzureStack-Tools](https://github.com/Azure/AzureStack-Tools/tree/master/HCI) endpoint lists.

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

---

## Export Formats

| Extension | Format | Best for |
|:---|:---|:---|
| `.csv` | Comma-separated values | Firewall change requests, Excel, ServiceNow |
| `.json` | JSON | Pipeline automation, programmatic consumption |
| `.xml` | JUnit XML | Azure DevOps / GitHub Actions test reporting |
| `.md` | Markdown table | Documentation, wiki pages, email |

---

## 🔄 CI/CD Integration

Ready-to-use pipeline templates are in the [`Automation-Pipeline-Examples/`](Automation-Pipeline-Examples/) folder.

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

## 📁 Module Structure

```
AksArc.DeploymentReadiness/
├── AksArc.DeploymentReadiness.psd1          # Module manifest
├── AksArc.DeploymentReadiness.psm1          # All functions (single-file module)
├── data/
│   └── endpoints.json                       # 45 endpoints + 7 cross-subnet ports
├── Tests/
│   └── AksArc.DeploymentReadiness.Tests.ps1 # Pester test suite (22 tests)
├── Automation-Pipeline-Examples/
│   ├── github-actions-fleet-readiness.yml   # GitHub Actions workflow
│   └── azure-devops-fleet-readiness.yml     # Azure DevOps pipeline
├── CHANGELOG.md
├── LICENSE                                  # MIT
└── README.md
```

---

## 🤝 Contributing

Pull requests are welcome! Before submitting:

```powershell
# 1. Run the Pester test suite
Invoke-Pester ./Tests/ -Output Detailed

# 2. Run PSScriptAnalyzer
Invoke-ScriptAnalyzer ./AksArc.DeploymentReadiness.psm1

# 3. Verify import on both PowerShell versions
pwsh -c "Import-Module ./AksArc.DeploymentReadiness.psd1; Get-Command -Module AksArc.DeploymentReadiness"
powershell -c "Import-Module ./AksArc.DeploymentReadiness.psd1; Get-Command -Module AksArc.DeploymentReadiness"
```

---

## License

[MIT](LICENSE)

## Acknowledgments

- Module structure inspired by [AzStackHci.ManageUpdates](https://github.com/NeilBird/Azure-Local/tree/main/AzStackHci.ManageUpdates) by Neil Bird
- Endpoint data sourced from [Microsoft Learn — AKS Arc network requirements](https://learn.microsoft.com/azure/aks/aksarc/aks-hci-network-requirements)
