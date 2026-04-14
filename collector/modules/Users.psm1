# Users.psm1 — AD User data collection helpers

function Get-UsersData {
    [CmdletBinding()]
    param(
        [hashtable]$CommonParams = @{},
        [int]$Limit = 5000
    )

    Get-ADUser -Filter * -Properties Enabled, PasswordNeverExpires, LockedOut,
        LastLogonDate, PasswordLastSet, Description, mail, adminCount, SIDHistory @CommonParams |
        Select-Object -First $Limit |
        ForEach-Object {
            [PSCustomObject]@{
                SamAccountName       = $_.SamAccountName
                DisplayName          = $_.DisplayName
                UserPrincipalName    = $_.UserPrincipalName
                DistinguishedName    = $_.DistinguishedName
                Mail                 = $_.mail
                Enabled              = $_.Enabled
                PasswordNeverExpires = $_.PasswordNeverExpires
                LockedOut            = $_.LockedOut
                LastLogonDate        = $_.LastLogonDate
                PasswordLastSet      = $_.PasswordLastSet
                Description          = $_.Description
                AdminCount           = $_.adminCount
                SIDHistory           = @($_.SIDHistory | ForEach-Object { $_.Value })
            }
        }
}

function Get-PrivilegedAccountsData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $groups = @(
        "Domain Admins", "Enterprise Admins", "Schema Admins",
        "Administrators", "Account Operators", "Backup Operators",
        "Print Operators", "Server Operators"
    )

    $seen = @{}
    foreach ($group in $groups) {
        try {
            Get-ADGroupMember -Identity $group -Recursive @CommonParams |
                Where-Object { $_.objectClass -eq "user" } |
                ForEach-Object {
                    if (-not $seen[$_.SamAccountName]) {
                        $seen[$_.SamAccountName] = $true
                        [PSCustomObject]@{
                            SamAccountName = $_.SamAccountName
                            Group          = $group
                        }
                    }
                }
        } catch {
            Write-Warning "Could not enumerate group '$group': $_"
        }
    }
}

Export-ModuleMember -Function Get-UsersData, Get-PrivilegedAccountsData
