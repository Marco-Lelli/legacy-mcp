# FGPP.psm1 — Fine-Grained Password Policy data collection helpers

function Get-FGPPData {
    [CmdletBinding()]
    param([hashtable]$CommonParams = @{})

    Get-ADFineGrainedPasswordPolicy -Filter * @CommonParams | ForEach-Object {
        $pso = $_
        $appliesTo = try {
            (Get-ADFineGrainedPasswordPolicySubject $pso @CommonParams).Name -join ", "
        } catch { "" }

        [PSCustomObject]@{
            Name                        = $pso.Name
            Precedence                  = $pso.Precedence
            MinPasswordLength           = $pso.MinPasswordLength
            PasswordHistoryCount        = $pso.PasswordHistoryCount
            MaxPasswordAgeDays          = $pso.MaxPasswordAge.Days
            MinPasswordAgeDays          = $pso.MinPasswordAge.Days
            ComplexityEnabled           = $pso.ComplexityEnabled
            ReversibleEncryptionEnabled = $pso.ReversibleEncryptionEnabled
            LockoutThreshold            = $pso.LockoutThreshold
            LockoutDurationMinutes      = $pso.LockoutDuration.Minutes
            LockoutObservationMinutes   = $pso.LockoutObservationWindow.Minutes
            AppliesTo                   = $appliesTo
        }
    }
}

Export-ModuleMember -Function Get-FGPPData
