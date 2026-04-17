@{
    # Module manifest for AksArc.DeploymentReadiness
    # Generated on: 2026-04-15

    RootModule        = 'AksArc.DeploymentReadiness.psm1'
    ModuleVersion     = '0.7.0'
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
            ReleaseNotes = 'v0.7.0: Fix az CLI JSON parsing on Windows PowerShell 5.1 - use System.Diagnostics.Process to bypass PS 5.1 native command pipeline bugs that lose stdout data. All az CLI calls now use dedicated helpers (Invoke-AzCliJson, Invoke-AzCliRaw) for reliable cross-version operation.'
        }
    }
}
