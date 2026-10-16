param([string]$Work)
$ErrorActionPreference = 'Stop'
Import-Module ADCSAdministration
Stop-Service certsvc -Force
$zip = Get-ChildItem -LiteralPath $Work -Filter *-database.zip | Select-Object -First 1
Expand-Archive -LiteralPath $zip.FullName -DestinationPath "$Work\DataBase" -Force
Restore-CARoleService -Path $Work -DatabaseOnly -Force
# Stored as UTF-8 text for the sake of diffs; reg.exe wants UTF-16.
$reg = Get-ChildItem -LiteralPath $Work -Filter *-configuration.reg | Select-Object -First 1
[IO.File]::WriteAllText("$Work\import.reg", [IO.File]::ReadAllText($reg.FullName, [Text.Encoding]::UTF8), [Text.Encoding]::Unicode)
# reg.exe reports success on the error stream, which would stop the
# script here; judge it by its exit code instead.
$ErrorActionPreference = 'Continue'
& reg.exe import "$Work\import.reg" 2>&1 | Out-Null
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) { throw "reg import failed ($code)" }
Start-Service certsvc
# The service reports "running" some seconds before it answers;
# publishing at once failed with "RPC server unavailable".
$ErrorActionPreference = 'Continue'
foreach ($try in 1..24) {
    & certutil.exe -ping 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 5
}
& certutil.exe -crl 2>&1 | Out-Null
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) { throw "The restored CA could not publish a CRL ($code)" }
$Ansible.Changed = $true
