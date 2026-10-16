param([string]$Volumes)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$done = @()
foreach ($want in ($Volumes | ConvertFrom-Json)) {
    # A moved disk is offline, so its volume cannot be seen yet.
    foreach ($disk in Get-Disk | Where-Object { $_.IsOffline -or $_.IsReadOnly }) {
        if ($disk.IsOffline)  { Set-Disk -Number $disk.Number -IsOffline $false;  $Ansible.Changed = $true }
        if ((Get-Disk -Number $disk.Number).IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false; $Ansible.Changed = $true }
    }
    $volume = $null
    foreach ($try in 1..10) {
        $volume = Get-Volume | Where-Object { $_.FileSystemLabel -eq $want.label -and $_.DriveType -eq 'Fixed' }
        if ($volume) { break }; Start-Sleep -Seconds 2
    }
    if (-not $volume) { throw "No volume labelled '$($want.label)' on this server. Is the data disk attached to the VM?" }
    if (@($volume).Count -gt 1) { throw "More than one volume is labelled '$($want.label)'." }
    if ("$($volume.DriveLetter)" -ne $want.letter) {
        # Whatever holds the letter now (usually the CD drive) moves aside.
        $holder = Get-CimInstance Win32_Volume -Filter "DriveLetter='$($want.letter):'"
        if ($holder) {
            $free = [char[]](70..90) | Where-Object { -not (Get-CimInstance Win32_Volume -Filter "DriveLetter='${_}:'") -and "$_" -ne $want.letter } | Select-Object -Last 1
            Set-CimInstance -InputObject $holder -Property @{ DriveLetter = "${free}:" }
        }
        Get-Partition | Where-Object { $_.AccessPaths -contains $volume.Path } | Set-Partition -NewDriveLetter $want.letter
        $Ansible.Changed = $true
    }
    $done += "$($want.label) is $($want.letter):"
}
$done
