# build_bitstream.ps1 -- Vollstaendiger Quartus-Build fuer Minimig auf MiSTer
$ErrorActionPreference = "Stop"
$QuartusBin = "C:\altera_lite\25.1std\quartus\bin64"
$MisterDir = "D:\programmier_ordner\FPGA\NanoMig\mister"

Set-Location $MisterDir

Write-Host "=== [1/3] Erzeuge build_id.v ==="
& "$QuartusBin\quartus_sh.exe" -t sys/build_id.tcl compile Minimig Minimig

Write-Host "=== [2/3] Starte quartus_sh --flow compile Minimig ==="
$logFile = Join-Path $MisterDir "build_flow.log"
& "$QuartusBin\quartus_sh.exe" --flow compile Minimig | Tee-Object -FilePath $logFile

if ($LASTEXITCODE -ne 0) {
    Write-Error "Quartus compile FAILED mit Exit-Code $LASTEXITCODE"
    exit 1
}

Write-Host "=== [3/3] Build erfolgreich. Extrahiere Ergebnisse... ==="
$rbf = Join-Path $MisterDir "output_files\Minimig.rbf"
if (-not (Test-Path $rbf)) {
    # Suche ggf. im Hauptordner
    $rbf = Join-Path $MisterDir "Minimig.rbf"
}

if (Test-Path $rbf) {
    $hashObj = Get-FileHash -Algorithm SHA256 $rbf
    $fullHash = $hashObj.Hash.ToLower()
    $shortHash = $fullHash.Substring(0, 8)
    $fileSize = (Get-Item $rbf).Length
    Write-Host "RBF: $rbf"
    Write-Host "Groesse: $fileSize Bytes"
    Write-Host "SHA256: $fullHash"

    $targetRbf = Join-Path $MisterDir "release\2026-11-01\Minimig_$shortHash.rbf"
    Copy-Item $rbf $targetRbf -Force
    Write-Host "Kopiert nach: $targetRbf"
} else {
    Write-Warning "Minimig.rbf nicht gefunden!"
}

$fitSummary = Join-Path $MisterDir "output_files\Minimig.fit.summary"
if (Test-Path $fitSummary) {
    Get-Content $fitSummary | Select-String "Logic utilization|registers|RAM Blocks|DSP Blocks"
}

$staSummary = Join-Path $MisterDir "output_files\Minimig.sta.summary"
if (Test-Path $staSummary) {
    Get-Content $staSummary
}

Write-Host "=== BUILD VOLLSTAENDIG ABGESCHLOSSEN ==="
