@{
    # Module manifest for AksArc.DeploymentReadiness
    # Generated on: 2026-04-15

    RootModule        = 'AksArc.DeploymentReadiness.psm1'
    ModuleVersion     = '0.8.0'
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
            ReleaseNotes = 'v0.8.0: Node-local cluster resolution. Initialize-AksArcValidation now auto-detects the local Azure Local cluster via Get-Cluster + azcmagent when run on a node, and uses `az resource show` for direct lookup (no subscription-wide Reader required). Test-AksArcDeploymentReadiness accepts -ClusterName / -ResourceGroupName / -SubscriptionId directly so it works without an explicit Initialize call. Subscription-wide enumeration is now a last-resort fallback for management workstations. New public helper Get-AksArcLocalContext. Context gains ResolveMode field (Explicit | AzureLocalNode | SubscriptionDiscovery).'
        }
    }
}
