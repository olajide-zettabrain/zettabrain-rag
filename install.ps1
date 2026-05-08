# ============================================================
# ZettaBrain RAG — Windows Installer
# Usage: [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://zettabrain.app/install.ps1 | iex
# ============================================================

# Force TLS 1.2 — required on Windows Server 2016 and older which default to TLS 1.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ErrorActionPreference = "Stop"
$EMBED_MODEL = "nomic-embed-text"
$LOG_FILE = "$env:LOCALAPPDATA\ZettaBrain\install.log"

New-Item -ItemType Directory -Force -Path (Split-Path $LOG_FILE) | Out-Null

function Log       { param($m) Add-Content -Path $LOG_FILE -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" -EA SilentlyContinue }
function Step      { param($n,$m) Write-Host "`n[$n] $m" -ForegroundColor Blue }
function Info      { param($m) Write-Host "  -> $m" -ForegroundColor Cyan;   Log "INFO  $m" }
function OK        { param($m) Write-Host "  v  $m" -ForegroundColor Green;  Log "OK    $m" }
function Warn      { param($m) Write-Host "  !  $m" -ForegroundColor Yellow; Log "WARN  $m" }
function Fail      { param($m) Write-Host "  x  ERROR: $m" -ForegroundColor Red; Log "ERROR $m"; exit 1 }

function Refresh-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
}

# ── Banner ───────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  +======================================================+" -ForegroundColor Blue
Write-Host "  |               ZettaBrain RAG                        |" -ForegroundColor Blue
Write-Host "  |   Local private AI - your data stays on device      |" -ForegroundColor Blue
Write-Host "  +======================================================+" -ForegroundColor Blue
Write-Host ""

# ── Admin check ──────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Fail "Run PowerShell as Administrator, then retry:`n  irm https://zettabrain.app/install.ps1 | iex"
}

# ── 1/5 OS detection ─────────────────────────────────────────
Step "1/5" "Detecting operating system"
$osVer = [System.Environment]::OSVersion.Version
OK "Windows $($osVer.Major).$($osVer.Minor) (Build $($osVer.Build))"

$hasWinget = [bool](Get-Command winget -EA SilentlyContinue)
if ($hasWinget) { Info "winget: $(winget --version)" }

# ── 2/5 System dependencies ──────────────────────────────────
Step "2/5" "Installing system dependencies"

# Find Python 3.9+
$PYTHON = $null
foreach ($py in @("python3.12","python3.11","python3.10","python3.9","python3","python")) {
    if (Get-Command $py -EA SilentlyContinue) {
        $n = & $py -c "import sys; print(sys.version_info.major*10+sys.version_info.minor)" 2>$null
        if ([int]$n -ge 39) { $PYTHON = $py; break }
    }
}

if (-not $PYTHON) {
    Info "Installing Python 3.11..."
    if ($hasWinget) {
        winget install --id Python.Python.3.11 --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-File $LOG_FILE -Append
    } else {
        $url = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
        $tmp = "$env:TEMP\python-installer.exe"
        Info "Downloading Python 3.11 (~25MB)..."
        Invoke-WebRequest -Uri $url -OutFile $tmp
        Start-Process $tmp -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1" -Wait
        Remove-Item $tmp -EA SilentlyContinue
    }
    Refresh-Path
    foreach ($py in @("python3.11","python3","python")) {
        if (Get-Command $py -EA SilentlyContinue) { $PYTHON = $py; break }
    }
    if (-not $PYTHON) { Fail "Could not install Python. Check log: $LOG_FILE" }
}

OK "Python: $PYTHON ($(& $PYTHON --version 2>&1))"

# ── 3/5 NVIDIA drivers ───────────────────────────────────────
Step "3/5" "NVIDIA drivers"
OK "Windows manages GPU drivers — install via GeForce Experience or nvidia.com if needed."

# ── 4/5 ZettaBrain RAG via pipx ──────────────────────────────
Step "4/5" "Installing ZettaBrain RAG"

if (-not (Get-Command pipx -EA SilentlyContinue)) {
    Info "Installing pipx..."

    # Ensure pip itself is available and up to date
    & $PYTHON -m ensurepip --upgrade 2>&1 | Out-File $LOG_FILE -Append
    Info "Upgrading pip..."
    & $PYTHON -m pip install --upgrade pip 2>&1 | ForEach-Object { "  $_" }

    # Install pipx — show output so failures are visible
    Info "Installing pipx via pip..."
    & $PYTHON -m pip install --upgrade pipx 2>&1 | ForEach-Object { "  $_" }

    # Add pipx to PATH for this session
    & $PYTHON -m pipx ensurepath 2>&1 | Out-File $LOG_FILE -Append
    Refresh-Path
    $env:PATH += ";$env:USERPROFILE\.local\bin;$env:APPDATA\Python\Scripts"
    $env:PATH += ";$env:USERPROFILE\AppData\Roaming\Python\Python311\Scripts"
    hash 2>$null; $null = $null  # no-op, just refresh
}

