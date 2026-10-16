[CmdletBinding(SupportsShouldProcess)]
param([string]$Shares)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$changes = @()
foreach ($want in ($Shares | ConvertFrom-Json)) {
    if (-not (Test-Path -LiteralPath $want.path)) { throw "$($want.path), the path of share $($want.name), does not exist." }
    $share = Get-SmbShare -Name $want.name -ErrorAction SilentlyContinue
    $abe = if ($want.access_based_enumeration) { 'AccessBased' } else { 'Unrestricted' }
    if (-not $share) {
        $changes += "create share $($want.name) at $($want.path)"
        if ($PSCmdlet.ShouldProcess($want.name, 'create share')) {
            # Created with nobody on it; the permissions follow.
            New-SmbShare -Name $want.name -Path $want.path -Description "$($want.description)" -FolderEnumerationMode $abe | Out-Null
            Get-SmbShareAccess -Name $want.name | ForEach-Object { Revoke-SmbShareAccess -Name $want.name -AccountName $_.AccountName -Force | Out-Null }
        } else { continue }
    } elseif ($share.Path -ne $want.path) {
        throw "Share $($want.name) exists at $($share.Path), not $($want.path). Remove it by hand if that is meant."
    } elseif ("$($share.Description)" -ne "$($want.description)" -or "$($share.FolderEnumerationMode)" -ne $abe) {
        $changes += "share $($want.name): description or enumeration mode"
        if ($PSCmdlet.ShouldProcess($want.name, 'update share')) {
            Set-SmbShare -Name $want.name -Description "$($want.description)" -FolderEnumerationMode $abe -Force | Out-Null
        }
    }
    $have = @(Get-SmbShareAccess -Name $want.name -ErrorAction SilentlyContinue | Where-Object AccessControlType -eq 'Allow')
    foreach ($p in $want.permissions) {
        $current = $have | Where-Object AccountName -eq $p.who
        if (-not $current -or "$($current.AccessRight)" -ne $p.rights) {
            $changes += "share $($want.name): $($p.who) = $($p.rights)"
            if ($PSCmdlet.ShouldProcess($want.name, "grant $($p.who)")) {
                if ($current) { Revoke-SmbShareAccess -Name $want.name -AccountName $p.who -Force | Out-Null }
                Grant-SmbShareAccess -Name $want.name -AccountName $p.who -AccessRight $p.rights -Force | Out-Null
            }
        }
    }
    $names = @($want.permissions | ForEach-Object { $_.who })
    foreach ($extra in $have | Where-Object { $_.AccountName -notin $names }) {
        $changes += "share $($want.name): remove $($extra.AccountName)"
        if ($PSCmdlet.ShouldProcess($want.name, "revoke $($extra.AccountName)")) {
            Revoke-SmbShareAccess -Name $want.name -AccountName $extra.AccountName -Force | Out-Null
        }
    }
}
$Ansible.Changed = $changes.Count -gt 0
$changes
