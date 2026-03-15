# Forest.psm1 — AD Forest data collection helpers
# Called by Collect-ADData.ps1

function Get-ForestData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $forest = Get-ADForest @CommonParams
    $rootDSE = Get-ADRootDSE @CommonParams
    $schemaObj = Get-ADObject $rootDSE.schemaNamingContext -Properties objectVersion @CommonParams

    [PSCustomObject]@{
        Name                 = $forest.Name
        ForestMode           = $forest.ForestMode.ToString()
        SchemaMaster         = $forest.SchemaMaster
        DomainNamingMaster   = $forest.DomainNamingMaster
        Sites                = $forest.Sites -join ", "
        Domains              = $forest.Domains -join ", "
        GlobalCatalogs       = $forest.GlobalCatalogs -join ", "
        SchemaVersion        = $schemaObj.objectVersion
    }
}

function Get-OptionalFeaturesData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADOptionalFeature -Filter * @CommonParams | ForEach-Object {
        [PSCustomObject]@{
            Name    = $_.Name
            Enabled = $_.EnabledScopes.Count -gt 0
            Scopes  = $_.EnabledScopes -join ", "
        }
    }
}

Export-ModuleMember -Function Get-ForestData, Get-OptionalFeaturesData
