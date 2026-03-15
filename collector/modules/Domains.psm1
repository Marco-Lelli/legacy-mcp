# Domains.psm1 — Domain and password policy data collection helpers

function Get-DomainData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADDomain @CommonParams | ForEach-Object {
        [PSCustomObject]@{
            Name                 = $_.Name
            DNSRoot              = $_.DNSRoot
            DomainMode           = $_.DomainMode.ToString()
            PDCEmulator          = $_.PDCEmulator
            RIDMaster            = $_.RIDMaster
            InfrastructureMaster = $_.InfrastructureMaster
            ChildDomains         = $_.ChildDomains -join ", "
            Forest               = $_.Forest
        }
    }
}

function Get-DefaultPasswordPolicyData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $policy = Get-ADDefaultDomainPasswordPolicy @CommonParams
    $domain = (Get-ADDomain @CommonParams).DNSRoot
    [PSCustomObject]@{
        Domain                     = $domain
        MinPasswordLength          = $policy.MinPasswordLength
        PasswordHistoryCount       = $policy.PasswordHistoryCount
        MaxPasswordAge             = $policy.MaxPasswordAge.Days
        MinPasswordAge             = $policy.MinPasswordAge.Days
        ComplexityEnabled          = $policy.ComplexityEnabled
        ReversibleEncryptionEnabled = $policy.ReversibleEncryptionEnabled
        LockoutThreshold           = $policy.LockoutThreshold
        LockoutDuration            = $policy.LockoutDuration.Minutes
        LockoutObservationWindow   = $policy.LockoutObservationWindow.Minutes
    }
}

Export-ModuleMember -Function Get-DomainData, Get-DefaultPasswordPolicyData
