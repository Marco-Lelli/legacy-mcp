# Forest.psm1 — AD Forest data collection helpers
# Called by Collect-ADData.ps1
#
# Get-ADForest must ALWAYS be called with -Identity here. Without it the cmdlet
# binds to its "Current" parameter set and returns the forest of the
# LocalComputer/LoggedOnUser -- the caller's forest -- regardless of -Server.
# In a cross-forest collection that is the wrong forest entirely: the field
# JSON described "auslromagna.it" (caller) while collecting "ausl.fo.it"
# (target). The target forest is derived from the target domain, which does
# honour -Server, via Get-ADDomain(.Forest).

# Resolve the DNS name of the forest the TARGET domain belongs to.
function Resolve-TargetForestName {
    param([hashtable]$CommonParams = @{})
    return (Get-ADDomain @CommonParams).Forest
}

function Get-ForestData {
    [CmdletBinding()]
    param(
        [hashtable]$CommonParams = @{},
        # Supplied by Collect-ADData.ps1, which has already resolved it, so the
        # metadata and this section cannot disagree. Resolved locally when the
        # module is used standalone.
        [string]$ForestName
    )

    if (-not $ForestName) { $ForestName = Resolve-TargetForestName -CommonParams $CommonParams }

    $forest    = Get-ADForest -Identity $ForestName @CommonParams
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

function Get-FSMOForestData {
    [CmdletBinding()]
    param(
        [hashtable]$CommonParams = @{},
        [string]$ForestName
    )

    # Same defect as Get-ForestData: without -Identity this reported the FSMO
    # role holders of the CALLER's forest, leaving fsmo_roles contradicting the
    # forest section in the same JSON.
    if (-not $ForestName) { $ForestName = Resolve-TargetForestName -CommonParams $CommonParams }

    $forest = Get-ADForest -Identity $ForestName @CommonParams
    [ordered]@{
        SchemaMaster       = $forest.SchemaMaster
        DomainNamingMaster = $forest.DomainNamingMaster
    }
}

Export-ModuleMember -Function Get-ForestData, Get-OptionalFeaturesData, `
    Get-FSMOForestData, Resolve-TargetForestName
