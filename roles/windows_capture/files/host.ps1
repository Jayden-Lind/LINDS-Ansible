# Read-only. Describes one server: what is installed and running on it, what
# it shares and to whom, and the security settings that are set on the server
# itself rather than by policy. Emits one JSON document.
#
# Left out because they change by themselves: free space, uptime, counters.

$ErrorActionPreference = 'Stop'

function Try-Get([scriptblock]$block) { try { & $block } catch { $null } }
# Permissions set with the "generic" bits show up as bare numbers.
$generic = @{ '268435456' = 'FullControl'; '-1610612736' = 'ReadAndExecute'; '-536805376' = 'Modify'; '-2147483648' = 'Read'; '1073741824' = 'Write' }
function RightsOf($rule) { $r = "$($rule.FileSystemRights)"; if ($generic.ContainsKey($r)) { $generic[$r] } else { $r } }
function AclOf([string]$path) {
    $acl = Get-Acl -LiteralPath $path
    [ordered]@{
        owner       = "$($acl.Owner)"
        inheritance = -not $acl.AreAccessRulesProtected
        permissions = @($acl.Access | ForEach-Object {
            [ordered]@{ who = "$($_.IdentityReference)"; access = "$($_.AccessControlType)"; rights = RightsOf $_
                        inherited = $_.IsInherited; applies_to = "$($_.InheritanceFlags)/$($_.PropagationFlags)" }
        } | Sort-Object { $_.who }, { $_.rights }, { $_.access })
    }
}

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$result = [ordered]@{}

$result.host = [ordered]@{
    name        = $env:COMPUTERNAME
    domain      = $cs.Domain
    role        = @('Standalone workstation', 'Member workstation', 'Standalone server', 'Member server', 'Domain controller', 'Domain controller (PDC emulator)')[[int]$cs.DomainRole]
    os          = $os.Caption
    edition     = $cv.EditionID
    # The build without the update revision, which moves every month.
    build       = $cv.CurrentBuild
    memory_gb   = [int][math]::Round($cs.TotalPhysicalMemory / 1GB)
    processors  = $cs.NumberOfLogicalProcessors
    time_zone   = (Get-TimeZone).Id
    features    = @(Get-WindowsFeature | Where-Object Installed | ForEach-Object Name | Sort-Object)
    volumes     = @(Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
        [ordered]@{ letter = "$($_.DriveLetter)"; label = $_.FileSystemLabel; file_system = $_.FileSystem; size_gb = [int][math]::Round($_.Size / 1GB) }
    })
    addresses   = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                    ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength) ($($_.PrefixOrigin))" } | Sort-Object)
    dns_servers = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses -and $_.InterfaceAlias -notlike 'Loopback*' } |
                    ForEach-Object { $_.ServerAddresses } | Select-Object -Unique)
}

# Shares, without the administrative ones, and the permissions on each root.
$result.shares = @(Get-SmbShare | Where-Object { -not $_.Special -and $_.Name -notin 'SYSVOL', 'NETLOGON' } | Sort-Object Name | ForEach-Object {
    $share = $_
    [ordered]@{
        name        = $share.Name
        path        = $share.Path
        description = $share.Description
        access_based_enumeration = "$($share.FolderEnumerationMode)" -eq 'AccessBased'
        encrypted   = $share.EncryptData
        share_permissions = @(Get-SmbShareAccess -Name $share.Name | ForEach-Object {
            [ordered]@{ who = $_.AccountName; access = "$($_.AccessControlType)"; rights = "$($_.AccessRight)" }
        } | Sort-Object { $_.who })
        ntfs = Try-Get { AclOf $share.Path }
        # One level down: on a data share that is where the real permissions are.
        folders = @(if ($share.Name -ne 'print$') {
            Get-ChildItem -LiteralPath $share.Path -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin 'System Volume Information', '$RECYCLE.BIN', 'DfsrPrivate' } | Sort-Object Name | ForEach-Object {
                    $folder = $_
                    [ordered]@{ name = $folder.Name; ntfs = Try-Get { AclOf $folder.FullName } }
                }
        })
    }
})
$result.nfs_shares = @(Try-Get { Get-NfsShare -ErrorAction Stop | Sort-Object Name | ForEach-Object {
    $n = $_
    [ordered]@{
        name = $n.Name; path = $n.Path; authentication = @($n.Authentication | ForEach-Object { "$_" })
        anonymous_access = $n.AnonymousAccess; unmapped_user_access = $n.UnmappedUserAccess
        clients = @(Get-NfsSharePermission -Name $n.Name | ForEach-Object {
            [ordered]@{ client = $_.ClientName; type = "$($_.ClientType)"; permission = "$($_.Permission)"; root_access = $_.AllowRootAccess }
        } | Sort-Object { $_.client })
    }
} })

