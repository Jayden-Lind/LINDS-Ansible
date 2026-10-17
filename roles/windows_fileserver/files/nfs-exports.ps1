[CmdletBinding(SupportsShouldProcess)]
param([string]$Exports)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$changes = @()
foreach ($want in ($Exports | ConvertFrom-Json)) {
    $export = Get-NfsShare -Name $want.name -ErrorAction SilentlyContinue
    if (-not $export) {
        $changes += "create export $($want.name) at $($want.path)"
        if ($PSCmdlet.ShouldProcess($want.name, 'create export')) {
            New-NfsShare -Name $want.name -Path $want.path -Authentication @($want.authentication) `
                -EnableUnmappedAccess ([bool]$want.unmapped_user_access) -EnableAnonymousAccess ([bool]$want.anonymous_access) `
                -Permission no-access | Out-Null
        } else { continue }
    }
    $have = @(Get-NfsSharePermission -Name $want.name | Where-Object { $_.ClientType -ne 'builtin' })
    foreach ($c in $want.clients) {
        $current = $have | Where-Object ClientName -eq $c.client
        if (-not $current -or "$($current.Permission)" -ne $c.permission -or [bool]$current.AllowRootAccess -ne [bool]$c.root) {
            $changes += "export $($want.name): $($c.client) = $($c.permission), root $([bool]$c.root)"
            if ($PSCmdlet.ShouldProcess($want.name, "grant $($c.client)")) {
                Grant-NfsSharePermission -Name $want.name -ClientName $c.client -ClientType host -Permission $c.permission -AllowRootAccess ([bool]$c.root)
            }
        }
    }
    $names = @($want.clients | ForEach-Object { $_.client })
    foreach ($extra in $have | Where-Object { $_.ClientName -notin $names }) {
        $changes += "export $($want.name): remove $($extra.ClientName)"
        if ($PSCmdlet.ShouldProcess($want.name, "revoke $($extra.ClientName)")) {
            Revoke-NfsSharePermission -Name $want.name -ClientName $extra.ClientName -ClientType host
        }
    }
}
$Ansible.Changed = $changes.Count -gt 0
$changes
