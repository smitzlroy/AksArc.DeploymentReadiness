# Changelog

All notable changes to the **AksArc.DeploymentReadiness** module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-04-16

### Added

- **`New-AksArcReadinessReport`**: New function to generate self-contained HTML readiness reports. Supports single-site results, fleet results, and deployment plan IP capacity analysis. Styled with executive summary cards, gate result tables, remediation action items, and fleet cluster status grids.
- **Fleet deep checks** in `Test-AksArcFleetReadiness`: Now checks extension health (failed extensions = deployment risk), logical network health, and AKS cluster count per Azure Local cluster.
- **`-DeploymentPlan`** parameter on `Test-AksArcFleetReadiness` for fleet-wide IP capacity reporting.
- **`-MinReadyPercent`** and **`-MaxWarningPercent`** configurable health gate thresholds on `Test-AksArcFleetReadiness`. Default: 100% ready, 10% max warnings.
- **`-ThrottleLimit`** parameter on `Test-AksArcFleetReadiness` for parallel data collection via `Start-Job` (default: 4). Reduces API call time for fleets of 20+ clusters.
- **Three-state fleet status**: Clusters now report `Ready`, `Warning`, or `NotReady` (was binary Ready/NotReady). Warnings track extension failures and LNET issues.
- **Fleet result properties**: `ExtensionTotal`, `ExtensionFailed`, `FailedExtensions`, `LogicalNetworks`, `LogicalNetworkOk`, `AksClusterCount`, `Warnings`.

### Changed

- **`Test-AksArcFleetReadiness`** rewritten with parallel data collection architecture. Per-cluster queries (ARB, Custom Location, Extensions, LNETs, AKS clusters) run in parallel via `Start-Job` with configurable throttle.
- Fleet summary now shows Ready/Warning/NotReady breakdown and health gate pass/fail.
- Module now exports **10 functions** (was 9).

## [0.4.0] - 2026-04-16

### Added

- **Gate 7 — Active Cross-Subnet Port Testing**: Real TCP connectivity tests on cross-VLAN ports (22, 443, 6443, 9440, 55000, 65000) when target IPs are provided. Tests direction-aware: management→AKS subnet ports and AKS subnet→cluster ports. Arc Gateway port 40343 conditionally tested.
- **Gate 8 — RBAC Permission Validation**: Validates that the logged-in identity has sufficient Azure RBAC permissions for AKS Arc deployment. Checks for Owner/Contributor/AKS Arc Contributor roles, or drills into custom role permissions for specific actions like `Microsoft.Kubernetes/connectedClusters/write`.
- **`-ManagementIPs`**, **`-AksSubnetTestIP`**, **`-ClusterIP`** parameters on `Initialize-AksArcValidation` for active port testing targets.
- **Direction metadata** (`testDirection`) on cross-subnet port entries in `endpoints.json` — `toAks` for management→AKS subnet ports, `toCluster` for AKS subnet→cluster ports.
- **Conditional port flag** on port 40343 (Arc Gateway) — skipped unless explicitly enabled.

### Changed

- **`Invoke-AzRestCall`** enhanced with structured error handling: captures stderr, logs error messages, supports `-ThrowOnError` switch and `-ApiVersion` override. Previously swallowed all errors silently.
- Assessment now runs **8 gates** (was 6): Cluster Health, ARB, Custom Location, Network Connectivity, Logical Networks, Cross-Subnet Ports (info), Active Port Testing, RBAC.

## [0.3.0] - 2026-04-16

### Added

- **`New-AksArcDeploymentPlan`**: New function to create a deployment plan with IP capacity math. Calculates total IPs needed for node VMs, rolling upgrades, control plane (KubeVIP), load balancer (MetalLB), and autoscale headroom. Supports interactive prompts with CI/CD fallback to defaults.
- **`-DeploymentPlan` parameter** on `Test-AksArcDeploymentReadiness`: When provided, Gate 5 validates that the AKS logical network IP pool has sufficient capacity for the planned deployment.
- **On-node detection** in `Initialize-AksArcValidation`: Detects whether the module is running on an Azure Local node (via `Get-ClusterNode`) and warns when running remotely that network connectivity tests validate from the wrong vantage point.
- **`HostType` property** on the context object returned by `Initialize-AksArcValidation` (`AzureLocalNode`, `RemoteHost`, or `Unknown`).