# Services that are not part of Windows, and any service that logs on as an account.
$builtin = 'LocalSystem', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\NetworkService', 'NT AUTHORITY\LOCAL SERVICE', 'NT AUTHORITY\NETWORK SERVICE', $null, ''
$result.services = @(Get-CimInstance Win32_Service | Where-Object {
    $exe = ($_.PathName -replace '^"([^"]+)".*$', '$1' -replace '^(\S+\.exe).*$', '$1')
    $company = Try-Get { (Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo.CompanyName }
    $_ | Add-Member -NotePropertyName Company -NotePropertyValue $company -Force
    ($_.StartName -notin $builtin -and $_.StartName -notlike 'NT SERVICE\*') -or ($company -and $company -notlike 'Microsoft*')
} | Sort-Object Name | ForEach-Object {
    [ordered]@{ name = $_.Name; display_name = $_.DisplayName; start = $_.StartMode; runs_as = $_.StartName; vendor = $_.Company; path = $_.PathName }
})

# Scheduled tasks that did not come with Windows.
$result.scheduled_tasks = @(Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | Sort-Object TaskPath, TaskName | ForEach-Object {
    [ordered]@{
        name     = "$($_.TaskPath)$($_.TaskName)"
        enabled  = "$($_.State)" -ne 'Disabled'
        runs_as  = $_.Principal.UserId
        highest_privileges = "$($_.Principal.RunLevel)" -eq 'Highest'
        logon_type = "$($_.Principal.LogonType)"
        actions  = @($_.Actions | ForEach-Object { ("$($_.Execute) $($_.Arguments)").Trim() })
        triggers = @($_.Triggers | ForEach-Object { $_.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', '' })
    }
})

$uninstall = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$result.software = @(Get-ItemProperty $uninstall -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
    Sort-Object DisplayName, DisplayVersion -Unique | ForEach-Object {
        [ordered]@{ name = $_.DisplayName; version = $_.DisplayVersion; publisher = $_.Publisher }
    })

$lsa = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$smb = Get-SmbServerConfiguration
$rdp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$nla = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$w32 = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
$w32policy = Try-Get { Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters' -ErrorAction Stop }
$defender = Try-Get { Get-MpPreference -ErrorAction Stop }
$sshKeys = 'C:\ProgramData\ssh\administrators_authorized_keys'
$result.security = [ordered]@{
    firewall = [ordered]@{}
    defender = [ordered]@{
        service           = "$((Get-Service WinDefend -ErrorAction SilentlyContinue).Status)"
        realtime          = if ($defender) { -not $defender.DisableRealtimeMonitoring } else { $null }
        excluded_paths     = @($defender.ExclusionPath | Sort-Object)
        excluded_processes = @($defender.ExclusionProcess | Sort-Object)
        controlled_folder_access = "$($defender.EnableControlledFolderAccess)"
        attack_surface_rules     = @($defender.AttackSurfaceReductionRules_Ids).Count
    }
    smb = [ordered]@{
        smb1_enabled      = $smb.EnableSMB1Protocol
        smb1_feature      = "$((Get-WindowsFeature FS-SMB1).InstallState)"
        signing_required  = $smb.RequireSecuritySignature
        encryption        = $smb.EncryptData
        reject_unencrypted = $smb.RejectUnencryptedAccess
    }
    lsa = [ordered]@{
        lsa_protection            = $lsa.RunAsPPL
        lm_compatibility_level    = $lsa.LmCompatibilityLevel
        no_lm_hash                = $lsa.NoLMHash
        restrict_anonymous        = $lsa.RestrictAnonymous
        restrict_anonymous_sam    = $lsa.RestrictAnonymousSAM
        everyone_includes_anonymous = $lsa.EveryoneIncludesAnonymous
        credential_guard          = (Try-Get { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -ErrorAction Stop).EnableVirtualizationBasedSecurity })
    }
    remote_desktop = [ordered]@{ enabled = ($rdp.fDenyTSConnections -eq 0); network_level_authentication = ($nla.UserAuthentication -eq 1) }
    winrm_listeners = @(Try-Get { Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop | ForEach-Object { ($_.Keys -join ' ') } | Sort-Object })
    openssh_server = [ordered]@{
        service = "$((Get-Service sshd -ErrorAction SilentlyContinue).Status)"
        start   = "$((Get-Service sshd -ErrorAction SilentlyContinue).StartType)"
        # How many, not which: the keys themselves stay on the server.
        administrator_keys = if (Test-Path $sshKeys) { @(Get-Content $sshKeys | Where-Object { $_ -match '^\s*(ssh-|ecdsa-|sk-)' }).Count } else { 0 }
    }
    time = [ordered]@{
        configured_type = $w32.Type; configured_server = $w32.NtpServer
        policy_type = $w32policy.Type; policy_server = $w32policy.NtpServer
    }
    print_spooler = "$((Get-Service Spooler -ErrorAction SilentlyContinue).StartType)"
    local_administrators = @(Try-Get { if ($cs.DomainRole -lt 4) { Get-LocalGroupMember -Group Administrators -ErrorAction Stop | ForEach-Object Name | Sort-Object } })
    windows_update = [ordered]@{
        policy = (Try-Get { $au = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction Stop
                            [ordered]@{ no_auto_update = $au.NoAutoUpdate; options = $au.AUOptions; day = $au.ScheduledInstallDay; hour = $au.ScheduledInstallTime } })
    }
    event_log_sizes_mb = [ordered]@{}
}
Get-NetFirewallProfile | Sort-Object Name | ForEach-Object {
    $result.security.firewall[$_.Name] = [ordered]@{ enabled = [bool]$_.Enabled; inbound = "$($_.DefaultInboundAction)"; outbound = "$($_.DefaultOutboundAction)" }
}
foreach ($log in 'Application', 'Security', 'System') {
    $result.security.event_log_sizes_mb[$log] = [int]((Get-WinEvent -ListLog $log).MaximumSizeInBytes / 1MB)
}

# Only where this server is a DNS server: the settings that are per server.
if (Get-Service DNS -ErrorAction SilentlyContinue) {
    $scavenging = Try-Get { Get-DnsServerScavenging -ErrorAction Stop }
    $result.dns_server = [ordered]@{
        forwarders  = @(Try-Get { (Get-DnsServerForwarder -ErrorAction Stop).IPAddress | ForEach-Object { "$_" } })
        recursion   = (Try-Get { (Get-DnsServerRecursion -ErrorAction Stop).Enable })
        scavenging  = [bool]$scavenging.ScavengingState
        scavenging_interval_hours = [int]$scavenging.ScavengingInterval.TotalHours
        listens_on  = @(Try-Get { (Get-DnsServerSetting -All -ErrorAction Stop -WarningAction SilentlyContinue).ListeningIPAddress | ForEach-Object { "$_" } | Sort-Object })
    }
}

$result | ConvertTo-Json -Depth 8 -Compress
