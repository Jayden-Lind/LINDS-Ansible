# Make one GPO agree with its definition: the GPO and its comment, its
# registry policy values and registry preference items (exact for each key
# that the definition names), its user rights, its advanced audit policy, the
# computers that apply it, and its WMI filter.
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

# Settings that live in SYSVOL (user rights, audit policy). No GroupPolicy
# cmdlet sets them, so the script does what GPMC does: it writes the file,
# adds the client-side extension to the GPO and raises the computer version,
# so that each computer applies the change at its next refresh.
$rights = $d.privilege_rights
$audit = @($d.audit_policy | Where-Object { $_ })
if (($rights -and @($rights.PSObject.Properties).Count) -or $audit.Count) {
    Import-Module ActiveDirectory
    $domain = Get-ADDomain
    $gpt = "\\$($domain.DNSRoot)\SYSVOL\$($domain.DNSRoot)\Policies\{$($gpo.Id)}"
}
# $Extension is "[{extension}{snap-in}]". GPMC keeps the list sorted. The
# function reads $gpo, $domain and $gpt from the script.
function Register-MachineChange([string]$Extension) {
    $dn = "CN={$($gpo.Id)},CN=Policies,CN=System,$($domain.DistinguishedName)"
    $obj = Get-ADObject -Identity $dn -Properties gPCMachineExtensionNames, versionNumber
    $entries = @([regex]::Matches("$($obj.gPCMachineExtensionNames)", '\[[^\]]+\]') | ForEach-Object { $_.Value })
    if ($entries -notcontains $Extension) { $entries += $Extension }
    # The low 16 bits are the computer version.
    $version = [int]$obj.versionNumber + 1
    Set-ADObject -Identity $dn -Replace @{ gPCMachineExtensionNames = ((@($entries) | Sort-Object) -join ''); versionNumber = $version }
    $ini = "$gpt\GPT.INI"
    $text = [IO.File]::ReadAllText($ini)
    [IO.File]::WriteAllText($ini, [regex]::Replace($text, '(?m)^Version=\d+', "Version=$version"))
}

# User rights (Security Settings, GptTmpl.inf).
if ($rights -and @($rights.PSObject.Properties).Count) {
    $lines = foreach ($p in @($rights.PSObject.Properties | Sort-Object Name)) {
        $sids = foreach ($who in @($p.Value)) { '*' + ([Security.Principal.NTAccount]$who).Translate([Security.Principal.SecurityIdentifier]).Value }
        "$($p.Name) = " + ((@($sids) | Sort-Object) -join ',')
    }
    $want = "[Unicode]`r`nUnicode=yes`r`n[Version]`r`nsignature=`"`$CHICAGO`$`"`r`nRevision=1`r`n[Privilege Rights]`r`n" + (@($lines) -join "`r`n") + "`r`n"
    $inf = "$gpt\Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
    $have = if (Test-Path -LiteralPath $inf) { [IO.File]::ReadAllText($inf, [Text.Encoding]::Unicode) } else { '' }
    if ($have -ne $want) {
        Note "set the user rights: $((@($rights.PSObject.Properties) | ForEach-Object { $_.Name }) -join ', ')"
        if (-not $check) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $inf) | Out-Null
            [IO.File]::WriteAllText($inf, $want, [Text.Encoding]::Unicode)
            # The Security extension and its GPMC snap-in.
            Register-MachineChange '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
        }
    }
}

# Advanced audit policy (Advanced Audit Policy Configuration, audit.csv). One
# line for each subcategory in the definition, in its order. A GPO with these
# settings makes the computer ignore the old category settings (Audit
# Policy) of all GPOs, so a definition must list every subcategory to keep.
if ($audit.Count) {
    $names = @{ success = @('Success', 1); failure = @('Failure', 2); success_and_failure = @('Success and Failure', 3); none = @('No Auditing', 0) }
    $lines = foreach ($a in $audit) {
        $s = $names["$($a.setting)"]
        if (-not $s) { throw "audit_policy: unknown setting '$($a.setting)' for $($a.subcategory)" }
        ",System,Audit $($a.subcategory),$("$($a.guid)".ToLower()),$($s[0]),,$($s[1])"
    }
    $want = "Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting,Setting Value`r`n" + (@($lines) -join "`r`n") + "`r`n"
    $csv = "$gpt\Machine\Microsoft\Windows NT\Audit\audit.csv"
    $have = if (Test-Path -LiteralPath $csv) { [IO.File]::ReadAllText($csv) } else { '' }
    if ($have -ne $want) {
        Note "set the audit policy: $($audit.Count) subcategories"
        if (-not $check) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $csv) | Out-Null
            [IO.File]::WriteAllText($csv, $want, (New-Object Text.UTF8Encoding $false))
            # The Audit Policy Configuration extension and its GPMC snap-in.
            Register-MachineChange '[{F3CCC681-B74C-4060-9F26-CD84525DCA2A}{0F3F3735-573D-9804-99E4-AB2A69BA5FD4}]'
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
