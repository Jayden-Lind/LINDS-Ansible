param([string]$Machine)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$Ansible.Changed = $false
$removed = @()

if (Get-ADDomainController -Filter "Name -eq '$Machine'") {
    throw "$Machine is still listed as a domain controller; the demotion did not complete."
}

$account = Get-ADComputer -Filter "Name -eq '$Machine'"
if ($account) {
    # -Recursive: a computer account can own child objects (service
    # connection points, BitLocker keys).
    Remove-ADObject -Identity $account.DistinguishedName -Recursive -Confirm:$false
    $removed += "computer account"
}

$sites = 'CN=Sites,' + (Get-ADRootDSE).configurationNamingContext
foreach ($server in Get-ADObject -SearchBase $sites -LDAPFilter "(&(objectClass=server)(cn=$Machine))") {
    # Only an empty one: NTDS Settings underneath means it is still
    # a domain controller as far as replication is concerned.
    if (-not (Get-ADObject -SearchBase $server.DistinguishedName -SearchScope OneLevel -Filter *)) {
        Remove-ADObject -Identity $server.DistinguishedName -Confirm:$false
        $removed += "server object in $(($server.DistinguishedName -split ',')[2])"
    }
}

$Ansible.Changed = $removed.Count -gt 0
$removed
