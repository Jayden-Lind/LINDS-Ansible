# Copies the files that exist only on LINDS-DC onto JD-FS-01, so JD-FS-01
# holds the union before it is made the DFS-R primary member.
#
# Additive only. Nothing is deleted on either side, and existing files on
# JD-FS-01 are never overwritten - only missing paths are created.
$ErrorActionPreference = 'Stop'
$list = 'C:\ADBackup\only-on-linds.txt'
$log  = 'C:\ADBackup\merge-log.txt'

$entries = @(Get-Content $list | Where-Object { $_.Trim() })
"files to copy: {0:N0}" -f $entries.Count

$copied = 0; $skipped = 0; $failed = 0; $bytes = 0L
$errors = [Collections.Generic.List[string]]::new()

foreach ($e in $entries) {
    $i = $e.IndexOf("`t")
    if ($i -lt 0) { continue }
    $folder = $e.Substring(0, $i)
    $rel    = $e.Substring($i + 1)

    $src = "\\linds-dc\NAS\$folder\$rel"
    $dst = "D:\$folder\$rel"

    if (Test-Path -LiteralPath $dst) { $skipped++; continue }

    try {
        # Split-Path -LiteralPath and -Parent are in incompatible parameter
        # sets on PowerShell 5.1; this also avoids wildcard interpretation.
        $parent = [IO.Path]::GetDirectoryName($dst)
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        $si = Get-Item -LiteralPath $src
        $di = Get-Item -LiteralPath $dst
        $di.LastWriteTime  = $si.LastWriteTime
        $di.CreationTime   = $si.CreationTime
        $bytes += $di.Length
        $copied++
    }
    catch {
        $failed++
        $errors.Add("$folder`t$rel`t$($_.Exception.Message)")
    }

    if (($copied + $failed + $skipped) % 100 -eq 0) {
        "  progress: {0}/{1}  ({2:N1} GB)" -f ($copied + $failed + $skipped), $entries.Count, ($bytes / 1GB)
    }
}

$errors | Set-Content $log -Encoding UTF8
""
"copied  : {0:N0}  ({1:N2} GB)" -f $copied, ($bytes / 1GB)
"skipped : {0:N0}  (already present)" -f $skipped
"failed  : {0:N0}" -f $failed
if ($failed) { "first failures:"; $errors | Select-Object -First 10 | ForEach-Object { "  $_" } }
