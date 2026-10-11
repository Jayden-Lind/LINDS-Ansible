# Read-only. Describes the directory itself: the domain, its sites, OUs,
# groups, users, computers, service accounts, who holds the powerful groups
# and who has been delegated what. Emits one JSON document.
#
# Left out on purpose, because they change by themselves and would make every
# capture differ from the last: logon times, machine password ages, counters.

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
Import-Module GroupPolicy

$rootDse = Get-ADRootDSE
$domain  = Get-ADDomain
$forest  = Get-ADForest
$dn      = $domain.DistinguishedName
$config  = $rootDse.configurationNamingContext

function Day($v) { if ($v) { ([datetime]$v).ToString('yyyy-MM-dd') } else { $null } }
function ParentOf([string]$d) { ($d -split '(?<!\\),', 2)[1] }

# Every security principal by DN, so memberships can be written as names.
$nameOf = @{}
Get-ADObject -LDAPFilter '(|(objectClass=user)(objectClass=group)(objectClass=computer)(objectClass=msDS-GroupManagedServiceAccount))' `
    -Properties sAMAccountName | ForEach-Object { $nameOf[$_.DistinguishedName] = $_.sAMAccountName }
function NameOf([string]$d) {
    if ($nameOf.ContainsKey($d)) { return $nameOf[$d] }
    # Foreign security principals are named by SID: Authenticated Users and friends.
    if ($d -match '^CN=(S-1-[0-9-]+),CN=ForeignSecurityPrincipals') {
        try { return (New-Object Security.Principal.SecurityIdentifier $Matches[1]).Translate([Security.Principal.NTAccount]).Value } catch { return $Matches[1] }
    }
    return $d
}
# The comma keeps an empty result an empty list instead of nothing at all.
function Names($list) { , @($list | Where-Object { $_ } | ForEach-Object { NameOf $_ } | Sort-Object) }

$policy = Get-ADDefaultDomainPasswordPolicy
$result = [ordered]@{}

$result.domain = [ordered]@{
    name                  = $domain.DNSRoot
    netbios               = $domain.NetBIOSName
    forest_mode           = "$($forest.ForestMode)"
    domain_mode           = "$($domain.DomainMode)"
    machine_account_quota = (Get-ADObject $dn -Properties 'ms-DS-MachineAccountQuota').'ms-DS-MachineAccountQuota'
    recycle_bin_enabled   = [bool](Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'").EnabledScopes
    tombstone_lifetime    = (Get-ADObject "CN=Directory Service,CN=Windows NT,CN=Services,$config" -Properties tombstoneLifetime).tombstoneLifetime
    krbtgt_password_set   = Day (Get-ADUser krbtgt -Properties PasswordLastSet).PasswordLastSet
    fsmo = [ordered]@{
        pdc_emulator   = $domain.PDCEmulator
        rid_master     = $domain.RIDMaster
        infrastructure = $domain.InfrastructureMaster
        schema         = $forest.SchemaMaster
        domain_naming  = $forest.DomainNamingMaster
    }
    domain_controllers = @(Get-ADDomainController -Filter * | Sort-Object Name | ForEach-Object {
        [ordered]@{ name = $_.Name; site = $_.Site; address = $_.IPv4Address; global_catalog = $_.IsGlobalCatalog
                    read_only = $_.IsReadOnly; os = $_.OperatingSystem }
    })
    default_password_policy = [ordered]@{
        min_length            = $policy.MinPasswordLength
        complexity            = $policy.ComplexityEnabled
        history               = $policy.PasswordHistoryCount
        max_age_days          = $policy.MaxPasswordAge.Days
        min_age_days          = $policy.MinPasswordAge.Days
        lockout_threshold     = $policy.LockoutThreshold
        lockout_minutes       = [int]$policy.LockoutDuration.TotalMinutes
        lockout_window_minutes = [int]$policy.LockoutObservationWindow.TotalMinutes
        reversible_encryption = $policy.ReversibleEncryptionEnabled
    }
    fine_grained_password_policies = @(Get-ADFineGrainedPasswordPolicy -Filter * | Sort-Object Name | ForEach-Object {
        [ordered]@{ name = $_.Name; precedence = $_.Precedence; min_length = $_.MinPasswordLength; complexity = $_.ComplexityEnabled
                    max_age_days = $_.MaxPasswordAge.Days; lockout_threshold = $_.LockoutThreshold; applies_to = Names $_.AppliesTo }
    })
    trusts = @(Get-ADTrust -Filter * | Sort-Object Name | ForEach-Object {
        [ordered]@{ name = $_.Name; direction = "$($_.Direction)"; type = "$($_.TrustType)"; forest_transitive = $_.ForestTransitive }
    })
}

$result.sites = [ordered]@{
    sites = @(Get-ADReplicationSite -Filter * | Sort-Object Name | ForEach-Object {
        $site = $_
        [ordered]@{
            name    = $site.Name
            subnets = @(Get-ADReplicationSubnet -Filter * | Where-Object { $_.Site -eq $site.DistinguishedName } | ForEach-Object Name | Sort-Object)
            gp_link = (Get-ADObject $site.DistinguishedName -Properties gPLink).gPLink
        }
    })
    site_links = @(Get-ADReplicationSiteLink -Filter * | Sort-Object Name | ForEach-Object {
        [ordered]@{ name = $_.Name; cost = $_.Cost; interval_minutes = $_.ReplicationFrequencyInMinutes
                    sites = @($_.SitesIncluded | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' } | Sort-Object) }
    })
}

# The domain root and every OU, with the GPOs linked to each, in order.
$containers = @($dn) + @(Get-ADOrganizationalUnit -Filter * | Sort-Object DistinguishedName | ForEach-Object DistinguishedName)
$result.ous = @($containers | ForEach-Object {
    $inheritance = Get-GPInheritance -Target $_
    $ou = if ($_ -ne $dn) { Get-ADOrganizationalUnit $_ -Properties Description, ProtectedFromAccidentalDeletion }
    [ordered]@{
        dn                      = $_
        description             = $ou.Description
        protected_from_deletion = $ou.ProtectedFromAccidentalDeletion
        gp_inheritance_blocked  = $inheritance.GpoInheritanceBlocked
        gpo_links = @($inheritance.GpoLinks | Sort-Object Order | ForEach-Object {
            [ordered]@{ order = $_.Order; gpo = $_.DisplayName; enabled = $_.Enabled; enforced = $_.Enforced }
        })
    }
})

$result.groups = @(Get-ADGroup -Filter * -Properties Description, Members, MemberOf, adminCount | Sort-Object SamAccountName | ForEach-Object {
    [ordered]@{
        name        = $_.SamAccountName
        container   = ParentOf $_.DistinguishedName
        scope       = "$($_.GroupScope)"
        category    = "$($_.GroupCategory)"
        description = $_.Description
        admin_count = [bool]$_.adminCount
        members     = Names $_.Members
        member_of   = Names $_.MemberOf
    }
})

$userProps = 'Description', 'UserPrincipalName', 'PasswordLastSet', 'PasswordNeverExpires', 'PasswordNotRequired', 'CannotChangePassword',
             'adminCount', 'servicePrincipalName', 'TrustedForDelegation', 'TrustedToAuthForDelegation', 'msDS-AllowedToDelegateTo',
             'DoesNotRequirePreAuth', 'MemberOf', 'ScriptPath', 'HomeDirectory', 'HomeDrive', 'SmartcardLogonRequired',
             'AccountExpirationDate', 'msDS-SupportedEncryptionTypes', 'AccountNotDelegated'
$result.users = @(Get-ADUser -Filter * -Properties $userProps | Sort-Object SamAccountName | ForEach-Object {
    [ordered]@{
        name                    = $_.SamAccountName
        display_name            = $_.Name
        container               = ParentOf $_.DistinguishedName
        upn                     = $_.UserPrincipalName
        enabled                 = $_.Enabled
        description             = $_.Description
        password_set            = Day $_.PasswordLastSet
        password_never_expires  = $_.PasswordNeverExpires
        password_not_required   = $_.PasswordNotRequired
        cannot_change_password  = $_.CannotChangePassword
        account_expires         = Day $_.AccountExpirationDate
        admin_count             = [bool]$_.adminCount
        smartcard_required      = $_.SmartcardLogonRequired
        sensitive_no_delegation = $_.AccountNotDelegated
        no_kerberos_preauth     = $_.DoesNotRequirePreAuth
        encryption_types        = $_.'msDS-SupportedEncryptionTypes'
        spns                    = @($_.servicePrincipalName | Sort-Object)
        trusted_for_delegation  = $_.TrustedForDelegation
        protocol_transition     = $_.TrustedToAuthForDelegation
        may_delegate_to         = @($_.'msDS-AllowedToDelegateTo' | Sort-Object)
        logon_script            = $_.ScriptPath
        home_directory          = $_.HomeDirectory
        home_drive              = $_.HomeDrive
        member_of               = Names $_.MemberOf
    }
})

$result.computers = @(Get-ADComputer -Filter * -Properties Description, OperatingSystem, DNSHostName, TrustedForDelegation,
        TrustedToAuthForDelegation, 'msDS-AllowedToDelegateTo', servicePrincipalName, PrimaryGroupID, MemberOf,
        'msDS-AllowedToActOnBehalfOfOtherIdentity' | Sort-Object Name | ForEach-Object {
    [ordered]@{
        name                   = $_.Name
        container              = ParentOf $_.DistinguishedName
        dns_name               = $_.DNSHostName
        enabled                = $_.Enabled
        description            = $_.Description
        os                     = $_.OperatingSystem
        domain_controller      = $_.PrimaryGroupID -in 516, 521
        trusted_for_delegation = $_.TrustedForDelegation
        protocol_transition    = $_.TrustedToAuthForDelegation
        may_delegate_to        = @($_.'msDS-AllowedToDelegateTo' | Sort-Object)
        resource_delegation    = [bool]$_.'msDS-AllowedToActOnBehalfOfOtherIdentity'
        service_classes        = @($_.servicePrincipalName | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
        member_of              = Names $_.MemberOf
    }
})

$result.service_accounts = @(Get-ADServiceAccount -Filter * -Properties Description, servicePrincipalName, MemberOf,
        PrincipalsAllowedToRetrieveManagedPassword, 'msDS-ManagedPasswordInterval' | Sort-Object Name | ForEach-Object {
    [ordered]@{
        name                   = $_.SamAccountName
        kind                   = $_.ObjectClass
        container              = ParentOf $_.DistinguishedName
        enabled                = $_.Enabled
        description            = $_.Description
        password_interval_days = $_.'msDS-ManagedPasswordInterval'
        may_retrieve_password  = Names $_.PrincipalsAllowedToRetrieveManagedPassword
        spns                   = @($_.servicePrincipalName | Sort-Object)
        member_of              = Names $_.MemberOf
    }
})

# Who ends up in the groups that matter, nesting followed.
$powerful = 'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators', 'Account Operators', 'Server Operators',
            'Backup Operators', 'Print Operators', 'DnsAdmins', 'Group Policy Creator Owners', 'Cert Publishers',
            'Key Admins', 'Enterprise Key Admins', 'Protected Users', 'Remote Desktop Users', 'Remote Management Users',
            'Distributed COM Users', 'Certificate Service DCOM Access', 'Pre-Windows 2000 Compatible Access'
$result.privileged = [ordered]@{}
foreach ($group in $powerful) {
    $object = Get-ADGroup -Filter "Name -eq '$group'"
    if (-not $object) { continue }
    # LDAP_MATCHING_RULE_IN_CHAIN: everything that is a member, however deep.
    $nested = Get-ADObject -LDAPFilter "(memberOf:1.2.840.113556.1.4.1941:=$($object.DistinguishedName))" -Properties objectClass
    $result.privileged[$group] = Names ($nested | Where-Object { $_.objectClass -ne 'group' } | ForEach-Object DistinguishedName)
}

# Explicit (not inherited) permissions on the containers that policy and
# delegation hang off. GUIDs are turned into the names of the attribute,
# class or extended right they stand for.
$guidName = @{ '00000000-0000-0000-0000-000000000000' = $null }
Get-ADObject -SearchBase $rootDse.schemaNamingContext -LDAPFilter '(schemaIDGUID=*)' -Properties lDAPDisplayName, schemaIDGUID |
    ForEach-Object { $guidName[([guid]$_.schemaIDGUID).ToString()] = $_.lDAPDisplayName }
Get-ADObject -SearchBase "CN=Extended-Rights,$config" -LDAPFilter '(rightsGuid=*)' -Properties rightsGuid, Name |
    ForEach-Object { $guidName[([guid]$_.rightsGuid).ToString()] = $_.Name }
function GuidName($g) { $k = "$g".ToLower(); if ($guidName.ContainsKey($k)) { $guidName[$k] } else { $k } }

$watched = @($dn, "CN=Users,$dn", "CN=Computers,$dn", "CN=AdminSDHolder,CN=System,$dn") + @($containers | Where-Object { $_ -ne $dn })
$result.delegation = @($watched | ForEach-Object {
    $target = $_
    $acl = Get-Acl -Path "AD:\$target"
    [ordered]@{
        dn    = $target
        owner = "$($acl.Owner)"
        explicit_permissions = @($acl.Access | Where-Object { -not $_.IsInherited } | ForEach-Object {
            [ordered]@{
                who         = "$($_.IdentityReference)"
                access      = "$($_.AccessControlType)"
                rights      = "$($_.ActiveDirectoryRights)"
                on          = GuidName $_.ObjectType
                applies_to  = GuidName $_.InheritedObjectType
                inheritance = "$($_.InheritanceType)"
            }
        } | Sort-Object { $_.who }, { $_.rights }, { "$($_.on)" }, { "$($_.applies_to)" }, { $_.access })
    }
})

$result | ConvertTo-Json -Depth 8 -Compress
