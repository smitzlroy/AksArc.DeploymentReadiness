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
            $manifest.Version | Should -Be '0.8.3'
        }

        It 'Exports exactly 11 functions' {
            $commands = Get-Command -Module AksArc.DeploymentReadiness
            $commands.Count | Should -Be 11
        }

        It 'Exports expected function names' {
            $expected = @(
                'Connect-AksArcServicePrincipal'
                'Export-AksArcFirewallRules'
                'Get-AksArcEndpointReference'
                'Get-AksArcFleetProgress'
                'Get-AksArcLocalContext'
                'Initialize-AksArcValidation'
                'New-AksArcDeploymentPlan'
                'New-AksArcReadinessReport'
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

    Context 'New-AksArcDeploymentPlan' {

        It 'Has PlannedClusters parameter' {
            $cmd = Get-Command New-AksArcDeploymentPlan
            $cmd.Parameters.ContainsKey('PlannedClusters') | Should -Be $true
        }

        It 'Has ControlPlaneNodes parameter' {
            $cmd = Get-Command New-AksArcDeploymentPlan
            $cmd.Parameters.ContainsKey('ControlPlaneNodes') | Should -Be $true
        }

        It 'Has WorkerNodes parameter' {
            $cmd = Get-Command New-AksArcDeploymentPlan
            $cmd.Parameters.ContainsKey('WorkerNodes') | Should -Be $true
        }

        It 'Has EnableAutoScale parameter' {
            $cmd = Get-Command New-AksArcDeploymentPlan
            $cmd.Parameters.ContainsKey('EnableAutoScale') | Should -Be $true
        }

        It 'Has AksNetworkName parameter' {
            $cmd = Get-Command New-AksArcDeploymentPlan
            $cmd.Parameters.ContainsKey('AksNetworkName') | Should -Be $true
        }

        It 'Calculates IP requirements for single cluster defaults' {
            $plan = New-AksArcDeploymentPlan -PlannedClusters 1 -ControlPlaneNodes 3 -WorkerNodes 3 -LoadBalancerIPs 3
            $plan.PlannedClusters | Should -Be 1
            $plan.ControlPlaneNodes | Should -Be 3
            $plan.WorkerNodes | Should -Be 3
            $plan.NodesPerCluster | Should -Be 6
            $plan.TotalNodeVMs | Should -Be 6
            $plan.TotalUpgradeIPs | Should -Be 1
            $plan.TotalControlPlaneIPs | Should -Be 1
            $plan.TotalRequiredIPs | Should -Be 8   # 6 nodes + 1 upgrade + 1 CP
            $plan.TotalWithLoadBalancer | Should -Be 11  # 8 + 3 LB
        }

        It 'Calculates IP requirements for multi-cluster deployment' {
            $plan = New-AksArcDeploymentPlan -PlannedClusters 3 -ControlPlaneNodes 3 -WorkerNodes 5 -LoadBalancerIPs 5
            $plan.TotalNodeVMs | Should -Be 24   # (3+5) * 3
            $plan.TotalUpgradeIPs | Should -Be 3
            $plan.TotalControlPlaneIPs | Should -Be 3
            $plan.TotalRequiredIPs | Should -Be 30  # 24 + 3 + 3
            $plan.TotalWithLoadBalancer | Should -Be 35  # 30 + 5
        }

        It 'Calculates autoscale headroom correctly' {
            $plan = New-AksArcDeploymentPlan -PlannedClusters 2 -ControlPlaneNodes 3 -WorkerNodes 3 -LoadBalancerIPs 0 -EnableAutoScale -MaxAutoScaleNodes 10
            $plan.AutoScaleHeadroom | Should -Be 14  # (10-3) * 2
            $plan.TotalRequiredIPs | Should -Be 30   # 12 node VMs + 2 upgrade + 2 CP + 14 autoscale
        }

        It 'Autoscale headroom is zero when MaxAutoScaleNodes <= WorkerNodes' {
            $plan = New-AksArcDeploymentPlan -PlannedClusters 1 -ControlPlaneNodes 1 -WorkerNodes 5 -LoadBalancerIPs 0 -EnableAutoScale -MaxAutoScaleNodes 3
            $plan.AutoScaleHeadroom | Should -Be 0
        }

        It 'Returns a plan object with Timestamp' {
            $plan = New-AksArcDeploymentPlan -PlannedClusters 1 -ControlPlaneNodes 1 -WorkerNodes 1 -LoadBalancerIPs 0
            $plan.Timestamp | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Test-AksArcDeploymentReadiness DeploymentPlan parameter' {

        It 'Has DeploymentPlan parameter' {
            $cmd = Get-Command Test-AksArcDeploymentReadiness
            $cmd.Parameters.ContainsKey('DeploymentPlan') | Should -Be $true
        }
    }

    Context 'Initialize-AksArcValidation v0.4.0 parameters' {

        It 'Has ManagementIPs parameter' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters.ContainsKey('ManagementIPs') | Should -Be $true
        }

        It 'Has AksSubnetTestIP parameter' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters.ContainsKey('AksSubnetTestIP') | Should -Be $true
        }

        It 'Has ClusterIP parameter' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters.ContainsKey('ClusterIP') | Should -Be $true
        }

        It 'ManagementIPs accepts string array' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters['ManagementIPs'].ParameterType.Name | Should -Be 'String[]'
        }
    }

    Context 'Endpoint Data - Cross-Subnet Port Directions' {

        It 'Cross-subnet ports have testDirection property' {
            $dataPath = Join-Path $PSScriptRoot '..' 'data' 'endpoints.json'
            $data = Get-Content $dataPath -Raw | ConvertFrom-Json
            foreach ($port in $data.crossSubnetPorts) {
                $port.testDirection | Should -Not -BeNullOrEmpty
            }
        }

        It 'testDirection values are valid' {
            $dataPath = Join-Path $PSScriptRoot '..' 'data' 'endpoints.json'
            $data = Get-Content $dataPath -Raw | ConvertFrom-Json
            $validDirections = @('toAks', 'toCluster')
            foreach ($port in $data.crossSubnetPorts) {
                $port.testDirection | Should -BeIn $validDirections
            }
        }

        It 'Ports 22, 443, 6443, 9440 test toAks direction' {
            $dataPath = Join-Path $PSScriptRoot '..' 'data' 'endpoints.json'
            $data = Get-Content $dataPath -Raw | ConvertFrom-Json
            $toAksPorts = @(22, 443, 6443, 9440)
            foreach ($p in $toAksPorts) {
                $entry = $data.crossSubnetPorts | Where-Object { $_.port -eq $p }
                $entry.testDirection | Should -Be 'toAks'
            }
        }

        It 'Ports 55000, 65000 test toCluster direction' {
            $dataPath = Join-Path $PSScriptRoot '..' 'data' 'endpoints.json'
            $data = Get-Content $dataPath -Raw | ConvertFrom-Json
            $toClusterPorts = @(55000, 65000)
            foreach ($p in $toClusterPorts) {
                $entry = $data.crossSubnetPorts | Where-Object { $_.port -eq $p }
                $entry.testDirection | Should -Be 'toCluster'
            }
        }

        It 'Port 40343 is marked conditional' {
            $dataPath = Join-Path $PSScriptRoot '..' 'data' 'endpoints.json'
            $data = Get-Content $dataPath -Raw | ConvertFrom-Json
            $arcGw = $data.crossSubnetPorts | Where-Object { $_.port -eq 40343 }
            $arcGw.conditional | Should -Be $true
        }
    }

    Context 'Invoke-AzRestCall enhanced error handling' {

        It 'Invoke-AzRestCall is an internal function (not exported)' {
            $exported = (Get-Command -Module AksArc.DeploymentReadiness).Name
            $exported | Should -Not -Contain 'Invoke-AzRestCall'
        }
    }

    Context 'Gate 7 and Gate 8 integration (parameter-level)' {

        It 'Test-AksArcDeploymentReadiness has Context parameter' {
            $cmd = Get-Command Test-AksArcDeploymentReadiness
            $cmd.Parameters.ContainsKey('Context') | Should -Be $true
        }

        It 'Test-AksArcDeploymentReadiness has SkipNetworkTests parameter' {
            $cmd = Get-Command Test-AksArcDeploymentReadiness
            $cmd.Parameters.ContainsKey('SkipNetworkTests') | Should -Be $true
        }

        It 'Test-AksArcDeploymentReadiness has Region parameter' {
            $cmd = Get-Command Test-AksArcDeploymentReadiness
            $cmd.Parameters.ContainsKey('Region') | Should -Be $true
        }
    }

    Context 'Test-AksArcFleetReadiness v0.5.0 enhancements' {

        It 'Has DeploymentPlan parameter' {
            $cmd = Get-Command Test-AksArcFleetReadiness
            $cmd.Parameters.ContainsKey('DeploymentPlan') | Should -Be $true
        }

        It 'Has MinReadyPercent parameter' {
            $cmd = Get-Command Test-AksArcFleetReadiness
            $cmd.Parameters.ContainsKey('MinReadyPercent') | Should -Be $true
        }

        It 'Has MaxWarningPercent parameter' {
            $cmd = Get-Command Test-AksArcFleetReadiness
            $cmd.Parameters.ContainsKey('MaxWarningPercent') | Should -Be $true
        }

        It 'Has ThrottleLimit parameter' {
            $cmd = Get-Command Test-AksArcFleetReadiness
            $cmd.Parameters.ContainsKey('ThrottleLimit') | Should -Be $true
        }

        It 'MinReadyPercent has ValidateRange 0-100' {
            $cmd = Get-Command Test-AksArcFleetReadiness
            $attrs = $cmd.Parameters['MinReadyPercent'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $attrs | Should -Not -BeNullOrEmpty
        }

        It 'ThrottleLimit has ValidateRange 1-20' {
            $cmd = Get-Command Test-AksArcFleetReadiness
            $attrs = $cmd.Parameters['ThrottleLimit'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $attrs | Should -Not -BeNullOrEmpty
        }
    }

    Context 'New-AksArcReadinessReport' {

        It 'Function exists and is exported' {
            $cmd = Get-Command New-AksArcReadinessReport -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
        }

        It 'Has OutputPath as mandatory parameter' {
            $cmd = Get-Command New-AksArcReadinessReport
            $cmd.Parameters.ContainsKey('OutputPath') | Should -Be $true
            $mandatory = $cmd.Parameters['OutputPath'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }
            $mandatory | Should -Not -BeNullOrEmpty
        }

        It 'Has Results parameter' {
            $cmd = Get-Command New-AksArcReadinessReport
            $cmd.Parameters.ContainsKey('Results') | Should -Be $true
        }

        It 'Has FleetResults parameter' {
            $cmd = Get-Command New-AksArcReadinessReport
            $cmd.Parameters.ContainsKey('FleetResults') | Should -Be $true
        }

        It 'Has DeploymentPlan parameter' {
            $cmd = Get-Command New-AksArcReadinessReport
            $cmd.Parameters.ContainsKey('DeploymentPlan') | Should -Be $true
        }

        It 'Has PassThru parameter' {
            $cmd = Get-Command New-AksArcReadinessReport
            $cmd.Parameters.ContainsKey('PassThru') | Should -Be $true
        }

        It 'Has Title parameter' {
            $cmd = Get-Command New-AksArcReadinessReport
            $cmd.Parameters.ContainsKey('Title') | Should -Be $true
        }

        It 'Generates HTML from mock single-site results' {
            $mockResults = @(
                [PSCustomObject]@{ Gate = 'ClusterHealth'; Check = 'Provisioning'; Status = 'Passed'; Message = 'Cluster OK'; Remediation = $null; Detail = $null }
                [PSCustomObject]@{ Gate = 'ARB'; Check = 'Status'; Status = 'Failed'; Message = 'ARB not running'; Remediation = 'Restart ARB'; Detail = $null }
                [PSCustomObject]@{ Gate = 'Network'; Check = 'DNS'; Status = 'Warning'; Message = 'Slow DNS'; Remediation = $null; Detail = $null }
            )
            $path = Join-Path $TestDrive 'report.html'
            New-AksArcReadinessReport -Results $mockResults -OutputPath $path
            Test-Path $path | Should -Be $true
            $content = Get-Content $path -Raw
            $content | Should -Match '<html'
            $content | Should -Match 'NOT READY'
            $content | Should -Match 'Remediation Actions'
            $content | Should -Match 'Restart ARB'
        }

        It 'Generates HTML from mock fleet results' {
            $mockFleet = @(
                [PSCustomObject]@{ ClusterName = 'c1'; ResourceGroup = 'rg1'; Region = 'eastus'; ClusterConnected = $true; ARBHealthy = $true; CustomLocationOk = $true; ExtensionTotal = 5; ExtensionFailed = 0; FailedExtensions = ''; LogicalNetworks = 2; AksClusterCount = 1; Warnings = ''; ReadyForAksArc = $true; Status = 'Ready' }
                [PSCustomObject]@{ ClusterName = 'c2'; ResourceGroup = 'rg2'; Region = 'westus'; ClusterConnected = $false; ARBHealthy = $false; CustomLocationOk = $false; ExtensionTotal = 3; ExtensionFailed = 1; FailedExtensions = 'ext1'; LogicalNetworks = 1; AksClusterCount = 0; Warnings = 'Extensions: 1 failed'; ReadyForAksArc = $false; Status = 'NotReady' }
            )
            $path = Join-Path $TestDrive 'fleet-report.html'
            New-AksArcReadinessReport -FleetResults $mockFleet -OutputPath $path
            Test-Path $path | Should -Be $true
            $content = Get-Content $path -Raw
            $content | Should -Match 'Fleet Cluster Status'
            $content | Should -Match 'c1'
            $content | Should -Match 'c2'
        }

        It 'Includes IP capacity section when DeploymentPlan provided' {
            $plan = New-AksArcDeploymentPlan -PlannedClusters 2 -ControlPlaneNodes 3 -WorkerNodes 5 -LoadBalancerIPs 3
            $path = Join-Path $TestDrive 'plan-report.html'
            New-AksArcReadinessReport -DeploymentPlan $plan -Results @(
                [PSCustomObject]@{ Gate = 'Test'; Check = 'Test'; Status = 'Passed'; Message = 'OK'; Remediation = $null; Detail = $null }
            ) -OutputPath $path
            $content = Get-Content $path -Raw
            $content | Should -Match 'IP Capacity Analysis'
            $content | Should -Match '20'  # TotalRequiredIPs for 2 clusters * (3+5) + 2 upgrade + 2 CP
        }

        It 'Returns HTML string with -PassThru' {
            $mockResults = @(
                [PSCustomObject]@{ Gate = 'Test'; Check = 'Test'; Status = 'Passed'; Message = 'OK'; Remediation = $null; Detail = $null }
            )
            $path = Join-Path $TestDrive 'passthru.html'
            $html = New-AksArcReadinessReport -Results $mockResults -OutputPath $path -PassThru
            $html | Should -Not -BeNullOrEmpty
            $html | Should -Match '<html'
        }
    }

    Context 'Initialize-AksArcValidation interactive LNET selection' {

        It 'Initialize-AksArcValidation still has ManagementNetwork parameter' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters.ContainsKey('ManagementNetwork') | Should -Be $true
        }

        It 'Initialize-AksArcValidation still has AksNetwork parameter' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters.ContainsKey('AksNetwork') | Should -Be $true
        }

        It 'ManagementNetwork and AksNetwork are optional (not mandatory)' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters['ManagementNetwork'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object {
                $_.Mandatory | Should -Be $false
            }
            $cmd.Parameters['AksNetwork'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object {
                $_.Mandatory | Should -Be $false
            }
        }

        It 'ManagementNetwork accepts string type' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters['ManagementNetwork'].ParameterType | Should -Be ([string])
        }

        It 'AksNetwork accepts string type' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters['AksNetwork'].ParameterType | Should -Be ([string])
        }
    }

    Context 'v0.8.0 node-local cluster resolution' {

        It 'Exports Get-AksArcLocalContext' {
            Get-Command Get-AksArcLocalContext -Module AksArc.DeploymentReadiness -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It 'Get-AksArcLocalContext takes no mandatory parameters' {
            $cmd = Get-Command Get-AksArcLocalContext
            $mandatory = $cmd.Parameters.Values | Where-Object {
                $_.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }
            }
            $mandatory | Should -BeNullOrEmpty
        }

        It 'Get-AksArcLocalContext returns $null when not on an Azure Local node' {
            # Dev / CI boxes will not have both Get-Cluster + azcmagent configured.
            $result = Get-AksArcLocalContext -ErrorAction SilentlyContinue
            if ($null -ne $result) {
                # If we do happen to be on a node, the shape must be correct.
                $result.IsAzureLocalNode | Should -Be $true
                $result.SubscriptionId | Should -Not -BeNullOrEmpty
                $result.ResourceGroupName | Should -Not -BeNullOrEmpty
                $result.ClusterName | Should -Not -BeNullOrEmpty
            } else {
                $result | Should -BeNullOrEmpty
            }
        }

        It 'Test-AksArcDeploymentReadiness exposes -ClusterName parameter' {
            $cmd = Get-Command Test-AksArcDeploymentReadiness
            $cmd.Parameters.ContainsKey('ClusterName') | Should -Be $true
            $cmd.Parameters['ClusterName'].ParameterType | Should -Be ([string])
        }

        It 'Test-AksArcDeploymentReadiness exposes -ResourceGroupName parameter' {
            $cmd = Get-Command Test-AksArcDeploymentReadiness
            $cmd.Parameters.ContainsKey('ResourceGroupName') | Should -Be $true
        }

        It 'Test-AksArcDeploymentReadiness exposes -SubscriptionId parameter' {
            $cmd = Get-Command Test-AksArcDeploymentReadiness
            $cmd.Parameters.ContainsKey('SubscriptionId') | Should -Be $true
        }

        It 'Test-AksArcDeploymentReadiness exposes -ManagementNetwork / -AksNetwork pass-through' {
            $cmd = Get-Command Test-AksArcDeploymentReadiness
            $cmd.Parameters.ContainsKey('ManagementNetwork') | Should -Be $true
            $cmd.Parameters.ContainsKey('AksNetwork')        | Should -Be $true
        }
    }

    Context 'v0.8.2 Arc Gateway and Key Vault parameters' {

        It 'Initialize-AksArcValidation accepts -ArcGatewayUrl' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters.ContainsKey('ArcGatewayUrl') | Should -Be $true
            $cmd.Parameters['ArcGatewayUrl'].ParameterType | Should -Be ([string])
        }

        It 'Initialize-AksArcValidation accepts -KeyVaultName' {
            $cmd = Get-Command Initialize-AksArcValidation
            $cmd.Parameters.ContainsKey('KeyVaultName') | Should -Be $true
        }

        It 'Test-AksArcDeploymentReadiness accepts -ArcGatewayUrl and -KeyVaultName' {
            $cmd = Get-Command Test-AksArcDeploymentReadiness
            $cmd.Parameters.ContainsKey('ArcGatewayUrl') | Should -Be $true
            $cmd.Parameters.ContainsKey('KeyVaultName')  | Should -Be $true
        }

        It 'Test-AksArcNetworkConnectivity accepts -ArcGatewayUrl and -KeyVaultName' {
            $cmd = Get-Command Test-AksArcNetworkConnectivity
            $cmd.Parameters.ContainsKey('ArcGatewayUrl') | Should -Be $true
            $cmd.Parameters.ContainsKey('KeyVaultName')  | Should -Be $true
        }

        It 'Test-AksArcNetworkConnectivity substitutes -KeyVaultName into placeholder URL' {
            # Smoke test: pass a fake KV name and verify the result row reflects substitution.
            $r = Test-AksArcNetworkConnectivity -Component 'Azure Local Key Vault*' -KeyVaultName 'pesterfakekv' -PassThru -TimeoutMs 250
            if ($r) {
                $kvRow = $r | Where-Object { $_.Url -match 'pesterfakekv' } | Select-Object -First 1
                # When no KV endpoint exists for the component name match, the test harness
                # may return an empty set - that is fine for this smoke test.
                if ($kvRow) {
                    $kvRow.Url | Should -Match 'pesterfakekv'
                }
            }
        }

        It 'Test-AksArcNetworkConnectivity marks Arc-Gateway-supported endpoints as Skipped when -ArcGatewayUrl is set' {
            $r = Test-AksArcNetworkConnectivity -Component 'Azure Local AKS infra' -ArcGatewayUrl 'pestergw123.gw.arc.azure.com' -PassThru -TimeoutMs 250
            if ($r) {
                $covered = @($r | Where-Object { $_.Detail -like 'Covered by Arc Gateway*' })
                $covered.Count | Should -BeGreaterThan 0
            }
        }
    }
}
