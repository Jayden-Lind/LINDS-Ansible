# Read-only as far as the domain is concerned: lists every Group Policy
# object, takes a backup and a settings report of each into a temporary
# folder on this server, and zips it for collection. Emits one JSON document
# naming the zip. The caller fetches the zip and then removes it.

$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy
Import-Module ActiveDirectory

$work = Join-Path $env:TEMP ('gpo-capture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$work\backup", "$work\report" | Out-Null

$gpos = @(Get-GPO -All | Sort-Object DisplayName | ForEach-Object {
    $gpo = $_
    $backup = Backup-GPO -Guid $gpo.Id -Path "$work\backup"
    Get-GPOReport -Guid $gpo.Id -ReportType Xml -Path "$work\report\$($gpo.Id).xml"
    [ordered]@{
        name             = $gpo.DisplayName
        id               = "$($gpo.Id)"
        status           = "$($gpo.GpoStatus)"
        description      = $gpo.Description
        owner            = $gpo.Owner
        wmi_filter       = $gpo.WmiFilter.Name
        created          = $gpo.CreationTime.ToString('yyyy-MM-dd')
        modified         = $gpo.ModificationTime.ToString('yyyy-MM-dd HH:mm')
        computer_version = $gpo.Computer.DSVersion
        user_version     = $gpo.User.DSVersion
        # The directory and SYSVOL halves of a GPO replicate separately.
        sysvol_matches   = ($gpo.Computer.DSVersion -eq $gpo.Computer.SysvolVersion) -and ($gpo.User.DSVersion -eq $gpo.User.SysvolVersion)
        backup_id        = "$($backup.Id)"
        permissions = @(Get-GPPermission -Guid $gpo.Id -All | ForEach-Object {
            [ordered]@{
                who        = if ($_.Trustee.Name) { "$($_.Trustee.Domain)\$($_.Trustee.Name)".TrimStart('\') } else { "$($_.Trustee.Sid)" }
                permission = "$($_.Permission)"
                denied     = $_.Denied
            }
        } | Sort-Object { $_.who }, { $_.permission })
    }
})

$domainDn = (Get-ADDomain).DistinguishedName
$wmiFilters = @(Get-ADObject -SearchBase "CN=SOM,CN=WMIPolicy,CN=System,$domainDn" -LDAPFilter '(objectClass=msWMI-Som)' `
        -Properties 'msWMI-Name', 'msWMI-Parm1', 'msWMI-Parm2' -ErrorAction SilentlyContinue | Sort-Object 'msWMI-Name' | ForEach-Object {
    [ordered]@{ name = $_.'msWMI-Name'; description = $_.'msWMI-Parm1'; query = $_.'msWMI-Parm2' }
})

Compress-Archive -Path "$work\*" -DestinationPath "$work.zip"
Remove-Item -LiteralPath $work -Recurse -Force

[ordered]@{ gpos = $gpos; wmi_filters = $wmiFilters; archive = "$work.zip" } | ConvertTo-Json -Depth 6 -Compress
