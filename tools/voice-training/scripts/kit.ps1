# MeshCore Open TAK voice training kit (Windows). START.bat runs this.
# Sets up its own Python and PyTorch (CUDA 12.8, for RTX 50 series) in .venv
# next to it, then shows the menu. Nothing is installed system-wide.
$ErrorActionPreference = "Stop"
$Kit = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Kit
$Uv = Join-Path $Kit "bin\uv.exe"
$Venv = Join-Path $Kit ".venv"
$Py = Join-Path $Venv "Scripts\python.exe"
$Settings = Join-Path $Kit "kit-settings.txt"
$env:C2ROUND = Join-Path $Kit "bin\c2round.exe"
$env:PYTHONUNBUFFERED = "1"

function Run([string]$exe, [string[]]$argv) {
  & $exe @argv
  if ($LASTEXITCODE -ne 0) { throw "$([IO.Path]::GetFileName($exe)) failed (exit $LASTEXITCODE)" }
}

function Setup {
  if (-not (Test-Path (Join-Path $Venv ".kit-ready"))) {
    Write-Host ""
    Write-Host "First run: setting up Python 3.12 and PyTorch for your GPU (about 3 GB, once)." -ForegroundColor Cyan
    if (-not (Test-Path $Py)) {
      Run $Uv @("python", "install", "3.12")
      Run $Uv @("venv", "--python", "3.12", $Venv)
    }
    Run $Uv @("pip", "install", "--python", $Py, "torch==2.7.1", "--index-url", "https://download.pytorch.org/whl/cu128")
    Run $Uv @("pip", "install", "--python", $Py, "-r", (Join-Path $Kit "requirements.txt"))
    New-Item -ItemType File (Join-Path $Venv ".kit-ready") | Out-Null
    Run $Py @("-m", "kit.run", "check")
  }
}

function DataDir {
  if (Test-Path $Settings) { return (Get-Content $Settings -First 1).Trim() }
  $def = Join-Path $Kit "data"
  Write-Host ""
  Write-Host "Where should downloads and prepared data go? The restorer needs about 40 GB free."
  $d = Read-Host "Folder (Enter for $def)"
  if (-not $d) { $d = $def }
  New-Item -ItemType Directory -Force $d | Out-Null
  Set-Content $Settings $d
  return $d
}

try {
  Setup
  while ($true) {
    Write-Host ""
    Write-Host "MeshCore Open TAK voice training kit" -ForegroundColor Cyan
    Write-Host "  1  Brighter voice net for standalones   (downloads 2.4 GB; about 30 min)"
    Write-Host "  2  Voice restorer for the app           (downloads 11 GB; prepares ~1 h, then trains)"
    Write-Host "  3  Export the restorer as it is now"
    Write-Host "  4  Small restorer for standalones       (P4, T-Deck; same data; about 2 h)"
    Write-Host "  5  Export the small restorer as it is now"
    Write-Host "  6  Check the GPU and Codec2"
    Write-Host "  7  Open the output folder"
    Write-Host "  Q  Quit"
    $c = (Read-Host "Choose").Trim().ToUpper()
    $data = $null
    if ($c -in @("1", "2", "3", "4", "5")) { $data = DataDir }
    switch ($c) {
      "1" { Run $Py @("-m", "kit.run", "bright", "--data", $data) }
      "2" {
        $h = Read-Host "Hours to train this time (Enter for 8; run it again later to continue)"
        if (-not $h) { $h = "8" }
        Write-Host "Ctrl+C stops and saves; samples to listen to appear in output\restorer-samples."
        Run $Py @("-m", "kit.run", "restorer", "--data", $data, "--hours", $h)
      }
      "3" { Run $Py @("-m", "kit.run", "export", "--data", $data) }
      "4" {
        $h = Read-Host "Hours to train this time (Enter for 2; run it again later to continue)"
        if (-not $h) { $h = "2" }
        Write-Host "Ctrl+C stops and saves; samples to listen to appear in output\small-restorer-samples."
        Run $Py @("-m", "kit.run", "small", "--data", $data, "--hours", $h)
      }
      "5" { Run $Py @("-m", "kit.run", "small-export", "--data", $data) }
      "6" { Run $Py @("-m", "kit.run", "check") }
      "7" { New-Item -ItemType Directory -Force (Join-Path $Kit "output") | Out-Null; Invoke-Item (Join-Path $Kit "output") }
      "Q" { exit 0 }
      default { Write-Host "Type 1-7 or Q." }
    }
  }
} catch {
  Write-Host ""
  Write-Host "Stopped: $_" -ForegroundColor Red
  Write-Host "Run START.bat again to retry; downloads and training pick up where they left off."
}
