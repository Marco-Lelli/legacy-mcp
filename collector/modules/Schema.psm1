# Schema.psm1 — AD Schema extensions data collection helpers

function Get-SchemaExtensionsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $schemaDN = (Get-ADRootDSE @CommonParams).schemaNamingContext

    # Custom extensions are identified by OID prefix: exclude Microsoft-reserved
    # subtrees (1.2.840.113556 Windows/Exchange, 2.16.840.1.101.2 US DoD,
    # 1.3.6.1.4.1.311 Microsoft vendor arc). governsID applies to classSchema;
    # attributeID applies to attributeSchema.
    Get-ADObject -SearchBase $schemaDN -Filter * `
        -Properties lDAPDisplayName, objectClass, adminDescription,
                    governsID, attributeID @CommonParams |
        Where-Object {
            $oid = if ($_.governsID) { $_.governsID } else { $_.attributeID }
            $oid -and
            -not $oid.StartsWith("1.2.840.113556") -and
            -not $oid.StartsWith("2.16.840.1.101.2") -and
            -not $oid.StartsWith("1.3.6.1.4.1.311")
        } |
        Select-Object -First 500 |
        ForEach-Object {
            [PSCustomObject]@{
                lDAPDisplayName  = $_.lDAPDisplayName
                ObjectClass      = $_.objectClass
                AdminDescription = $_.adminDescription
                GovernsID        = $_.governsID
                AttributeID      = $_.attributeID
            }
        }
}

function Get-SchemaProductPresenceData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $schemaDN = (Get-ADRootDSE @CommonParams).schemaNamingContext

    function Test-SchemaObject {
        param([string]$LdapName)
        try {
            $obj = Get-ADObject -SearchBase $schemaDN `
                -Filter "lDAPDisplayName -eq '$LdapName'" @CommonParams
            return ($null -ne $obj)
        } catch {
            return $false
        }
    }

    $lapsLegacy  = Test-SchemaObject "ms-Mcs-AdmPwd"
    $lapsWindows = Test-SchemaObject "msLAPS-Password"
    $exchange    = Test-SchemaObject "msExchMailboxGuid"
    $sccm        = Test-SchemaObject "mSSMSSite"
    $lync        = Test-SchemaObject "msRTCSIP-UserEnabled"
    $adConnect   = Test-SchemaObject "msDS-ExternalDirectoryObjectId"

    [PSCustomObject]@{
        LAPS_Legacy    = $lapsLegacy
        LAPS_Windows   = $lapsWindows
        Exchange       = $exchange
        SCCM           = $sccm
        Lync_SfB       = $lync
        AzureADConnect = $adConnect
    }
}

Export-ModuleMember -Function Get-SchemaExtensionsData, Get-SchemaProductPresenceData
