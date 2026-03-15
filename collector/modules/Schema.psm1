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

Export-ModuleMember -Function Get-SchemaExtensionsData
