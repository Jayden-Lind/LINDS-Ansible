# Make one GPO agree with its definition: the GPO and its comment, its
# registry policy values and registry preference items (exact for each key
# that the definition names), the computers that apply it, and its WMI filter.
# The GPOs of this role have computer settings only, so the user half is off.
# SupportsShouldProcess: without it, win_powershell does not run the script in
# check mode. The script reads $Ansible.CheckMode itself.
[CmdletBinding(SupportsShouldProcess)]
param([string]$Definition)
$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy
$Ansible.Changed = $false
# A lookup that finds nothing returns nothing. Some GroupPolicy cmdlets throw
# for a missing item, and SilentlyContinue does not stop all of them.
function Quiet([scriptblock]$Block) { try { & $Block } catch { } }
$d = $Definition | ConvertFrom-Json
$check = [bool]$Ansible.CheckMode
$changes = New-Object Collections.Generic.List[string]
function Note([string]$text) { $changes.Add($text) }

$gpo = Quiet { Get-GPO -Name $d.name }
if (-not $gpo) {
    Note "make the GPO"
    if ($check) { $Ansible.Changed = $true; return $changes }
    $gpo = New-GPO -Name $d.name -Comment $d.comment
}
if ($gpo.Description -ne $d.comment) {
    Note "set the comment"
    if (-not $check) { $gpo.Description = $d.comment }
}
if ("$($gpo.GpoStatus)" -ne 'UserSettingsDisabled') {
    Note "turn off the user settings"
    if (-not $check) { $gpo.GpoStatus = 'UserSettingsDisabled' }
}

# A value is the same when the type and the data are the same. A DWord comes
# back as UInt32, so compare the text.
function Same($have, $want) { $have -and "$($have.Type)" -eq $want.type -and "$($have.Value)" -eq "$($want.value)" }

# Registry policy values (Administrative Templates, Registry.pol).
$policy = @($d.policy | Where-Object { $_ })
foreach ($v in $policy) {
    $have = Quiet { Get-GPRegistryValue -Guid $gpo.Id -Key $v.key -ValueName $v.name }
    if ($v.state -eq 'absent') {
        if ($have) { Note "remove policy $($v.key)\$($v.name)"; if (-not $check) { Remove-GPRegistryValue -Guid $gpo.Id -Key $v.key -ValueName $v.name | Out-Null } }
    } elseif (-not (Same $have $v)) {
        Note "set policy $($v.key)\$($v.name) = $($v.value)"
        if (-not $check) { Set-GPRegistryValue -Guid $gpo.Id -Key $v.key -ValueName $v.name -Type $v.type -Value $v.value | Out-Null }
    }
}
foreach ($key in @($policy | Where-Object { $_.state -ne 'absent' } | ForEach-Object { $_.key } | Sort-Object -Unique)) {
    $wanted = @($policy | Where-Object { $_.key -eq $key } | ForEach-Object { $_.name })
    foreach ($extra in @(Quiet { Get-GPRegistryValue -Guid $gpo.Id -Key $key } | Where-Object { $_.ValueName -and $_.ValueName -notin $wanted })) {
        Note "remove policy $key\$($extra.ValueName) (not in the code)"
        if (-not $check) { Remove-GPRegistryValue -Guid $gpo.Id -Key $key -ValueName $extra.ValueName | Out-Null }
    }
}

# Registry preference items (Group Policy Preferences), action Update.
$prefs = @($d.preferences | Where-Object { $_ })
foreach ($v in $prefs) {
    $have = @(Quiet { Get-GPPrefRegistryValue -Guid $gpo.Id -Context Computer -Key $v.key -ValueName $v.name })
    if ($v.state -eq 'absent') {
        if ($have) { Note "remove preference $($v.key)\$($v.name)"; if (-not $check) { Remove-GPPrefRegistryValue -Guid $gpo.Id -Context Computer -Key $v.key -ValueName $v.name | Out-Null } }
        continue
    }
    $ok = $have.Count -eq 1 -and "$($have[0].Action)" -eq 'Update' -and (Same $have[0] $v)
    if (-not $ok) {
        Note "set preference $($v.key)\$($v.name) = $($v.value)"
        if (-not $check) {
            if ($have) { Remove-GPPrefRegistryValue -Guid $gpo.Id -Context Computer -Key $v.key -ValueName $v.name | Out-Null }
            Set-GPPrefRegistryValue -Guid $gpo.Id -Context Computer -Action Update -Key $v.key -ValueName $v.name -Type $v.type -Value $v.value | Out-Null
        }
    }
}

# Security filtering. With apply_to, only the computers in the list apply the
# GPO. Authenticated Users keep Read, which every computer needs to read a GPO.
$apply = @($d.apply_to | Where-Object { $_ } | ForEach-Object { $_.ToUpper() })
if ($apply) {
    foreach ($c in $apply) {
        $p = Quiet { Get-GPPermission -Guid $gpo.Id -TargetName $c -TargetType Computer }
        if ("$($p.Permission)" -ne 'GpoApply') {
            Note "let $c apply the GPO"
            if (-not $check) { Set-GPPermission -Guid $gpo.Id -TargetName $c -TargetType Computer -PermissionLevel GpoApply -Replace | Out-Null }
        }
    }
    foreach ($p in @(Get-GPPermission -Guid $gpo.Id -All | Where-Object { "$($_.Permission)" -eq 'GpoApply' })) {
        $who = $p.Trustee.Name
        if ("$($p.Trustee.SidType)" -eq 'Computer' -and $who.TrimEnd('$').ToUpper() -in $apply) { continue }
        if ($who -eq 'Authenticated Users') {
            Note "give Authenticated Users Read only"
            if (-not $check) { Set-GPPermission -Guid $gpo.Id -TargetName $who -TargetType Group -PermissionLevel GpoRead -Replace | Out-Null }
        } else {
            Note "stop $who applying the GPO (not in the code)"
            $type = switch ("$($p.Trustee.SidType)") { 'Computer' { 'Computer' } 'User' { 'User' } default { 'Group' } }
            if (-not $check) { Set-GPPermission -Guid $gpo.Id -TargetName $who.TrimEnd('$') -TargetType $type -PermissionLevel None -Replace | Out-Null }
        }
    }
}

# WMI filter.
$wantFilter = "$($d.wmi_filter)"
$haveFilter = if ($gpo.WmiFilter) { $gpo.WmiFilter.Name } else { '' }
if ($wantFilter -ne $haveFilter) {
    Note "set the WMI filter to '$wantFilter'"
    if (-not $check) {
        if ($wantFilter) {
            $gpDomain = New-Object Microsoft.GroupPolicy.GPDomain
            $filter = $gpDomain.SearchWmiFilters((New-Object Microsoft.GroupPolicy.GPSearchCriteria)) | Where-Object Name -eq $wantFilter
            if (-not $filter) { throw "no WMI filter named '$wantFilter'" }
            $gpo.WmiFilter = $filter
        } else {
            $gpo.WmiFilter = $null
        }
    }
}

$Ansible.Changed = $changes.Count -gt 0
$changes
