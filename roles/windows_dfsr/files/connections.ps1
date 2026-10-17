param([string]$Group, [object[]]$Connections, [bool]$Rdc)
$ErrorActionPreference = 'Stop'
Import-Module DFSR
$Ansible.Changed = $false

foreach ($c in $Connections) {
    $existing = Get-DfsrConnection -GroupName $Group `
                  -SourceComputerName $c.source `
                  -DestinationComputerName $c.destination -ErrorAction SilentlyContinue

    if (-not $existing) {
        Add-DfsrConnection -GroupName $Group `
            -SourceComputerName $c.source -DestinationComputerName $c.destination | Out-Null
        "created $($c.source) -> $($c.destination)"
        $Ansible.Changed = $true
        continue
    }

    if (-not $existing.Enabled -or $existing.RdcEnabled -ne $Rdc) {
        Set-DfsrConnection -GroupName $Group `
            -SourceComputerName $c.source -DestinationComputerName $c.destination `
            -DisableConnection $false -DisableRDC (-not $Rdc) | Out-Null
        "updated $($c.source) -> $($c.destination)"
        $Ansible.Changed = $true
    }
}