$PIPX = if (Get-Command pipx -EA SilentlyContinue) { "pipx" }
        elseif (Test-Path "$env:USERPROFILE\.local\bin\pipx.exe") { "$env:USERPROFILE\.local\bin\pipx.exe" }
        elseif (Test-Path "$env:APPDATA\Python\Scripts\pipx.exe") { "$env:APPDATA\Python\Scripts\pipx.exe" }
        elseif (Test-Path "$env:USERPROFILE\AppData\Roaming\Python\Python311\Scripts\pipx.exe") { "$env:USERPROFILE\AppData\Roaming\Python\Python311\Scripts\pipx.exe" }
        else { Fail "Could not install pipx. Check log: $LOG_FILE" }

OK "pipx $(& $PIPX --version 2>$null)"

Write-Host ""
# 2>&1 merges stderr into stdout so "nothing has been installed" doesn't throw
$zbInstalled = (& $PIPX list 2>&1) | Select-String "zettabrain-rag"
if ($zbInstalled) {
    Info "Upgrading zettabrain-rag (downloading latest + dependencies)..."
    Write-Host "  (This can take 2-5 minutes — please wait)"
    Write-Host ""
    & $PIPX upgrade --pip-args='--no-cache-dir' zettabrain-rag 2>&1 | ForEach-Object { "  $_" }
} else {
    Info "Installing zettabrain-rag (downloading package + dependencies)..."
    Write-Host "  (This can take 3-6 minutes — please wait)"
    Write-Host ""
    & $PIPX install --pip-args='--no-cache-dir' zettabrain-rag 2>&1 | ForEach-Object { "  $_" }
}

# Add pipx bin to system PATH permanently
Refresh-Path
$pipxBin = "$env:USERPROFILE\.local\bin"
$machinePath = [System.Environment]::GetEnvironmentVariable("PATH","Machine")
if ($machinePath -notlike "*$pipxBin*") {
    [System.Environment]::SetEnvironmentVariable("PATH", "$machinePath;$pipxBin", "Machine")
    $env:PATH += ";$pipxBin"
}

$INSTALLED_VERSION = "$(& zettabrain --version 2>$null)"
if (-not $INSTALLED_VERSION) { $INSTALLED_VERSION = "latest" }
Write-Host ""
OK "ZettaBrain RAG installed: $INSTALLED_VERSION"

# ── 5/5 Ollama ───────────────────────────────────────────────
Step "5/5" "Installing Ollama + embedding model"

if (Get-Command ollama -EA SilentlyContinue) {
    Info "Ollama already installed: $((ollama --version 2>&1) | Select-Object -First 1)"
} else {
    Info "Installing Ollama..."
    if ($hasWinget) {
        winget install --id Ollama.Ollama --silent --accept-package-agreements --accept-source-agreements 2>&1 | ForEach-Object { "  $_" }
    } else {
        $url = "https://ollama.com/download/OllamaSetup.exe"
        $tmp = "$env:TEMP\OllamaSetup.exe"
        Info "Downloading Ollama (~60MB)..."
        Invoke-WebRequest -Uri $url -OutFile $tmp
        Start-Process $tmp -ArgumentList "/silent" -Wait
        Remove-Item $tmp -EA SilentlyContinue
    }
    Refresh-Path
    OK "Ollama installed."
}

# Ollama runs as a background process on Windows (no systemctl)
Info "Starting Ollama..."
$ollamaRunning = Get-Process -Name "ollama" -EA SilentlyContinue
if (-not $ollamaRunning) {
    Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -EA SilentlyContinue
    Start-Sleep -Seconds 3
}

Info "Pulling embedding model: $EMBED_MODEL (~275MB)..."
& ollama pull $EMBED_MODEL 2>&1 | ForEach-Object { "  $_" }
OK "Embedding model ready."

# ── Done ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |       ZettaBrain RAG installed successfully!         |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host ""
Write-Host "  Version  : $INSTALLED_VERSION" -ForegroundColor Green
Write-Host "  Log file : $LOG_FILE" -ForegroundColor Green
Write-Host ""
Write-Host "  To reinstall/upgrade:" -ForegroundColor White
Write-Host "  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://zettabrain.app/install.ps1 | iex" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host ""
Write-Host "  1. Run setup:" -ForegroundColor White
Write-Host "     zettabrain-setup" -ForegroundColor Cyan
Write-Host ""
Write-Host "  2. Launch the web GUI:" -ForegroundColor White
Write-Host "     zettabrain-server" -ForegroundColor Cyan
Write-Host "     Open: https://local.zettabrain.app:7860" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. Or start CLI chat:" -ForegroundColor White
Write-Host "     zettabrain-chat" -ForegroundColor Cyan
Write-Host ""

Log "Installation completed. Version: $INSTALLED_VERSION"
