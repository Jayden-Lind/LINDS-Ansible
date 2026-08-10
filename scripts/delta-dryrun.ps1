# Read-only. Reports what exists on LINDS-DC but not on JD-FS-01.
# /L = list only, nothing is copied. DfsrPrivate is excluded on both sides.
$folders = 'Zoe','Personal Files','holiday videos','Cheryls Files','business doc','Jayden','Photos'

"folder            | files to copy | bytes to copy | extra on JD-FS-01"
"------------------+---------------+---------------+------------------"
foreach ($f in $folders) {
    $r = robocopy "\\linds-dc\NAS\$f" "D:\$f" /L /E /NFL /NDL /NJH /XD DfsrPrivate /R:0 /W:0 2>&1 | Out-String
    $lines = $r -split "`r?`n"

    function Field($label, $col) {
        $m = $lines | Select-String "^\s+$label :"
        if (-not $m) { return '?' }
        # columns: Total  Copied  Skipped  Mismatch  FAILED  Extras
        $parts = ($m.ToString() -replace "^\s+$label :\s*", '') -split '\s+'
        if ($parts.Count -gt $col) { $parts[$col] } else { '?' }
    }

    "{0,-17} | {1,13} | {2,13} | {3,17}" -f $f, (Field 'Files' 1), (Field 'Bytes' 1), (Field 'Files' 5)
}
