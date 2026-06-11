#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Creates (or reuses) a self-signed code-signing certificate and signs the
    Hyper-V monitoring script so it can run under the AllSigned / RemoteSigned
    PowerShell execution policies.

.DESCRIPTION
    In hardened environments the Zabbix agent cannot execute
    hyper-v-monitoring2.ps1 unless it is digitally signed. This helper:
      1. Verifies the target script exists.
      2. Creates a 4096-bit self-signed code-signing certificate (valid 5
         years) in Cert:\LocalMachine\My, or reuses an existing one.
      3. Signs the script (with a timestamp, so the signature stays valid
         after the certificate expires).
      4. Verifies the resulting signature.
      5. Imports the public certificate into the LocalMachine TrustedPublisher
         and Root stores so signed scripts run without prompting.
      6. Optionally switches the machine execution policy to AllSigned.

    Must be run elevated (it writes to LocalMachine certificate stores).

.PARAMETER ScriptPath
    Full path to the PowerShell script to sign.
    Defaults to 'C:\Program Files\Zabbix Agent 2\hyper-v-monitoring2.ps1'.

.PARAMETER CertSubject
    Subject of the code-signing certificate to create / look up.

.PARAMETER TimestampServer
    RFC 3161 timestamp server used when signing. Pass an empty string to skip
    timestamping (not recommended). Defaults to the DigiCert public server.

.PARAMETER SetExecutionPolicy
    If specified, sets the LocalMachine execution policy to AllSigned after
    signing. Off by default because it affects every PowerShell script on the
    host, not just this one.

.EXAMPLE
    .\ZabbixAgentScriptSigner.ps1

.EXAMPLE
    .\ZabbixAgentScriptSigner.ps1 -ScriptPath 'D:\Zabbix\hyper-v-monitoring2.ps1'

.NOTES
    SECURITY WARNING - read before running:

    This script establishes machine-wide code-signing trust using a
    self-signed certificate. Understand the trade-offs:

      * Importing the certificate into Cert:\LocalMachine\Root makes the host
        trust it as a root certificate authority. Anything signed by the
        matching private key is then treated as a trusted publisher on this
        machine. (Root is required here only because the certificate is
        self-signed and is therefore its own CA.)
      * The private key stays in Cert:\LocalMachine\My on this host. Anyone who
        gains administrative/local access can use it to sign arbitrary scripts
        that will pass AllSigned and appear trusted. The signature proves
        nothing about identity - it is self-issued.
      * -SetExecutionPolicy AllSigned changes policy for ALL PowerShell on the
        machine, which may block other unsigned scripts you rely on.

    Lower-risk alternatives to consider:
      * Sign with a certificate issued by your internal/enterprise PKI instead
        of a self-signed one (no Root import needed, identity is validated).
      * Use the RemoteSigned policy instead of AllSigned.
      * Scope the execution policy to a process or user rather than the machine.

    Based on the contribution in PR #46 (author: AnthonyTepach).
#>

[CmdletBinding()]
param(
    [string]$ScriptPath = 'C:\Program Files\Zabbix Agent 2\hyper-v-monitoring2.ps1',
    [string]$CertSubject = 'CN=Zabbix Hyper-V Signing Cert',
    [string]$TimestampServer = 'http://timestamp.digicert.com',
    [switch]$SetExecutionPolicy
)

$ErrorActionPreference = 'Stop'

# 1. Verify the target script exists
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Error "Script not found: $ScriptPath"
    exit 1
}

# 2. Reuse an existing signing certificate if one is already present
$cert = Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert |
    Where-Object { $_.Subject -like "*$CertSubject*" } |
    Select-Object -First 1

if (-not $cert) {
    Write-Host "Creating new self-signed code-signing certificate..." -ForegroundColor Yellow
    $cert = New-SelfSignedCertificate -Subject $CertSubject -Type CodeSigningCert `
        -CertStoreLocation Cert:\LocalMachine\My -KeyUsage DigitalSignature `
        -KeyLength 4096 -NotAfter (Get-Date).AddYears(5)
    Write-Host "Certificate created. Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green
} else {
    Write-Host "Reusing existing certificate. Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green
}

# 3. Sign the script. Timestamping keeps the signature valid after the
#    certificate's own expiry date.
Write-Host "Signing script..." -ForegroundColor Cyan
$signParams = @{
    Certificate = $cert
    FilePath    = $ScriptPath
}
if ($TimestampServer) { $signParams['TimestampServer'] = $TimestampServer }
Set-AuthenticodeSignature @signParams | Out-Null

# 4. Verify the signature
$signature = Get-AuthenticodeSignature -LiteralPath $ScriptPath
if ($signature.Status -eq 'Valid') {
    Write-Host "Signature OK: $($signature.SignerCertificate.Subject)" -ForegroundColor Green
} else {
    Write-Warning "Invalid signature: $($signature.Status)"
}

# 5. Export the public certificate to a temporary file
$exportPath = Join-Path $env:TEMP 'zabbix-signing.cer'
Export-Certificate -Cert $cert -FilePath $exportPath | Out-Null

# 6. Trust the certificate so signed scripts run without prompting.
#    TrustedPublisher -> avoids the "Do you want to run software from this
#                        untrusted publisher?" prompt under AllSigned.
#    Root             -> required because the certificate is self-signed and is
#                        therefore its own CA; without it the chain cannot be
#                        validated.
#    SECURITY: see the warning in the .NOTES block / README before doing this.
Import-Certificate -FilePath $exportPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
Import-Certificate -FilePath $exportPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Write-Host "Certificate imported into TrustedPublisher and Root stores." -ForegroundColor Green

# 7. Remove the temporary export file
Remove-Item -LiteralPath $exportPath -Force

# 8. Optionally enforce the AllSigned execution policy (affects the whole machine)
if ($SetExecutionPolicy) {
    Write-Host "Setting LocalMachine execution policy to AllSigned..." -ForegroundColor Yellow
    Set-ExecutionPolicy AllSigned -Scope LocalMachine -Force
}

Write-Host "`nDone. The script is signed and the certificate is trusted." -ForegroundColor Green
Write-Host "Verify with: Get-AuthenticodeSignature '$ScriptPath'" -ForegroundColor Yellow
