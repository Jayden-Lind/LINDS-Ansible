# List the GPO links in the listed containers that are not in the code.
# "domain" is the domain root. It changes nothing.
param([string]$Base, [string]$Links)
$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy
$Ansible.Changed = $false
$wanted = $Links | ConvertFrom-Json
foreach ($container in $wanted.PSObject.Properties) {
    $target = if ($container.Name -eq 'domain') { $Base } else { "$($container.Name),$Base" }
    $names = @($container.Value | ForEach-Object { $_.gpo })
    foreach ($link in @((Get-GPInheritance -Target $target).GpoLinks | Where-Object { $_.DisplayName -notin $names })) {
        [pscustomobject]@{ target = $target; gpo = $link.DisplayName; guid = "$($link.GpoId)" }
    }
}
