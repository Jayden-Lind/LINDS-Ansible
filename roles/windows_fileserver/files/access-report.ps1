[CmdletBinding()]
param([string]$Share)
# What each enabled domain account can really do in each top folder of a share.
# For each account, Windows makes its token without a password (an S4U logon,
# with its real group memberships). AccessCheck then gets the rights that the
# share and the folder each give. The effective right is the smaller of the
# two. The script reads only. Run it as SYSTEM.
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$searcher = [adsisearcher]'(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'
$searcher.PropertiesToLoad.Add('samaccountname') | Out-Null
$domain = ([ADSI]'LDAP://RootDSE').defaultNamingContext -replace '^DC=', '' -replace ',DC=', '.'
$Accounts = @($searcher.FindAll() | ForEach-Object { [string]$_.Properties['samaccountname'][0] } | Sort-Object)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Ac {
    [StructLayout(LayoutKind.Sequential)] public struct GENERIC_MAPPING { public uint R, W, X, A; }
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AccessCheck(byte[] sd, IntPtr token, uint desired, ref GENERIC_MAPPING map,
        byte[] privs, ref uint privsLen, out uint granted, out bool status);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool DuplicateToken(IntPtr existing, int level, out IntPtr dup);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static uint Granted(byte[] sd, IntPtr token, GENERIC_MAPPING map) {
        IntPtr imp;
        if (!DuplicateToken(token, 1, out imp)) throw new System.ComponentModel.Win32Exception();
        try {
            byte[] privs = new byte[256]; uint len = 256; uint granted; bool ok;
            if (!AccessCheck(sd, imp, 0x02000000, ref map, privs, ref len, out granted, out ok))
                throw new System.ComponentModel.Win32Exception();
            return ok ? granted : 0;
        } finally { CloseHandle(imp); }
    }
}
'@
# The file generic mapping (FILE_GENERIC_READ, _WRITE, _EXECUTE, FILE_ALL_ACCESS).
$map = New-Object Ac+GENERIC_MAPPING
$map.R = 0x120089; $map.W = 0x120116; $map.X = 0x1200A0; $map.A = 0x1F01FF

function Describe([uint32]$g) {
    $read = ($g -band 0x1) -and ($g -band 0x80)                 # list/read data, read attributes
    $write = ($g -band 0x2) -and ($g -band 0x4)                 # write data / add file, append / add folder
    $delete = [bool]($g -band 0x10000) -or [bool]($g -band 0x40) # DELETE, or delete child
    $full = ($g -band 0x40000) -and ($g -band 0x80000)          # WRITE_DAC and WRITE_OWNER
    if ($full) { 'full' } elseif ($write -and $delete) { 'modify' } elseif ($write) { 'write' } elseif ($read) { 'read' } else { 'none' }
}

$s = Get-SmbShare -Name $Share
$shareSd = (New-Object Security.AccessControl.RawSecurityDescriptor $s.SecurityDescriptor)
$shareBytes = New-Object byte[] $shareSd.BinaryLength; $shareSd.GetBinaryForm($shareBytes, 0)

$folders = Get-ChildItem -LiteralPath $s.Path -Directory -Force | Where-Object { $_.Name -notmatch '^(\$|System Volume|\.|DfsrPrivate)' } | Sort-Object Name
$width = [Math]::Max(10, ($Accounts | Measure-Object Length -Maximum).Maximum + 2)
$header = 'folder'.PadRight(16) + (($Accounts | ForEach-Object { $_.PadRight($width) }) -join '')
$header
foreach ($f in $folders) {
    $sd = (Get-Acl -LiteralPath $f.FullName).GetSecurityDescriptorBinaryForm()
    $row = $f.Name.PadRight(16)
    foreach ($a in $Accounts) {
        try {
            $id = New-Object Security.Principal.WindowsIdentity("$a@$domain")
            $onShare = [Ac]::Granted($shareBytes, $id.Token, $map)
            $onFolder = [Ac]::Granted($sd, $id.Token, $map)
            $row += (Describe ($onShare -band $onFolder)).PadRight($width)
            $id.Dispose()
        } catch { $row += 'error'.PadRight($width) }
    }
    $row
}
