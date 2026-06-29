# Mock DDM download test - simulates DaVinci Resolve DDM's HTTPS download behavior
# Uses .NET WebClient which uses schannel (same as DaVinci DDM)
# schannel enforces CRL/OCSP revocation checks, which fail for corporate proxy certs
# that have no CRL Distribution Points.
#
# Expected results:
#   WITHOUT Corporate Proxy Fix: fails with CRYPT_E_NO_REVOCATION_CHECK (0x80092012)
#   WITH Corporate Proxy Fix:    succeeds (lux provides cert with CRL DP)

$testUrl = "https://www.blackmagicdesign.com/favicon.ico"

Write-Host "=== DDM Mock Download Test ===" -ForegroundColor Cyan
Write-Host "Testing HTTPS download via schannel (same as DaVinci DDM)" -ForegroundColor Cyan
Write-Host "URL: $testUrl"
Write-Host ""

# Method 1: .NET WebClient (schannel, enforces CRL) - same as DDM
Write-Host "--- Method 1: .NET WebClient (schannel) ---" -ForegroundColor Yellow
try {
    $wc = New-Object System.Net.WebClient
    [System.Net.ServicePointManager]::CheckCertificateRevocationList = $true
    $bytes = $wc.DownloadData($testUrl)
    Write-Host "SUCCESS: Downloaded $($bytes.Length) bytes" -ForegroundColor Green
    Write-Host "Certificate revocation check PASSED" -ForegroundColor Green
} catch [System.Net.WebException] {
    $inner = $_.Exception.InnerException
    $msg = $_.Exception.Message
    Write-Host "FAILED: $msg" -ForegroundColor Red
    if ($inner) {
        Write-Host "Inner: $($inner.Message)" -ForegroundColor Red
    }
    if ($msg -match "0x80092012" -or $msg -match "revocation" -or ($inner -and $inner.Message -match "revocation")) {
        Write-Host ""
        Write-Host ">>> CONFIRMED: CRYPT_E_NO_REVOCATION_CHECK error!" -ForegroundColor Red
        Write-Host ">>> This is exactly what DaVinci DDM encounters." -ForegroundColor Red
        Write-Host ">>> Enable 'Corporate Proxy Fix' in Lux Settings and add '*.blackmagicdesign.com'" -ForegroundColor Yellow
    }
} catch {
    Write-Host "FAILED: $_" -ForegroundColor Red
}

Write-Host ""

# Method 2: Invoke-WebRequest (also uses schannel on Windows)
Write-Host "--- Method 2: Invoke-WebRequest (schannel) ---" -ForegroundColor Yellow
try {
    $r = Invoke-WebRequest -Uri $testUrl -UseBasicParsing -TimeoutSec 15
    Write-Host "SUCCESS: HTTP $($r.StatusCode), $($r.RawContentLength) bytes" -ForegroundColor Green
} catch {
    $msg = $_.Exception.Message
    Write-Host "FAILED: $msg" -ForegroundColor Red
    if ($msg -match "revocation" -or ($_.Exception.InnerException -and $_.Exception.InnerException.Message -match "revocation")) {
        Write-Host ">>> CRYPT_E_NO_REVOCATION_CHECK via Invoke-WebRequest" -ForegroundColor Red
    }
}

Write-Host ""

# Method 3: curl (different revocation behavior - for comparison)
Write-Host "--- Method 3: curl.exe (for comparison) ---" -ForegroundColor Yellow
$curlResult = curl.exe -s -o NUL -w "%{http_code}" --max-time 10 $testUrl 2>&1
Write-Host "curl result: HTTP $curlResult" -ForegroundColor $(if ($curlResult -eq "200") { "Green" } else { "Red" })

Write-Host ""
Write-Host "=== Test Complete ===" -ForegroundColor Cyan
Write-Host "If Method 1 failed with revocation error:" -ForegroundColor Yellow
Write-Host "  1. Lux Settings -> Corporate Proxy Fix -> Enable" -ForegroundColor White
Write-Host "  2. Click 'Install CA' to trust Lux's MITM certificate" -ForegroundColor White
Write-Host "  3. Add '*.blackmagicdesign.com' to inspection domains" -ForegroundColor White
Write-Host "  4. Run this script again - Method 1 should succeed" -ForegroundColor White
