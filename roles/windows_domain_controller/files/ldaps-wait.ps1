param([int]$TimeoutSeconds)
$Ansible.Changed = $false
$name = "$env:COMPUTERNAME.$env:USERDNSDOMAIN".ToLower()
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    $presented = $null; $tcp = $null
    try {
        $tcp = New-Object Net.Sockets.TcpClient($name, 636)
        # The chain is not judged here; only that the directory
        # presents a certificate at all.
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($name)
        # Not the subject: a domain controller certificate has an empty
        # one and carries its names in the alternative-name extension.
        if ($ssl.IsAuthenticated) {
            $presented = [System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
        }
    } catch { } finally { if ($tcp) { $tcp.Close() } }
    if (-not $presented) { Start-Sleep -Seconds 15 }
} until ($presented -or (Get-Date) -gt $deadline)
if (-not $presented) { throw "LDAPS on ${name}:636 did not complete a TLS handshake." }
[pscustomobject]@{
    issuer     = $presented.Issuer
    thumbprint = $presented.Thumbprint
    expires    = $presented.NotAfter.ToString('yyyy-MM-dd')
}
