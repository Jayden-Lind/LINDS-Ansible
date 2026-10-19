[CmdletBinding(SupportsShouldProcess)]
param([string]$Folders, [string]$Broad)
# Makes the NTFS permissions of each listed folder exact. Below each folder
# with clean_below, it removes the own entries for broad identities (Everyone,
# Users, ...). See roles/windows_fileserver/README.md.
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$IdType = [Security.Principal.SecurityIdentifier]

function Get-Sid([string]$Name) {
    if ($Name -match '^S-1-') { return New-Object Security.Principal.SecurityIdentifier $Name }
    (New-Object Security.Principal.NTAccount $Name).Translate($IdType)
}

# Long-path syntax: some folders are deeper than 260 characters.
function Get-LongPath([string]$Path) { if ($Path.StartsWith('\\?\')) { $Path } else { '\\?\' + $Path } }

function Get-RuleKey($Rule) {
    '{0}|{1}|{2}|{3}|{4}' -f $Rule.IdentityReference.Value, [int]$Rule.FileSystemRights,
        [int]$Rule.InheritanceFlags, [int]$Rule.PropagationFlags, $Rule.AccessControlType
}

# PowerShell 5.1 gives a JSON array to the pipeline as one object: use foreach.
$wanted = @(foreach ($f in ($Folders | ConvertFrom-Json)) { $f })
$broadSids = foreach ($name in ($Broad | ConvertFrom-Json)) { (Get-Sid $name).Value }
# A managed folder gives these to all items below it. Below the folder, an own
# entry for one of them is a copy, and the script removes it with the broad one.
$copySids = $broadSids + @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-3-1')
$managedPaths = @($wanted | ForEach-Object { (Get-LongPath $_.path).TrimEnd('\').ToLowerInvariant() })

$changes = New-Object Collections.Generic.List[string]
$problems = New-Object Collections.Generic.List[string]

foreach ($folder in $wanted) {
    $path = Get-LongPath $folder.path
    if (-not [IO.Directory]::Exists($path)) { $problems.Add("$($folder.path): the folder does not exist"); continue }

    # 1. The folder itself: SYSTEM and Administrators with full control, then
    #    the listed rules. It does not inherit from its parent.
    $want = New-Object Security.AccessControl.DirectorySecurity
    $want.SetAccessRuleProtection($true, $false)
    $rules = @(@{ who = 'S-1-5-18'; rights = 'FullControl' }, @{ who = 'S-1-5-32-544'; rights = 'FullControl' }) + @($folder.rules)
    foreach ($r in $rules) {
        $inherit = if ($r.inherit) { $r.inherit } else { 'ContainerInherit, ObjectInherit' }
        $propagation = if ($r.propagation) { $r.propagation } else { 'None' }
        $want.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((Get-Sid $r.who),
            [Security.AccessControl.FileSystemRights]$r.rights, [Security.AccessControl.InheritanceFlags]$inherit,
            [Security.AccessControl.PropagationFlags]$propagation, 'Allow')))
    }
    $have = [IO.Directory]::GetAccessControl($path, 'Access')
    $wantKeys = @($want.GetAccessRules($true, $false, $IdType) | ForEach-Object { Get-RuleKey $_ } | Sort-Object) -join ';'
    $haveKeys = @($have.GetAccessRules($true, $false, $IdType) | ForEach-Object { Get-RuleKey $_ } | Sort-Object) -join ';'
    if ($wantKeys -ne $haveKeys -or -not $have.AreAccessRulesProtected) {
        $changes.Add("$($folder.path): set the permissions")
        # Windows also gives the new inherited entries to all items below.
        if ($PSCmdlet.ShouldProcess($folder.path, 'set the permissions')) { [IO.Directory]::SetAccessControl($path, $want) }
    }

    if (-not $folder.clean_below) { continue }

    # 2. The items below. An item with an own entry for a broad identity loses
    #    that entry and its copies, and inherits again. An item without one
    #    stays as it is, also if it does not inherit (a folder that someone
    #    made private on purpose). The script does not go into links (also
    #    DfsrPrivate is one), or folders that have their own entry in the list.
    $fixed = 0; $seen = 0; $kept = New-Object Collections.Generic.List[string]
    $stack = New-Object Collections.Generic.Stack[string]
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $entries = (New-Object IO.DirectoryInfo $dir).GetFileSystemInfos() }
        catch { $problems.Add("$($dir.Substring(4)): cannot list: $($_.Exception.Message)"); continue }
        foreach ($item in $entries) {
            $seen++
            $isDir = [bool]($item.Attributes -band [IO.FileAttributes]::Directory)
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($isDir -and $managedPaths -contains $item.FullName.ToLowerInvariant()) { continue }
            try {
                $sec = if ($isDir) { [IO.Directory]::GetAccessControl($item.FullName, 'Access') } else { [IO.File]::GetAccessControl($item.FullName, 'Access') }
                $own = @($sec.GetAccessRules($true, $false, $IdType))
                if (@($own | Where-Object { $broadSids -contains $_.IdentityReference.Value }).Count -gt 0) {
                    foreach ($sid in $copySids) { $sec.PurgeAccessRules((New-Object Security.Principal.SecurityIdentifier $sid)) }
                    $sec.SetAccessRuleProtection($false, $false)
                    $fixed++
                    if (-not $WhatIfPreference) {
                        if ($isDir) { [IO.Directory]::SetAccessControl($item.FullName, $sec) } else { [IO.File]::SetAccessControl($item.FullName, $sec) }
                    }
                } elseif ($sec.AreAccessRulesProtected -and $kept.Count -lt 20) {
                    $kept.Add($item.FullName.Substring(4))
                }
            } catch { $problems.Add("$($item.FullName.Substring(4)): $($_.Exception.Message)") }
            if ($isDir) { $stack.Push($item.FullName) }
        }
    }
    if ($fixed -gt 0) { $changes.Add("$($folder.path): removed the broad entries from $fixed of the $seen items below") }
    foreach ($k in $kept) { $changes.Add("$($folder.path): kept, does not inherit and has no broad entry: $k") }
}

$Ansible.Changed = @($changes | Where-Object { $_ -notmatch ': kept, ' }).Count -gt 0
$changes
if ($problems.Count -gt 0) {
    $problems | Select-Object -First 20 | ForEach-Object { Write-Warning $_ }
    throw "$($problems.Count) items could not be read or changed. Fix them and run the role again."
}