### Changed

- **Gate 5 (Logical Networks)**: Rewritten from existence checks to deep validation:
  - IP pool capacity validation: counts available IPs across pools, compares against deployment plan requirements, reports surplus or deficit
  - IP allocation method check: fails if DHCP detected (AKS Arc requires static)
  - DNS server validation: tests each configured DNS server for ability to resolve Azure endpoints (`mcr.microsoft.com`, `management.azure.com`)
  - Gateway validation: warns if no default gateway is configured
  - Load balancer IP guidance: warns that MetalLB IPs must be in same subnet but outside the IP pool range
  - Missing IP pool is now a **failure** (was warning) for AKS-designated networks

### Tests

- Updated module structure tests for 9 exported functions (was 8)
- Added 11 new Pester tests for `New-AksArcDeploymentPlan`: parameter existence, single-cluster IP math, multi-cluster IP math, autoscale headroom, edge cases
- Added parameter test for `Test-AksArcDeploymentReadiness -DeploymentPlan`
- Total tests: 28 → 40

## [0.2.0] - 2026-04-15

### Changed

- **Endpoint reference rebuilt**: 45 → 86 endpoints sourced from [Azure/AzureStack-Tools commit 41f99d8](https://github.com/Azure/AzureStack-Tools/blob/41f99d8c8157225201ee31f0ccf93f2110391ec7/HCI/EastUSendpoints/eastus-hci-endpoints.md)
- **Component names** now match upstream exactly (e.g., `Azure Local AKS infra`, `Azure Local ARB infra`, `Azure Local Arc agent`)
- **Component filter** is now case-insensitive substring match (e.g., `-Component 'AKS'` matches `Azure Local AKS infra`)
- **Region handling**: standalone `Test-AksArcNetworkConnectivity` now warns when `-Region` is omitted and skips 11 region-specific endpoints instead of silently failing DNS
- **Gate 5 (Logical Networks)**: enhanced to validate subnet, VLAN, and IP pool configuration; distinguishes management vs. AKS networks

### Added

- `-ManagementNetwork` and `-AksNetwork` parameters on `Initialize-AksArcValidation` to classify logical networks
- Customer-specific endpoint support (`customerSpecific` flag) for Key Vault and Arc Gateway placeholders
- 7 region URL patterns for resolving region-specific endpoints
- Comprehensive README with full parameter reference for every function, troubleshooting section
- 6 new Pester tests (22 → 28)

### Fixed

- Region-specific endpoints no longer silently fail when `-Region` is not provided
- Component filter no longer requires exact case-sensitive match

## [0.1.0] - 2025-01-01

### Added

- Initial release
- **Initialize-AksArcValidation**: Auto-discovers Azure Local cluster, ARB, custom location, and logical networks
- **Test-AksArcDeploymentReadiness**: 6-gate readiness assessment (cluster health, ARB, custom location, network, logical networks, cross-subnet ports)
- **Test-AksArcNetworkConnectivity**: Tests TCP/HTTPS/DNS reachability to all 45 required endpoints
- **Get-AksArcEndpointReference**: Returns the consolidated endpoint reference as filterable objects
- **Export-AksArcFirewallRules**: Exports firewall requirements as CSV, JSON, or Markdown for security teams
- **Test-AksArcFleetReadiness**: Batch readiness assessment across multiple clusters via Azure Resource Graph
- **Get-AksArcFleetProgress**: Fleet-wide readiness summary statistics
- **Connect-AksArcServicePrincipal**: Service Principal and Managed Identity authentication for CI/CD
- Embedded endpoint reference (45 endpoints + 7 cross-subnet ports) with provenance metadata
- JUnit XML export for CI/CD pipeline integration
- Support for PowerShell 5.1 (Server Core) and PowerShell 7+
