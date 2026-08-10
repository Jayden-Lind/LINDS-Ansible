# Retries the files Copy-Item could not resolve. These are hidden/system files
# (Thumbs.db, ~$ Office lock files, .tmp) which the PowerShell FileSystem
# provider hides over UNC; [IO.File]::Copy bypasses the provider entirely.
$ErrorActionPreference = 'Stop'
$log = 'C:\ADBackup\merge-log.txt'

$entries = @(Get-Content $log | Where-Object { $_.Trim() })
"retrying: {0:N0}" -f $entries.Count

$byKind = @{}
$copied = 0; $gone = 0; $failed = 0; $bytes = 0L
$still = [Collections.Generic.List[string]]::new()

foreach ($e in $entries) {
    $parts = $e -split "`t"
    if ($parts.Count -lt 2) { continue }
    $folder = $parts[0]; $rel = $parts[1]

    $kind = if ($rel -match '\\?Thumbs\.db$') { 'Thumbs.db' }
            elseif ($rel -match '\\~\$')      { 'Office lock (~$)' }
            elseif ($rel -match '\.tmp$')     { '.tmp' }
            elseif ($rel -match '\.DS_Store$'){ '.DS_Store' }
            else                              { 'other' }
    $byKind[$kind] = 1 + $byKind[$kind]

    $src = "\\linds-dc\NAS\$folder\$rel"
    $dst = "D:\$folder\$rel"

    if ([IO.File]::Exists($dst)) { continue }
    if (-not [IO.File]::Exists($src)) { $gone++; continue }

    try {
        $parent = [IO.Path]::GetDirectoryName($dst)
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
        [IO.File]::Copy($src, $dst, $true)
        $fi = New-Object IO.FileInfo $dst
        $si = New-Object IO.FileInfo $src
        $fi.LastWriteTimeUtc = $si.LastWriteTimeUtc
        $bytes += $fi.Length
        $copied++
    }
    catch { $failed++; $still.Add("$folder`t$rel`t$($_.Exception.Message)") }
}

""
"composition of the retry set:"
$byKind.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "  {0,-18} {1,5}" -f $_.Key, $_.Value }
""
"copied            : {0:N0}  ({1:N2} MB)" -f $copied, ($bytes / 1MB)
"gone from source  : {0:N0}  (deleted since the inventory was taken)" -f $gone
"still failing     : {0:N0}" -f $failed
if ($failed) { $still | Select-Object -First 8 | ForEach-Object { "  $_" } }
