# Changelog

All notable changes to the **AksArc.DeploymentReadiness** module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
