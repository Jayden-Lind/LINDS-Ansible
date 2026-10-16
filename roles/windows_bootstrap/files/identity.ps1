param([string]$Hostname, [string]$Address, [int]$Prefix, [string]$Gateway, [string[]]$Dns)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false

$nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
$addressed = [bool](Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 |
                    Where-Object { $_.IPAddress -eq $Address -and $_.PrefixOrigin -eq 'Manual' })
$named = $env:COMPUTERNAME -ieq $Hostname
if ($addressed -and $named) { return }

$dnsList = ($Dns | ForEach-Object { "'$_'" }) -join ', '
@"
`$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\Windows\Temp\set-identity.log -Force
# Nothing may reach the machine between the change of address and the
# restart: whatever is waiting for the new address would find it, start
# work and be cut off. WinRM starts again by itself at boot.
Stop-Service -Name WinRM -Force
`$nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
Set-NetIPInterface -InterfaceIndex `$nic.ifIndex -AddressFamily IPv4 -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex `$nic.ifIndex -AddressFamily IPv4 | Remove-NetIPAddress -Confirm:`$false
Get-NetRoute -InterfaceIndex `$nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:`$false
New-NetIPAddress -InterfaceIndex `$nic.ifIndex -IPAddress '$Address' -PrefixLength $Prefix -DefaultGateway '$Gateway'
Set-DnsClientServerAddress -InterfaceIndex `$nic.ifIndex -ServerAddresses $dnsList
if (`$env:COMPUTERNAME -ine '$Hostname') { Rename-Computer -NewName '$Hostname' -Force }
Unregister-ScheduledTask -TaskName 'set-identity' -Confirm:`$false
Stop-Transcript
Restart-Computer -Force
"@ | Set-Content -Path C:\Windows\Temp\set-identity.ps1 -Encoding UTF8

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\set-identity.ps1'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(20)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
Register-ScheduledTask -TaskName 'set-identity' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
$Ansible.Changed = $true
