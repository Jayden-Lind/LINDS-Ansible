$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module DFSR
$me = $env:COMPUTERNAME

$lister = {
    param([string[]]$Roots, [string[]]$Filters)
    # robocopy in list mode against a folder that does not exist: every
    # file is "new". Into a Unicode log, not through the pipeline: its
    # console output mangles accented names, and differently on each
    # side, which made 286 files with an accent in their name look lonely.
    $out = Join-Path $env:SystemRoot ('Temp\replicated-files-' + [guid]::NewGuid().ToString('N') + '.txt')
    $log = "$out.log"
    $writer = New-Object IO.StreamWriter $out
    foreach ($root in $Roots) {
        $prefix = $root.TrimEnd('\').Length + 1
        & robocopy.exe $root 'C:\does-not-exist-compare-only' /L /E /XJ /NJH /NJS /NDL /NC /NS /NP /FP /R:0 /W:0 /XD DfsrPrivate /XF $Filters "/UNILOG:$log" | Out-Null
        foreach ($raw in [IO.File]::ReadLines($log, [Text.Encoding]::Unicode)) {
            $line = $raw.Trim()
            if ($line.Length -gt $prefix) { $writer.WriteLine(((Split-Path $root -Leaf) + '|' + $line.Substring($prefix)).ToLowerInvariant()) }
        }
    }
    $writer.Close()
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    $out
}

$lonely = New-Object Collections.Generic.List[string]
$compared = 0
foreach ($group in Get-DfsReplicationGroup -GroupName * -ErrorAction SilentlyContinue | Where-Object GroupName -ne 'Domain System Volume') {
    $all = @(Get-DfsrMembership -GroupName $group.GroupName)
    $mine = @($all | Where-Object ComputerName -ieq $me)
    if (-not $mine) { continue }
    $partner = ($all | Where-Object ComputerName -ine $me | Select-Object -First 1).ComputerName
    if (-not $partner) { continue }
    $pairs = @(foreach ($m in $mine) {
        $theirs = $all | Where-Object { $_.FolderName -eq $m.FolderName -and $_.ComputerName -ieq $partner }
        if ($theirs) { [pscustomobject]@{ here = $m.ContentPath; there = $theirs.ContentPath } }
    })
    $filters = @(Get-DfsReplicatedFolder -GroupName $group.GroupName | ForEach-Object { $_.FileNameToExclude } | Sort-Object -Unique)

    # Two arguments, each an array. Wrapping each in another array joins it into one string on the far side.
    $remoteList = Invoke-Command -ComputerName $partner -ScriptBlock $lister -ArgumentList @($pairs.there), $filters
    if (-not (Invoke-Command -ComputerName $partner -ScriptBlock { param($f) (Get-Item -LiteralPath $f).Length } -ArgumentList $remoteList)) {
        throw "$partner listed no files at all in $($pairs.there -join ', '): not comparing against nothing."
    }
    $localList  = & $lister @($pairs.here) $filters
    try {
        $theirs = New-Object Collections.Generic.HashSet[string]
        $remotePath = "\\$partner\" + ($remoteList -replace '^(\w):', '$1$$')
        foreach ($line in [IO.File]::ReadLines($remotePath)) { [void]$theirs.Add($line) }
        foreach ($line in [IO.File]::ReadLines($localList)) { $compared++; if (-not $theirs.Contains($line)) { $lonely.Add($line) } }
    } finally {
        Remove-Item -LiteralPath $localList -Force -ErrorAction SilentlyContinue
        Invoke-Command -ComputerName $partner -ScriptBlock { param($f) Remove-Item -LiteralPath $f -Force } -ArgumentList $remoteList
    }
}
[ordered]@{ compared = $compared; count = $lonely.Count; first = @($lonely | Select-Object -First 20) } | ConvertTo-Json -Compress
