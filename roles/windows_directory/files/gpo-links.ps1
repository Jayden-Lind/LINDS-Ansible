[CmdletBinding(SupportsShouldProcess)]
param([string]$Base, [string]$Links)
$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy
$Ansible.Changed = $false
$changes = @()
$wanted = $Links | ConvertFrom-Json
foreach ($container in $wanted.PSObject.Properties) {
    $target = if ($container.Name -eq 'domain') { $Base } else { "$($container.Name),$Base" }
    $have = @((Get-GPInheritance -Target $target).GpoLinks | Sort-Object Order)
    $want = @($container.Value)
    for ($i = 0; $i -lt $want.Count; $i++) {
        $name = $want[$i].gpo
        $enabled  = if ($null -eq $want[$i].enabled)  { 'Yes' } elseif ($want[$i].enabled)  { 'Yes' } else { 'No' }
        $enforced = if ($want[$i].enforced) { 'Yes' } else { 'No' }
        $order = $i + 1
        $link = $have | Where-Object DisplayName -eq $name
        if (-not $link) {
            $changes += "link '$name' to $target at $order"
            if ($PSCmdlet.ShouldProcess($target, "link $name")) {
                New-GPLink -Name $name -Target $target -LinkEnabled $enabled -Enforced $enforced -Order $order | Out-Null
            }
        } elseif ($link.Order -ne $order -or $link.Enabled -ne ($enabled -eq 'Yes') -or $link.Enforced -ne ($enforced -eq 'Yes')) {
            $changes += "'$name' on ${target}: order $($link.Order)->$order, enabled $($link.Enabled)->$enabled, enforced $($link.Enforced)->$enforced"
            if ($PSCmdlet.ShouldProcess($target, "correct link $name")) {
                Set-GPLink -Name $name -Target $target -LinkEnabled $enabled -Enforced $enforced -Order $order | Out-Null
            }
        }
    }
    # A script block, not `ForEach-Object gpo`: that form honours -WhatIf and
    # returns nothing in check mode, which made every link look unwanted.
    $names = @($want | ForEach-Object { $_.gpo })
    foreach ($extra in $have | Where-Object { $_.DisplayName -notin $names }) {
        $changes += "unlink '$($extra.DisplayName)' from $target (not in the code)"
        if ($PSCmdlet.ShouldProcess($target, "unlink $($extra.DisplayName)")) {
            Remove-GPLink -Guid $extra.GpoId -Target $target | Out-Null
        }
    }
}
$Ansible.Changed = $changes.Count -gt 0
$changes
