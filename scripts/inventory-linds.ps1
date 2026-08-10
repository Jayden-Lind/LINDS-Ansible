# Read-only. Builds a local inventory of the replicated folders on LINDS-DC
# and writes it to the NAS share so JD-FS-01 can read it in one sequential
# pass rather than making 500k metadata round trips over the tunnel.
$ErrorActionPreference = 'Stop'
$out = 'E:\_dfsr_inventory_linds.txt'
$folders = 'business doc','Cheryls Files','holiday videos','Jayden','Personal Files','Photos','Zoe'

$sw = [IO.StreamWriter]::new($out, $false, [Text.Encoding]::UTF8)
try {
    foreach ($f in $folders) {
        $root = "E:\$f"
        $prefix = $root.Length + 1
        $n = 0
        foreach ($item in [IO.Directory]::EnumerateFiles($root, '*', 'AllDirectories')) {
            if ($item -like '*\DfsrPrivate\*') { continue }
            $rel = $item.Substring($prefix)
            $len = (New-Object IO.FileInfo $item).Length
            $sw.WriteLine("$f`t$rel`t$len")
            $n++
        }
        "  {0,-16} {1,8} files" -f $f, $n
    }
} finally { $sw.Close() }

"inventory written: {0} ({1:N1} MB)" -f $out, ((Get-Item $out).Length / 1MB)
