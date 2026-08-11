# Schema.psm1 -- AD Schema extensions data collection helpers

# Explicit dependency: this module calls Write-SafeCollectorLog. Importing it
# here makes the module self-sufficient (Principle 18 -- a module must never
# rely on another module's function having already been loaded by whatever
# happens to import it first).
Import-Module (Join-Path $PSScriptRoot "Logging.psm1") -Force

function Get-SchemaExtensionsData {
    [CmdletBinding()]
    param(
        [hashtable]$CommonParams = @{},
        # Default cap, unlike Users/Computers (#128, unlimited by default):
        # few organizations have hundreds of custom schema extensions, so a
        # default cap is a reasonable safety net here, not a silent data-loss
        # risk. 0 = unlimited, explicit override for the rare environment
        # that needs it.
        [int]$Limit = 500
    )

    $schemaDN = (Get-ADRootDSE @CommonParams).schemaNamingContext

    # Custom extensions are identified by OID prefix: exclude Microsoft-reserved
    # subtrees (1.2.840.113556 Windows/Exchange, 2.16.840.1.101.2 US DoD,
    # 1.3.6.1.4.1.311 Microsoft vendor arc). governsID applies to classSchema;
    # attributeID applies to attributeSchema.
    $allExtensions = @(Get-ADObject -SearchBase $schemaDN -Filter * `
        -Properties lDAPDisplayName, objectClass, adminDescription,
                    governsID, attributeID @CommonParams |
        Where-Object {
            $oid = if ($_.governsID) { $_.governsID } else { $_.attributeID }
            $oid -and
            -not $oid.StartsWith("1.2.840.113556") -and
            -not $oid.StartsWith("2.16.840.1.101.2") -and
            -not $oid.StartsWith("1.3.6.1.4.1.311")
        })

    $result = $allExtensions
    if ($Limit -gt 0 -and $allExtensions.Count -gt $Limit) {
        Write-SafeCollectorLog -Level WARN -Section "Schema" `
            -Message "Schema extensions: $($allExtensions.Count) found, truncated to $Limit -- use -Limit 0 for a complete collection"
        $result = $allExtensions | Select-Object -First $Limit
    }

    $result | ForEach-Object {
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
