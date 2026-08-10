# Read-only. Reports whether DFSR is actually replicating: per-folder runtime
# state, connection state, and the most recent service events.
$ErrorActionPreference = 'Continue'
"host: $env:COMPUTERNAME"

"`n===== replicated folder runtime state ====="
@(Get-WmiObject -Namespace root\microsoftdfs -Class DfsrReplicatedFolderInfo -ErrorAction SilentlyContinue) |
    Select-Object ReplicatedFolderName, State, CurrentStageSizeInMb, CurrentConflictSizeInMb |
    Sort-Object ReplicatedFolderName | Format-Table -AutoSize | Out-String -Width 160

"`n===== connections ====="
@(Get-WmiObject -Namespace root\microsoftdfs -Class DfsrConnectionInfo -ErrorAction SilentlyContinue) |
    Select-Object PartnerName, Inbound, State, LastErrorCode |
    Format-Table -AutoSize | Out-String -Width 160

"`n===== last 20 DFS Replication events ====="
Get-WinEvent -LogName 'DFS Replication' -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName,
        @{n='Message';e={ ($_.Message -split "`r?`n")[0] }} |
    Format-Table -AutoSize | Out-String -Width 200
