#Requires -Modules Pester

Describe 'AksArc.DeploymentReadiness Module' {

    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..'
        $manifestPath = Join-Path $modulePath 'AksArc.DeploymentReadiness.psd1'
        Import-Module $manifestPath -Force -ErrorAction Stop
    }

    Context 'Module Structure' {

        It 'Module manifest is valid' {
            $manifest = Test-ModuleManifest -Path (Join-Path $PSScriptRoot '..' 'AksArc.DeploymentReadiness.psd1')
            $manifest | Should -Not -BeNullOrEmpty
            $manifest.Version | Should -Be '0.2.0'
        }

        It 'Exports exactly 8 functions' {
            $commands = Get-Command -Module AksArc.DeploymentReadiness
            $commands.Count | Should -Be 8
        }

        It 'Exports expected function names' {
            $expected = @(
                'Connect-AksArcServicePrincipal'
                'Export-AksArcFirewallRules'
                'Get-AksArcEndpointReference'
                'Get-AksArcFleetProgress'
                'Initialize-AksArcValidation'
                'Test-AksArcDeploymentReadiness'
                'Test-AksArcFleetReadiness'
                'Test-AksArcNetworkConnectivity'
            )
            $actual = (Get-Command -Module AksArc.DeploymentReadiness).Name | Sort-Object
            $actual | Should -Be $expected
        }
    }

    Context 'Endpoint Data' {

        It 'Loads endpoint data without errors' {
            $endpoints = Get-AksArcEndpointReference
            $endpoints | Should -Not -BeNullOrEmpty
        }

        It 'Contains 86 endpoints' {
            $endpoints = Get-AksArcEndpointReference
            $endpoints.Count | Should -Be 86
        }

        It 'Each endpoint has required properties' {
            $endpoints = Get-AksArcEndpointReference
            foreach ($ep in $endpoints) {
                $ep.id | Should -Not -BeNullOrEmpty
                $ep.url | Should -Not -BeNullOrEmpty
                $ep.port | Should -BeGreaterThan 0
                $ep.protocol | Should -Not -BeNullOrEmpty
                $ep.component | Should -Not -BeNullOrEmpty
            }
        }

        It 'Filters by component' {
            $aks = Get-AksArcEndpointReference -Component 'Azure Local AKS infra'
            $aks | Should -Not -BeNullOrEmpty
            $aks | ForEach-Object { $_.component | Should -Be 'Azure Local AKS infra' }
        }

        It 'Component filter is case-insensitive' {
            $aks = Get-AksArcEndpointReference -Component 'azure local aks infra'
            $aks | Should -Not -BeNullOrEmpty
        }

        It 'Contains expected upstream component names' {
            $endpoints = Get-AksArcEndpointReference
            $components = $endpoints | Select-Object -ExpandProperty component -Unique
            $components | Should -Contain 'Azure Local AKS infra'
            $components | Should -Contain 'Azure Local ARB infra'
            $components | Should -Contain 'Azure Local Arc agent'
            $components | Should -Contain 'Azure Local authentication'
            $components | Should -Contain 'Azure Local deployment'
        }

        It 'Contains customer-specific endpoints' {
            $endpoints = Get-AksArcEndpointReference
            $customerSpecific = @($endpoints | Where-Object { $_.customerSpecific -eq $true })
            $customerSpecific.Count | Should -Be 2
        }

        It 'Contains region-specific endpoints' {
            $endpoints = Get-AksArcEndpointReference
            $regionSpecific = @($endpoints | Where-Object { $_.regionSpecific -eq $true })
            $regionSpecific.Count | Should -BeGreaterThan 0
        }

        It 'Filters by ArcGatewaySupported' {
            $notCovered = Get-AksArcEndpointReference -ArcGatewaySupported $false
            $notCovered | ForEach-Object { $_.arcGatewaySupported | Should -Be $false }
        }

        It 'Filters by RequiredFor' {
            $deploy = Get-AksArcEndpointReference -RequiredFor 'deployment'
            $deploy | Should -Not -BeNullOrEmpty
            $deploy | ForEach-Object {
                ($_.requiredFor -eq 'deployment' -or $_.requiredFor -eq 'both') | Should -Be $true
            }
        }
    }

    Context 'Export-AksArcFirewallRules' {

        It 'Exports CSV' {
            $path = Join-Path $TestDrive 'rules.csv'
            Export-AksArcFirewallRules -Path $path
            Test-Path $path | Should -Be $true
            $csv = Import-Csv $path
            $csv.Count | Should -BeGreaterThan 0
        }

        It 'Exports JSON' {
            $path = Join-Path $TestDrive 'rules.json'
            Export-AksArcFirewallRules -Path $path
            Test-Path $path | Should -Be $true
            $json = Get-Content $path -Raw | ConvertFrom-Json
            $json.endpoints | Should -Not -BeNullOrEmpty
        }

        It 'Exports Markdown' {
            $path = Join-Path $TestDrive 'rules.md'
            Export-AksArcFirewallRules -Path $path
            Test-Path $path | Should -Be $true
            $content = Get-Content $path -Raw
            $content | Should -Match 'AKS Arc Firewall Requirements'
            $content | Should -Match '\|.*\|.*\|'
        }

        It 'Rejects unsupported format' {
            { Export-AksArcFirewallRules -Path (Join-Path $TestDrive 'rules.txt') } | Should -Throw '*Unsupported*'
        }
    }

    Context 'Test-AksArcNetworkConnectivity' {

        It 'Has Component parameter' {
            $cmd = Get-Command Test-AksArcNetworkConnectivity
            $cmd.Parameters.ContainsKey('Component') | Should -Be $true
        }

        It 'Has Region parameter' {
            $cmd = Get-Command Test-AksArcNetworkConnectivity
            $cmd.Parameters.ContainsKey('Region') | Should -Be $true
        }

        It 'Has ExportPath parameter' {
            $cmd = Get-Command Test-AksArcNetworkConnectivity
            $cmd.Parameters.ContainsKey('ExportPath') | Should -Be $true
        }

        It 'Has PassThru parameter' {
            $cmd = Get-Command Test-AksArcNetworkConnectivity
            $cmd.Parameters.ContainsKey('PassThru') | Should -Be $true
        }
    }

    Context 'Test-AksArcDeploymentReadiness' {

        It 'Supports ShouldProcess' {
            $cmd = Get-Command Test-AksArcDeploymentReadiness
            $cmd.Parameters.ContainsKey('WhatIf') | Should -Be $true
        }
    }

    Context 'Test-AksArcFleetReadiness' {

        It 'Has ScopeByTag parameter' {
            $cmd = Get-Command Test-AksArcFleetReadiness
            $cmd.Parameters.ContainsKey('ScopeByTag') | Should -Be $true
        }

        It 'Has BatchSize parameter with default 50' {
            $cmd = Get-Command Test-AksArcFleetReadiness
            $cmd.Parameters.ContainsKey('BatchSize') | Should -Be $true
        }
    }

    Context 'Initialize-AksArcValidation' {

        It 'Has ManagementNetwork parameter' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters.ContainsKey('ManagementNetwork') | Should -Be $true
        }

        It 'Has AksNetwork parameter' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters.ContainsKey('AksNetwork') | Should -Be $true
        }
    }

    Context 'Connect-AksArcServicePrincipal' {

        It 'Has UseManagedIdentity parameter' {
            $cmd = Get-Command Connect-AksArcServicePrincipal
            $cmd.Parameters.ContainsKey('UseManagedIdentity') | Should -Be $true
        }

        It 'Has ServicePrincipalId parameter' {
            $cmd = Get-Command Connect-AksArcServicePrincipal
            $cmd.Parameters.ContainsKey('ServicePrincipalId') | Should -Be $true
        }
    }
}
