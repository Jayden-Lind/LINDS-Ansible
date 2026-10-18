# Remove registry policy values from GPOs that this repository does not own.
# Each item is {gpo, key, name}.
# SupportsShouldProcess: without it, win_powershell does not run the script in
# check mode. The script reads $Ansible.CheckMode itself.
[CmdletBinding(SupportsShouldProcess)]
param([string]$Values)
$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy
$Ansible.Changed = $false
# A lookup that finds nothing returns nothing. Some GroupPolicy cmdlets throw
# for a missing item, and SilentlyContinue does not stop all of them.
function Quiet([scriptblock]$Block) { try { & $Block } catch { } }
$found = @()
# Windows PowerShell 5.1 gives a JSON array as one object. Assign it first, so
# that foreach goes through the items.
$items = $Values | ConvertFrom-Json
foreach ($v in $items) {
    if (Quiet { Get-GPRegistryValue -Name $v.gpo -Key $v.key -ValueName $v.name }) {
        $found += "remove $($v.key)\$($v.name) from '$($v.gpo)'"
        if (-not $Ansible.CheckMode) { Remove-GPRegistryValue -Name $v.gpo -Key $v.key -ValueName $v.name | Out-Null }
    }
}
$Ansible.Changed = $found.Count -gt 0
$found
