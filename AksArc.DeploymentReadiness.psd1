@{
    # Module manifest for AksArc.DeploymentReadiness
    # Generated on: 2026-04-15

    RootModule        = 'AksArc.DeploymentReadiness.psm1'
    ModuleVersion     = '0.8.3'
    GUID              = 'a3e7c1d9-4f2b-4e8a-9d6c-1b5f3e7a2c4d'
    Author            = 'smitzlroy'
    CompanyName       = 'Community'
    Copyright         = '(c) 2026 smitzlroy. MIT License.'
    Description       = 'Pre-deployment readiness validation for AKS Arc on Azure Local. Validates network connectivity, endpoint reachability, cluster health, ARB status, and RBAC. Includes consolidated firewall endpoint reference and fleet-scale assessment. Follows the AzStackHci.ManageUpdates pattern.'

    # Minimum version of the PowerShell engine required
    PowerShellVersion = '5.1'

    # Functions to export from this module
    FunctionsToExport = @(
        'Initialize-AksArcValidation'
        'New-AksArcDeploymentPlan'
        'Test-AksArcDeploymentReadiness'
        'Test-AksArcNetworkConnectivity'
        'Get-AksArcEndpointReference'
        'Export-AksArcFirewallRules'
        'Test-AksArcFleetReadiness'
        'Get-AksArcFleetProgress'
        'Connect-AksArcServicePrincipal'
        'New-AksArcReadinessReport'
        'Get-AksArcLocalContext'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()

    # Private data for PSGallery
    PrivateData = @{
        PSData = @{
            Tags         = @('AKS', 'AKS-Arc', 'Azure-Local', 'Azure-Stack-HCI', 'Readiness', 'Validation', 'Firewall', 'Endpoints', 'Fleet', 'OT')
            LicenseUri   = 'https://github.com/smitzlroy/AksArc.DeploymentReadiness/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/smitzlroy/AksArc.DeploymentReadiness'
            ReleaseNotes = 'v0.8.3: Fixes from real-node validation. (1) Per-RP api-version map: Microsoft.ResourceConnector/appliances now uses 2022-10-27 and Microsoft.ExtendedLocation/customLocations uses 2021-08-15 (the global 2025-10-01 default returned NoRegisteredProviderFound for these RPs in westeurope). New Get-ApiVersionForUri helper picks the right version per resource type. (2) Gate 5 LNet detail: az stack-hci-vm network lnet show now uses --name (and --ids when available) instead of -n, which the extension does not alias. (3) Gate 8 RBAC: when az is logged in via az login --identity, account show returns user.name=systemAssignedIdentity which is not a valid --assignee value. The gate now resolves the Arc machine MSI principalId by reading the local Microsoft.HybridCompute/machines resource (machineName + RG come from azcmagent show -j via Get-AksArcLocalContext) and uses that oid for role assignment lookup. If the principalId cannot be resolved, the gate now Skips with specific guidance rather than producing a false-negative FAIL. (4) Get-AksArcLocalContext exposes new MachineName and MachineResourceGroup fields.'
        }
    }
}
