# PKI.psm1 -- PKI / CA Discovery data collection helpers
# Covers: CN=Enrollment Services,CN=Public Key Services,CN=Services,CN=Configuration

function Get-PKIData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $configDN = (Get-ADRootDSE @CommonParams).configurationNamingContext
    $enrollmentDN = "CN=Enrollment Services,CN=Public Key Services,CN=Services,$configDN"

    try {
        $result = @(
            Get-ADObject -SearchBase $enrollmentDN -Filter "objectClass -eq 'pKIEnrollmentService'" @CommonParams |
                ForEach-Object {
                    [PSCustomObject]@{
                        Name              = $_.Name
                        DistinguishedName = $_.DistinguishedName
                        ObjectClass       = $_.ObjectClass
                    }
                }
        )
        return $result
    } catch {
        Write-Warning "PKI discovery failed: $_"
        @()
    }
}

Export-ModuleMember -Function Get-PKIData
