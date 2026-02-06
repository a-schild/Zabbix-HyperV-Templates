# ========================================
# Script de Firma para Zabbix Hyper-V PS1
# ========================================

# Parámetros
$scriptPath = 'C:\Program Files\Zabbix Agent 2\hyper-v-monitoring2.ps1'
$exportPath = 'C:\zabbix-signing.cer'
$certSubject = 'CN=Zabbix Hyper-V Signing Cert'

# 1. Verificar que el script existe
if (-not (Test-Path $scriptPath)) {
    Write-Error "El script no existe: $scriptPath"
    exit 1
}

# 2. Buscar certificado existente
$cert = Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert | Where-Object { $_.Subject -like "*$certSubject*" } | Select-Object -First 1

if (-not $cert) {
    Write-Host "Creando nuevo certificado autofirmado..." -ForegroundColor Yellow
    $cert = New-SelfSignedCertificate -Subject $certSubject -Type CodeSigningCert -CertStoreLocation Cert:\LocalMachine\My -KeyUsage DigitalSignature -KeyLength 4096 -NotAfter (Get-Date).AddYears(5)
    Write-Host "Certificado creado. Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green
}

# 3. Firmar el script
Write-Host "Firmando script..." -ForegroundColor Cyan
Set-AuthenticodeSignature -Certificate $cert -FilePath $scriptPath | Out-Null

# 4. Verificar firma
$signature = Get-AuthenticodeSignature $scriptPath
if ($signature.Status -eq 'Valid') {
    Write-Host "Firma OK: $($signature.SignerCertificate.Subject)" -ForegroundColor Green
} else {
    Write-Warning "Firma inválida: $($signature.Status)"
}

# 5. Exportar certificado público
Export-Certificate -Cert $cert -FilePath $exportPath | Out-Null

# 6. Importar a TrustedPublisher y Root (para confianza en otras máquinas)
Import-Certificate -FilePath $exportPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
Import-Certificate -FilePath $exportPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null

Write-Host "Certificado importado a TrustedPublisher y Root." -ForegroundColor Green

# 7. Limpiar archivo temporal
Remove-Item $exportPath -Force

# 8. Configurar policy (opcional, descomenta si necesitas)
# Set-ExecutionPolicy AllSigned -Scope LocalMachine -Force

Write-Host "`n¡Listo! El script está firmado y el cert confiable." -ForegroundColor Green
Write-Host "Verifica: Get-AuthenticodeSignature '$scriptPath'" -ForegroundColor Yellow
