# Changelog

All notable changes to the **AksArc.DeploymentReadiness** module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
