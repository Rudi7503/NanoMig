# seed_sweep.ps1 -- baut denselben Stand mit mehreren Fitter-Seeds und
# meldet ALMs, Register, RAM, Setup/Hold und den RBF-Hash je Seed.
#
# Hintergrund: Der Fitter ist deterministisch, aber die Platzierung haengt
# stark am Startwert. Bei 86 Prozent Auslastung haben wir fuer praktisch
# identische Logik schon 1,5 ns Unterschied im Setup-Slack gesehen
# (-0.785 bis -2.275). Ein Seed-Lauf ist deshalb die billigste Art,
# Timing zu verbessern -- ohne Logik zu aendern.
#
# Aufruf:
#   .\seed_sweep.ps1 -Branch rudi/chain-stereo -Seeds 2,3,4,5
#
# Laufzeit: rund 40 Minuten je Seed. Vier Seeds also knapp drei Stunden.

param(
    [string]$Branch = "rudi/chain-stereo",
    [string]$Seeds = "2,3,4,5",   # Komma-Liste, damit -File den Aufruf annimmt
    [string]$Repo = "D:\programmier_ordner\FPGA\NanoMig",
    [string]$QuartusBin = "C:\altera_lite\25.1std\quartus\bin64"
)

$seedList = $Seeds -split "," | ForEach-Object { [int]$_.Trim() }
$results = @()

foreach ($seed in $seedList) {
    $wt = Join-Path $env:TEMP ("seed-$seed")
    Write-Host "=== Seed $seed ==="

    if (Test-Path $wt) { git -C $Repo worktree remove $wt --force 2>&1 | Out-Null }
    git -C $Repo worktree add --detach $wt $Branch --quiet 2>&1 | Out-Null

    $qsf = Join-Path $wt "mister\Minimig.qsf"
    if (-not (Test-Path $qsf)) { Write-Host "Worktree unvollstaendig: $wt"; continue }

    # Seed setzen: vorhandene Zeile ersetzen oder anhaengen
    $lines = Get-Content $qsf
    $filtered = $lines | Where-Object { $_ -notmatch 'set_global_assignment -name SEED' }
    $filtered += "set_global_assignment -name SEED $seed"
    Set-Content -Path $qsf -Value $filtered -Encoding ascii

    $log = Join-Path $wt "mister\seed-$seed.log"
    Push-Location (Join-Path $wt "mister")
    & "$QuartusBin\quartus_sh.exe" -t sys/build_id.tcl compile Minimig Minimig 2>&1 | Out-Null
    & "$QuartusBin\quartus_sh.exe" --flow compile Minimig 2>&1 | Tee-Object -FilePath $log | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    Pop-Location

    $row = [pscustomobject]@{
        Seed = $seed; Ok = $ok; ALMs = ""; Regs = ""; RAM = ""; DSP = ""; Setup = ""; Hold = ""; RBF = ""
    }

    $fit = Join-Path $wt "mister\output_files\Minimig.fit.summary"
    if (Test-Path $fit) {
        $c = Get-Content $fit -Raw
        if ($c -match 'Logic utilization \(in ALMs\)\s*:\s*([\d,]+)') { $row.ALMs = $matches[1] }
        if ($c -match 'Total registers\s*:\s*(\d+)')              { $row.Regs = $matches[1] }
        if ($c -match 'Total RAM Blocks\s*:\s*(\d+)')             { $row.RAM  = $matches[1] }
        if ($c -match 'Total DSP Blocks\s*:\s*(\d+)')             { $row.DSP  = $matches[1] }
    }
    # Die Slack-Zeile steht in der Summary oft in der NAECHSTEN Zeile,
    # deshalb zeilenweise und mit Blick auf die folgenden vier Zeilen.
    $sta = Join-Path $wt "mister\output_files\Minimig.sta.summary"
    if (Test-Path $sta) {
        $lines = Get-Content $sta
        foreach ($kind in @('Setup','Hold')) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "Model $kind 'emu\|pll") {
                    for ($j = $i; $j -lt [Math]::Min($i + 4, $lines.Count); $j++) {
                        if ($lines[$j] -match 'Slack\s*:\s*(-?[\d.,]+)') {
                            if ($kind -eq 'Setup') { $row.Setup = $matches[1] } else { $row.Hold = $matches[1] }
                            break
                        }
                    }
                    break
                }
            }
        }
    }
    $rbf = Join-Path $wt "mister\output_files\Minimig.rbf"
    if (Test-Path $rbf) { $row.RBF = (Get-FileHash $rbf -Algorithm SHA256).Hash.ToLower() }

    $results += $row
    Write-Host ("Seed {0}: ALMs {1}  Setup {2}  Hold {3}" -f $seed, $row.ALMs, $row.Setup, $row.Hold)
}

Write-Host ""
Write-Host "=== Zusammenfassung ==="
$results | Sort-Object { [double]($_.Setup -replace ',', '.') } -Descending | Format-Table -AutoSize

$best = $results | Where-Object { $_.Setup -ne "" } |
        Sort-Object { [double]($_.Setup -replace ',', '.') } -Descending |
        Select-Object -First 1
if ($best) {
    Write-Host ("Bester Seed: {0}  Setup {1}  RBF {2}" -f $best.Seed, $best.Setup, $best.RBF)
    $results | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $env:TEMP "seed_sweep.json") -Encoding ascii
    Write-Host ("Ergebnisse: " + (Join-Path $env:TEMP "seed_sweep.json"))
}
