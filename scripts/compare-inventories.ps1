# Read-only. Compares LINDS-DC's inventory against the local copy on JD-FS-01.
# Reads the remote inventory as ONE sequential file rather than doing per-file
# metadata round trips over the tunnel.
$ErrorActionPreference = 'Stop'
$remote  = '\\linds-dc\NAS\_dfsr_inventory_linds.txt'
$folders = 'business doc','Cheryls Files','holiday videos','Jayden','Personal Files','Photos','Zoe'
$onlyLindsOut = 'C:\ADBackup\only-on-linds.txt'
New-Item -ItemType Directory -Path (Split-Path $onlyLindsOut) -Force | Out-Null

if (-not (Test-Path $remote)) { throw "remote inventory not found: $remote" }
"reading remote inventory ({0:N1} MB)..." -f ((Get-Item $remote).Length / 1MB)

# key = "folder<TAB>relpath" (case-insensitive), value = size
$lindsSize = [Collections.Generic.Dictionary[string,long]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($line in [IO.File]::ReadLines($remote)) {
    $i = $line.LastIndexOf("`t")
    if ($i -lt 0) { continue }
    $lindsSize[$line.Substring(0, $i)] = [long]$line.Substring($i + 1)
}
"  {0:N0} entries from LINDS-DC" -f $lindsSize.Count

$localKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$sizeMismatch = 0
foreach ($f in $folders) {
    $root = "D:\$f"
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $prefix = $root.Length + 1
    foreach ($item in [IO.Directory]::EnumerateFiles($root, '*', 'AllDirectories')) {
        if ($item -like '*\DfsrPrivate\*') { continue }
        $key = "$f`t" + $item.Substring($prefix)
        [void]$localKeys.Add($key)
        $sz = 0L
        if ($lindsSize.TryGetValue($key, [ref]$sz)) {
            if ($sz -ne (New-Object IO.FileInfo $item).Length) { $sizeMismatch++ }
        }
    }
}
"  {0:N0} entries on JD-FS-01" -f $localKeys.Count

# --- per-folder breakdown --------------------------------------------------
"`nfolder           | on LINDS |  on JD-FS | only LINDS | only JD-FS"
"-----------------+----------+-----------+------------+-----------"
$onlyLinds = [Collections.Generic.List[string]]::new()
foreach ($f in $folders) {
    $pfx = "$f`t"
    $l = @($lindsSize.Keys | Where-Object { $_.StartsWith($pfx, 'OrdinalIgnoreCase') })
    $j = @($localKeys      | Where-Object { $_.StartsWith($pfx, 'OrdinalIgnoreCase') })
    $lSet = [Collections.Generic.HashSet[string]]::new([string[]]$l, [StringComparer]::OrdinalIgnoreCase)
    $jSet = [Collections.Generic.HashSet[string]]::new([string[]]$j, [StringComparer]::OrdinalIgnoreCase)
    $ol = [Collections.Generic.HashSet[string]]::new($lSet, [StringComparer]::OrdinalIgnoreCase)
    $ol.ExceptWith($jSet)
    $oj = [Collections.Generic.HashSet[string]]::new($jSet, [StringComparer]::OrdinalIgnoreCase)
    $oj.ExceptWith($lSet)
    $onlyLinds.AddRange([string[]]$ol)
    "{0,-16} | {1,8:N0} | {2,9:N0} | {3,10:N0} | {4,10:N0}" -f $f, $lSet.Count, $jSet.Count, $ol.Count, $oj.Count
}

$onlyLinds | Set-Content $onlyLindsOut -Encoding UTF8
"`nfiles present only on LINDS-DC : {0:N0}  (list: {1})" -f $onlyLinds.Count, $onlyLindsOut
"same-path files differing in size: {0:N0}" -f $sizeMismatch
