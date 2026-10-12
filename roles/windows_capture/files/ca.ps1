# Read-only. Describes the certification authority on this server and what
# the directory trusts: the CA's settings, who may manage it and enrol from
# it, every certificate template with who may enrol, and the certificates in
# the directory's trust stores. No key material: the CA's own certificate is
# public and is included so that it can be compared and installed.

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$config  = (Get-ADRootDSE).configurationNamingContext
$pki     = "CN=Public Key Services,CN=Services,$config"
$certSvc = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
$caName  = (Get-ItemProperty $certSvc).Active
$ca      = Get-ItemProperty "$certSvc\$caName"
$csp     = Get-ItemProperty "$certSvc\$caName\CSP"
$policy  = Get-ItemProperty "$certSvc\$caName\PolicyModules\CertificateAuthority_MicrosoftDefault.Policy"

function Who($sid) { try { $sid.Translate([Security.Principal.NTAccount]).Value } catch { "$sid" } }
function Days([byte[]]$period) { if ($period) { [int]([BitConverter]::ToInt64($period, 0) / -864000000000) } }
function CertInfo([byte[]]$raw) {
    $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, $raw)
    [ordered]@{ subject = $c.Subject; thumbprint = $c.Thumbprint; not_before = $c.NotBefore.ToString('yyyy-MM-dd')
                not_after = $c.NotAfter.ToString('yyyy-MM-dd'); self_signed = ($c.Subject -eq $c.Issuer) }
}

$caCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -in @($ca.CACertHash | ForEach-Object { ($_ -replace ' ', '').ToUpper() }) } |
          Sort-Object NotAfter -Descending | Select-Object -First 1

$caCertInfo = $null; $caCertPem = $null
if ($caCert) {
    $caCertInfo = CertInfo $caCert.RawData
    $caCertPem  = "-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($caCert.RawData, 'InsertLineBreaks') + "`n-----END CERTIFICATE-----`n"
}

# Who may do what on the CA itself.
$rights = @(@(1, 'ManageCA'), @(2, 'ManageCertificates'), @(256, 'Read'), @(512, 'Enroll'))
$sd = New-Object Security.AccessControl.RawSecurityDescriptor ($ca.Security, 0)
$caSecurity = @($sd.DiscretionaryAcl | Group-Object { "$(Who $_.SecurityIdentifier)|$($_.AceType)" } | ForEach-Object {
    $mask = 0; $_.Group | ForEach-Object { $mask = $mask -bor $_.AccessMask }
    [ordered]@{ who = ($_.Name -split '\|')[0]; access = (($_.Name -split '\|')[1] -replace 'Access', '')
                rights = @($rights | Where-Object { $mask -band $_[0] } | ForEach-Object { $_[1] }) }
} | Sort-Object { $_.who })

$published = @((Get-ADObject "CN=$caName,CN=Enrollment Services,$pki" -Properties certificateTemplates).certificateTemplates)

