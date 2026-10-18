# Make a WMI filter, or correct its query. The GroupPolicy module has no
# cmdlet for WMI filters; they are msWMI-Som objects in the System container.
# SupportsShouldProcess: without it, win_powershell does not run the script in
# check mode. The script reads $Ansible.CheckMode itself.
[CmdletBinding(SupportsShouldProcess)]
param([string]$Name, [string]$Description, [string]$Query)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$Ansible.Changed = $false
$domain = (Get-ADDomain).DistinguishedName
$container = "CN=SOM,CN=WMIPolicy,CN=System,$domain"
$parm2 = "1;3;10;$($Query.Length);WQL;root\CIMv2;$Query;"
$existing = Get-ADObject -SearchBase $container -Filter "msWMI-Name -eq '$Name'" -Properties 'msWMI-Parm1', 'msWMI-Parm2'
$now = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss.ffffff-000')
if (-not $existing) {
    $id = "{$([guid]::NewGuid().ToString().ToUpper())}"
    if (-not $Ansible.CheckMode) {
        New-ADObject -Name $id -Type 'msWMI-Som' -Path $container -OtherAttributes @{
            'msWMI-Name' = $Name; 'msWMI-Parm1' = $Description; 'msWMI-Parm2' = $parm2
            'msWMI-Author' = 'LINDS-Ansible'; 'msWMI-ID' = $id; 'instanceType' = 4
            'showInAdvancedViewOnly' = 'TRUE'; 'msWMI-ChangeDate' = $now; 'msWMI-CreationDate' = $now
        }
    }
    $Ansible.Changed = $true
    "made the WMI filter '$Name'"
} elseif ($existing.'msWMI-Parm2' -ne $parm2 -or $existing.'msWMI-Parm1' -ne $Description) {
    if (-not $Ansible.CheckMode) {
        Set-ADObject -Identity $existing.DistinguishedName -Replace @{ 'msWMI-Parm1' = $Description; 'msWMI-Parm2' = $parm2; 'msWMI-ChangeDate' = $now }
    }
    $Ansible.Changed = $true
    "corrected the WMI filter '$Name'"
}
