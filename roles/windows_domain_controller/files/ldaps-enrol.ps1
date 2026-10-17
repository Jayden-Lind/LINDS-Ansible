param([int]$TimeoutSeconds)
$Ansible.Changed = $false
function Get-ServerCertificate {
    # 1.3.6.1.5.5.7.3.1 is Server Authentication.
    Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and
        ($_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1')
    } | Sort-Object NotAfter -Descending | Select-Object -First 1
}
$certificate = Get-ServerCertificate
if (-not $certificate) {
    gpupdate.exe /target:computer /force | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        certutil.exe -pulse | Out-Null
        Start-Sleep -Seconds 20
        $certificate = Get-ServerCertificate
    } until ($certificate -or (Get-Date) -gt $deadline)
    $Ansible.Changed = [bool]$certificate
}
if (-not $certificate) {
    throw 'No server certificate was enrolled. See docs/windows/runbooks/certificate-enrolment.md, and the CertificateServicesClient-AutoEnrollment events in the Application log here.'
}
[pscustomobject]@{
    subject = $certificate.Subject
    issuer  = $certificate.Issuer
    expires = $certificate.NotAfter.ToString('yyyy-MM-dd')
}
