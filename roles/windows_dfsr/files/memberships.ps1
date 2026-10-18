# SupportsShouldProcess: without it, win_powershell does not run the script in
# check mode. The script reads $Ansible.CheckMode itself.
[CmdletBinding(SupportsShouldProcess)]
param([string]$Group, [string[]]$Folders, [hashtable]$MemberRoots,
      [int]$StagingQuota, [hashtable]$StagingOverrides, [int]$ConflictQuota,
      [hashtable]$InitialPrimary)
$ErrorActionPreference = 'Stop'
Import-Module DFSR
$Ansible.Changed = $false

foreach ($member in $MemberRoots.Keys) {
    $root = $MemberRoots[$member]
    foreach ($f in $Folders) {
        $want = "$root\$f"
        $staging = if ($StagingOverrides.ContainsKey($f)) { [int]$StagingOverrides[$f] } else { $StagingQuota }
        # Get-DfsrMembership has no -FolderName; it returns every folder's
        # membership for the member, so pick this folder's out of that.
        $have = Get-DfsrMembership -GroupName $Group -ComputerName $member -ErrorAction Stop |
                  Where-Object { $_.FolderName -eq $f }

        # Not $args - that is an automatic variable, and splatting it
        # would not refer to this hashtable.
        $set = @{}
        if ($have.ContentPath -ne $want)                          { $set.ContentPath = $want }
        # A membership without a content path is new. If this folder's
        # data is on one member only, that member becomes primary now,
        # and the others must not hold the folder yet: whatever they
        # held would be set aside in PreExisting.
        if (-not $have.ContentPath -and $InitialPrimary.ContainsKey($f)) {
            if ($InitialPrimary[$f] -ieq $member) {
                $set.PrimaryMember = $true
            } else {
                $unc = "\\$member\$($root.TrimEnd(':'))`$\$f"
                if ((Test-Path -LiteralPath $unc) -and (Get-ChildItem -LiteralPath $unc -Force | Select-Object -First 1)) {
                    throw "$f already holds files on $member ($unc), and $($InitialPrimary[$f]) is to be its primary. Empty or move it first."
                }
            }
        }
        if ($have.StagingPathQuotaInMB -ne $staging)              { $set.StagingPathQuotaInMB = $staging }
        if ($have.ConflictAndDeletedQuotaInMB -ne $ConflictQuota) { $set.ConflictAndDeletedQuotaInMB = $ConflictQuota }
        if (-not $have.Enabled)                                   { $set.DisableMembership = $false }

        if ($set.Count) {
            if (-not $Ansible.CheckMode) {
                Set-DfsrMembership -GroupName $Group -FolderName $f -ComputerName $member `
                    @set -Force | Out-Null
            }
            "$member/$f -> $($set.Keys -join ',')"
            $Ansible.Changed = $true
        }
    }
}
