@{
    # Module manifest for AksArc.DeploymentReadiness
    # Generated on: 2026-04-15

    RootModule        = 'AksArc.DeploymentReadiness.psm1'
    ModuleVersion     = '0.8.2'
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
            ReleaseNotes = 'v0.8.2: Arc Gateway and Key Vault awareness. (1) Get-AksArcLocalContext now reads gatewayUrl / connectionType from azcmagent show -j (and azcmagent config get connection.type as a fallback) so the module knows when traffic is tunneled through Arc Gateway. (2) New parameters -ArcGatewayUrl and -KeyVaultName on Initialize-AksArcValidation and Test-AksArcDeploymentReadiness. (3) When Arc Gateway is configured, endpoints flagged arcGatewaySupported=true are marked Skipped ("Covered by Arc Gateway") instead of being tested individually and falsely failing. The gateway URL placeholder ''<your-arc-gateway-id>.gw.arc.azure.com'' is replaced with the real hostname and tested. (4) Same pattern for Key Vault: -KeyVaultName replaces ''<your-keyvault-name>.vault.azure.net'' with the real value. (5) New Gate 0 ArcGateway check records the connection mode (Passed when gateway is in use, Skipped when direct).'
        }
    }
}
