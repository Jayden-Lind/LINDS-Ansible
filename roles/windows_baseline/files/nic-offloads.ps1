# Keep the offloads of the VirtIO network adapter at the values in $Offloads.
# If a value changes, a scheduled task restarts the adapter 15 seconds later.
[CmdletBinding(SupportsShouldProcess)]
param([string]$Offloads)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$want = $Offloads | ConvertFrom-Json
$changes = @()
foreach ($nic in @(Get-NetAdapter | Where-Object InterfaceDescription -like 'Red Hat VirtIO Ethernet*')) {
    foreach ($p in $want.PSObject.Properties) {
        $have = Get-NetAdapterAdvancedProperty -Name $nic.Name -RegistryKeyword $p.Name -ErrorAction SilentlyContinue
        if ($have -and "$($have.RegistryValue)" -ne "$($p.Value)") {
            $changes += "$($nic.Name): $($p.Name) $($have.RegistryValue) -> $($p.Value)"
            if ($PSCmdlet.ShouldProcess($nic.Name, "set $($p.Name)")) {
                Set-NetAdapterAdvancedProperty -Name $nic.Name -RegistryKeyword $p.Name -RegistryValue "$($p.Value)" -NoRestart
            }
        }
    }
}
if ($changes.Count) {
    $Ansible.Changed = $true
    if ($PSCmdlet.ShouldProcess('VirtIO network adapters', 'restart')) {
        # The task restarts the adapters after this WinRM connection has ended.
        # Then it deletes itself.
        $restart = @'
Get-NetAdapter | Where-Object InterfaceDescription -like 'Red Hat VirtIO Ethernet*' | Restart-NetAdapter -Confirm:$false
Unregister-ScheduledTask -TaskName BaselineNicRestart -Confirm:$false
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($restart))
        Register-ScheduledTask -TaskName BaselineNicRestart -Force `
            -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest) `
            -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15)) `
            -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -NonInteractive -EncodedCommand $encoded") | Out-Null
    }
}
$changes
