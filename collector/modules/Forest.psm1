# Forest.psm1 — AD Forest data collection helpers
# Called by Collect-ADData.ps1

function Get-ForestData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $forest    = Get-ADForest @CommonParams
    $rootDSE   = Get-ADRootDSE @CommonParams
    $schemaObj = Get-ADObject $rootDSE.schemaNamingContext `
        -Properties objectVersion @CommonParams

    # Tombstone lifetime -- stored in CN=Directory Service,CN=Windows NT,CN=Services,<configNC>
    $configNC  = $rootDSE.configurationNamingContext
    $dsSvcDN   = "CN=Directory Service,CN=Windows NT,CN=Services,$configNC"
    $tombstone = $null
    try {
        $dsObj    = Get-ADObject $dsSvcDN -Properties tombstoneLifetime @CommonParams
        $tombstone = if ($null -ne $dsObj.tombstoneLifetime -and $dsObj.tombstoneLifetime -gt 0) {
            [int]$dsObj.tombstoneLifetime
        } else {
            180  # AD default when tombstoneLifetime attribute is not explicitly set
        }
    } catch {
        $tombstone = $null
    }

    [PSCustomObject]@{
        Name                  = $forest.Name
        ForestMode            = $forest.ForestMode.ToString()
        SchemaMaster          = $forest.SchemaMaster
        DomainNamingMaster    = $forest.DomainNamingMaster
        Sites                 = $forest.Sites -join ", "
        Domains               = $forest.Domains -join ", "
        GlobalCatalogs        = $forest.GlobalCatalogs -join ", "
        SchemaVersion         = $schemaObj.objectVersion
        # New fields -- Webster gap closure
        SPNSuffixes           = $forest.SPNSuffixes -join ", "
        UPNSuffixes           = $forest.UPNSuffixes -join ", "
        ApplicationPartitions = $forest.ApplicationPartitions -join ", "
        TombstoneLifetime     = $tombstone
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
