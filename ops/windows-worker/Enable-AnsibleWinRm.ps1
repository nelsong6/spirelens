param(
    [int]$Port = 5986
)

$ErrorActionPreference = "Stop"

Write-Host "Enabling WinRM for Ansible over HTTPS..."

Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

winrm set winrm/config/service '@{AllowUnencrypted="false"}' | Out-Null
winrm set winrm/config/service/auth '@{Basic="false";Kerberos="true";Negotiate="true"}' | Out-Null

$listenersText = (winrm enumerate winrm/config/listener) | Out-String
if ($listenersText -notmatch "Transport = HTTPS") {
    $hostname = $env:COMPUTERNAME
    $cert = New-SelfSignedCertificate `
        -DnsName $hostname `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -NotAfter (Get-Date).AddYears(3)

    $selector = "winrm/config/Listener?Address=*+Transport=HTTPS"
    $value = "@{Hostname=\"$hostname\";CertificateThumbprint=\"$($cert.Thumbprint)\"}"
    winrm create $selector $value | Out-Null
}

if (-not (Get-NetFirewallRule -DisplayName "Allow WinRM HTTPS 5986" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -DisplayName "Allow WinRM HTTPS 5986" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port | Out-Null
}

Write-Host "Current WinRM listeners:"
winrm enumerate winrm/config/listener