$enroll = '0e10c968-78fb-11d2-90d4-00c04f79dc55'; $autoenroll = 'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
$templates = @(Get-ADObject -SearchBase "CN=Certificate Templates,$pki" -SearchScope OneLevel -Filter * -Properties displayName,
        'msPKI-Template-Schema-Version', pKIExtendedKeyUsage, 'msPKI-Certificate-Application-Policy', 'msPKI-Certificate-Name-Flag',
        'msPKI-Enrollment-Flag', 'msPKI-RA-Signature', 'msPKI-Minimal-Key-Size', pKIExpirationPeriod, pKIOverlapPeriod,
        nTSecurityDescriptor | Sort-Object Name | ForEach-Object {
    $t = $_
    $allow = @($t.nTSecurityDescriptor.Access | Where-Object { $_.AccessControlType -eq 'Allow' })
    $nameFlag = [int64]$t.'msPKI-Certificate-Name-Flag'; $enrollFlag = [int64]$t.'msPKI-Enrollment-Flag'
    [ordered]@{
        name                      = $t.Name
        display_name              = $t.displayName
        published                 = $t.Name -in $published
        schema_version            = $t.'msPKI-Template-Schema-Version'
        usages                    = @(@($t.pKIExtendedKeyUsage) + @($t.'msPKI-Certificate-Application-Policy') | Where-Object { $_ } | Sort-Object -Unique |
                                      ForEach-Object { $f = (New-Object Security.Cryptography.Oid $_).FriendlyName; if ($f) { $f } else { $_ } })
        valid_days                = Days $t.pKIExpirationPeriod
        renew_days_before         = Days $t.pKIOverlapPeriod
        minimum_key_size          = $t.'msPKI-Minimal-Key-Size'
        # The three settings that decide whether a template can be abused.
        requester_supplies_subject = [bool]($nameFlag -band 1)
        manager_approval           = [bool]($enrollFlag -band 2)
        authorised_signatures      = $t.'msPKI-RA-Signature'
        auto_enrollment            = [bool]($enrollFlag -band 32)
        may_enroll     = @($allow | Where-Object { ($_.ActiveDirectoryRights -band 256) -and "$($_.ObjectType)" -in $enroll, '00000000-0000-0000-0000-000000000000' } | ForEach-Object { "$($_.IdentityReference)" } | Sort-Object -Unique)
        may_autoenroll = @($allow | Where-Object { ($_.ActiveDirectoryRights -band 256) -and "$($_.ObjectType)" -eq $autoenroll } | ForEach-Object { "$($_.IdentityReference)" } | Sort-Object -Unique)
        may_change     = @($allow | Where-Object { $_.ActiveDirectoryRights -band 0xC0020 } | ForEach-Object { "$($_.IdentityReference)" } | Sort-Object -Unique)
    }
})

function StoreOf([string]$dn) {
    @(Get-ADObject -SearchBase $dn -LDAPFilter '(cACertificate=*)' -Properties cACertificate -ErrorAction SilentlyContinue | ForEach-Object {
        $_.cACertificate | Where-Object { $_.Length -gt 1 } | ForEach-Object { CertInfo $_ }
    } | Sort-Object { $_.subject }, { $_.not_after })
}

[ordered]@{
    ca = [ordered]@{
        name            = $caName
        server          = $ca.CAServerName
        kind            = @('Enterprise root', 'Enterprise subordinate', '', 'Standalone root', 'Standalone subordinate')[[int]$ca.CAType]
        key_provider    = $csp.Provider
        key_algorithm   = $csp.CNGPublicKeyAlgorithm
        key_size        = $caCert.PublicKey.Key.KeySize
        hash_algorithm  = $csp.CNGHashAlgorithm
        certificate     = $caCertInfo
        issued_validity = "$($ca.ValidityPeriodUnits) $($ca.ValidityPeriod)"
        crl_period      = "$($ca.CRLPeriodUnits) $($ca.CRLPeriod)"
        crl_delta       = "$($ca.CRLDeltaPeriodUnits) $($ca.CRLDeltaPeriod)"
        crl_locations   = @($ca.CRLPublicationURLs)
        aia_locations   = @($ca.CACertPublicationURLs)
        audit_filter    = $ca.AuditFilter
        interface_flags = $ca.InterfaceFlags
        # 0x00040000 here is EDITF_ATTRIBUTESUBJECTALTNAME2: any requester may name another subject.
        policy_edit_flags = '0x{0:X8}' -f [int64]$policy.EditFlags
        san_from_request_attribute = [bool]([int64]$policy.EditFlags -band 0x00040000)
        database_directory = (Get-ItemProperty $certSvc).DBDirectory
        security        = $caSecurity
        templates_published = @($published | Sort-Object)
    }
    templates = $templates
    trust = [ordered]@{
        ntauth                = StoreOf "CN=NTAuthCertificates,$pki"
        root_authorities      = StoreOf "CN=Certification Authorities,$pki"
        intermediate          = StoreOf "CN=AIA,$pki"
        enrollment_services   = @(Get-ADObject -SearchBase "CN=Enrollment Services,$pki" -SearchScope OneLevel -Filter * -Properties dNSHostName |
                                  Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; server = $_.dNSHostName } })
    }
    certificate_pem = $caCertPem
} | ConvertTo-Json -Depth 7 -Compress
