# Schema.psm1 — AD Schema extensions data collection helpers

function Get-SchemaExtensionsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $schemaDN = (Get-ADRootDSE @CommonParams).schemaNamingContext

    # Return schema objects that have a non-null adminDescription (often custom extensions)
    Get-ADObject -SearchBase $schemaDN -Filter { adminDescription -like "*" } `
        -Properties lDAPDisplayName, objectClass, adminDescription, isSingleValued @CommonParams |
        Select-Object -First 200 |
        ForEach-Object {
            [PSCustomObject]@{
                lDAPDisplayName  = $_.lDAPDisplayName
                ObjectClass      = $_.ObjectClass
                AdminDescription = $_.adminDescription
                IsSingleValued   = $_.isSingleValued
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
