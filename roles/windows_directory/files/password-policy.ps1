[CmdletBinding(SupportsShouldProcess)]
param([string]$Policy)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$Ansible.Changed = $false
$changes = @()
$domain = Get-ADDomain
$want = $Policy | ConvertFrom-Json
if ($want.PSObject.Properties.Count) {
    $have = Get-ADDefaultDomainPasswordPolicy
    $now = [ordered]@{
        min_length = $have.MinPasswordLength; complexity = $have.ComplexityEnabled; history = $have.PasswordHistoryCount
        max_age_days = $have.MaxPasswordAge.Days; min_age_days = $have.MinPasswordAge.Days
        lockout_threshold = $have.LockoutThreshold; lockout_minutes = [int]$have.LockoutDuration.TotalMinutes
        lockout_window_minutes = [int]$have.LockoutObservationWindow.TotalMinutes; reversible_encryption = $have.ReversibleEncryptionEnabled
    }
    $different = @($now.Keys | Where-Object { $null -ne $want.$_ -and "$($want.$_)" -ne "$($now[$_])" })
    if ($different) {
        $changes += $different | ForEach-Object { "password policy ${_}: $($now[$_]) -> $($want.$_)" }
        if ($PSCmdlet.ShouldProcess($domain.DNSRoot, 'set the password policy')) {
            $merged = @{}; $now.Keys | ForEach-Object { $merged[$_] = if ($null -ne $want.$_) { $want.$_ } else { $now[$_] } }
            Set-ADDefaultDomainPasswordPolicy -Identity $domain.DistinguishedName `
                -MinPasswordLength $merged.min_length -ComplexityEnabled ([bool]$merged.complexity) -PasswordHistoryCount $merged.history `
                -MaxPasswordAge (New-TimeSpan -Days $merged.max_age_days) -MinPasswordAge (New-TimeSpan -Days $merged.min_age_days) `
                -LockoutThreshold $merged.lockout_threshold -LockoutDuration (New-TimeSpan -Minutes $merged.lockout_minutes) `
                -LockoutObservationWindow (New-TimeSpan -Minutes $merged.lockout_window_minutes) `
                -ReversibleEncryptionEnabled ([bool]$merged.reversible_encryption)
        }
    }
}
$Ansible.Changed = $changes.Count -gt 0
$changes
