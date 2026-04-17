# Domains.psm1 — Domain and password policy data collection helpers

function Get-DomainData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    $domain  = Get-ADDomain @CommonParams
    $rootDSE = Get-ADRootDSE @CommonParams

    # MachineAccountQuota -- raw LDAP attribute on domain root object
    $domainObj = Get-ADObject $rootDSE.defaultNamingContext `
        -Properties "ms-DS-MachineAccountQuota" @CommonParams
    $maq = $domainObj."ms-DS-MachineAccountQuota"

    [PSCustomObject]@{
        Name                 = $domain.Name
        DNSRoot              = $domain.DNSRoot
        NetBIOSName          = $domain.NetBIOSName
        DomainSID            = $domain.DomainSID.Value
        DomainMode           = $domain.DomainMode.ToString()
        PDCEmulator          = $domain.PDCEmulator
        RIDMaster            = $domain.RIDMaster
        InfrastructureMaster = $domain.InfrastructureMaster
        ChildDomains         = $domain.ChildDomains -join ", "
        Forest               = $domain.Forest
        # New fields -- Webster gap closure
        AllowedDNSSuffixes   = $domain.AllowedDNSSuffixes -join ", "
        MachineAccountQuota  = $maq
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
