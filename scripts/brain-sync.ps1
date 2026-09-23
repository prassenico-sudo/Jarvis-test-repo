# brain-sync.ps1
# Laedt einen Obsidian-Vault in ein PRIVATES GitHub-Repo hoch, damit Claude
# ihn in Cloud-Sitzungen bearbeiten kann, auch wenn der PC aus ist.
#
# Start (PowerShell):
#   irm https://raw.githubusercontent.com/prassenico-sudo/Jarvis-test-repo/claude/zen-archimedes-2rfbr7/scripts/brain-sync.ps1 | iex

$ErrorActionPreference = 'Stop'
$GitHubUser = 'prassenico-sudo'
$RepoName   = 'brain'
$RemoteUrl  = "https://github.com/$GitHubUser/$RepoName.git"

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Ask($text, $default = 'j') {
    $answer = Read-Host "$text [$default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }
    return $answer.Trim().ToLower().StartsWith('j')
}

# --- 1. Git pruefen / installieren -----------------------------------------
Step 'Pruefe Git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'Git ist nicht installiert. Installiere Git ueber winget ...'
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git wurde installiert, ist aber noch nicht verfuegbar. Bitte PowerShell neu oeffnen und den Befehl nochmal ausfuehren.'
    }
}
Write-Host (git --version)

# --- 2. Obsidian-Vault finden ----------------------------------------------
Step 'Suche Obsidian-Vaults'
$vaults = @()
$obsidianConfig = Join-Path $env:APPDATA 'obsidian\obsidian.json'
if (Test-Path $obsidianConfig) {
    $cfg = Get-Content $obsidianConfig -Raw | ConvertFrom-Json
    foreach ($prop in $cfg.vaults.PSObject.Properties) {
        if (Test-Path $prop.Value.path) { $vaults += $prop.Value.path }
    }
}

if ($vaults.Count -eq 0) {
    $vault = Read-Host 'Kein Vault gefunden. Bitte den Pfad zum Vault eingeben'
} elseif ($vaults.Count -eq 1) {
    $vault = $vaults[0]
    Write-Host "Gefunden: $vault"
} else {
    for ($i = 0; $i -lt $vaults.Count; $i++) { Write-Host "  [$($i + 1)] $($vaults[$i])" }
    $choice = [int](Read-Host 'Welcher Vault ist dein Brain? Nummer eingeben')
    $vault = $vaults[$choice - 1]
}
if (-not (Test-Path $vault)) { throw "Pfad nicht gefunden: $vault" }
Set-Location $vault
Write-Host "Vault: $vault" -ForegroundColor Green

# --- 3. .gitignore: Geheimnisse und Obsidian-Cache ausschliessen -------------
Step 'Schliesse Geheimnisse und Cache-Dateien aus'
$ignoreRules = @(
    '# --- brain-sync ---',
    '.obsidian/workspace*.json',
    '.obsidian/cache',
    '.trash/',
    '.env',
    '.env.*',
    '*.pem',
    '*.key',
    '*.p12',
    '*.pfx',
    'secrets.*',
    'credentials*.json',
    'Thumbs.db',
    'desktop.ini'
)
$gitignore = Join-Path $vault '.gitignore'
$existing = if (Test-Path $gitignore) { Get-Content $gitignore } else { @() }
$missing = $ignoreRules | Where-Object { $existing -notcontains $_ }
if ($missing) { Add-Content -Path $gitignore -Value $missing -Encoding UTF8 }

# Notizen nach API-Schluesseln / Private Keys durchsuchen
$secretPattern = '(?i)(api[_-]?key|api[_-]?secret|secret[_-]?key|access[_-]?token|password|passwort)\s*[:=]\s*\S{12,}|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
$suspicious = Get-ChildItem -Recurse -File -Include *.md, *.txt, *.json, *.yaml, *.yml, *.csv, *.py, *.js, *.ts -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\\.git\\|\\\.obsidian\\' } |
    Where-Object { Select-String -Path $_.FullName -Pattern $secretPattern -Quiet -ErrorAction SilentlyContinue }

if ($suspicious) {
    Write-Host ''
    Write-Host 'ACHTUNG: Diese Dateien sehen aus, als enthielten sie Passwoerter oder API-Schluessel:' -ForegroundColor Yellow
    $suspicious | ForEach-Object { Write-Host "  - $($_.FullName.Substring($vault.Length).TrimStart('\'))" }
    if (Ask 'Diese Dateien NICHT hochladen? (empfohlen)') {
        $rel = $suspicious | ForEach-Object { $_.FullName.Substring($vault.Length).TrimStart('\').Replace('\', '/') }
        Add-Content -Path $gitignore -Value $rel -Encoding UTF8
        Write-Host 'Ausgeschlossen.' -ForegroundColor Green
    }
} else {
    Write-Host 'Keine offensichtlichen Geheimnisse gefunden.'
}

# --- 4. Lokales Git-Repo einrichten ----------------------------------------
Step 'Richte Git im Vault ein'
if (-not (Test-Path (Join-Path $vault '.git'))) { git init -b main | Out-Null }
if (-not (git config user.name))  { git config user.name  $GitHubUser }
if (-not (git config user.email)) { git config user.email "$GitHubUser@users.noreply.github.com" }
git add -A
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) { git commit -m 'Brain: Vault-Stand hochladen' | Out-Null }
git branch -M main

# --- 5. Privates Repo auf GitHub anlegen (Browser) --------------------------
Step "Privates GitHub-Repo '$RepoName' anlegen"
Write-Host 'Der Browser oeffnet sich. Pruefe, dass "Private" ausgewaehlt ist, und klicke auf "Create repository".'
Write-Host 'Falls das Repo schon existiert, schliess den Tab einfach.'
Start-Process "https://github.com/new?name=$RepoName&visibility=private&description=Obsidian+Brain"
Read-Host 'Enter druecken, sobald das Repo angelegt ist'

# --- 6. Hochladen ----------------------------------------------------------
Step 'Lade Vault hoch (beim ersten Mal fragt Git nach deinem GitHub-Login)'
if (git remote | Select-String -SimpleMatch 'origin' -Quiet) { git remote set-url origin $RemoteUrl } else { git remote add origin $RemoteUrl }
git push -u origin main
if ($LASTEXITCODE -ne 0) { throw 'Hochladen fehlgeschlagen. Ist das Repo angelegt und bist du eingeloggt?' }
Write-Host "Hochgeladen: https://github.com/$GitHubUser/$RepoName" -ForegroundColor Green

# --- 7. Claude Zugriff auf das Repo geben ----------------------------------
Step 'Claude Zugriff auf das Repo geben'
Write-Host "Der Browser oeffnet sich. Waehle dein Konto, dann bei 'Repository access' das Repo '$RepoName' hinzufuegen und speichern."
Start-Process 'https://github.com/apps/claude/installations/select_target'
Read-Host 'Enter druecken, wenn erledigt'

# --- 8. Optional: automatisch synchronisieren ------------------------------
Step 'Automatische Synchronisierung'
Write-Host 'Damit Aenderungen von dir (Obsidian) und von Claude (Cloud) immer abgeglichen werden,'
Write-Host 'kann ein Windows-Task alle 30 Minuten synchronisieren.'
if (Ask 'Automatische Synchronisierung einrichten?') {
    $syncScript = Join-Path $vault '.brain-sync.cmd'
    @(
        '@echo off',
        "cd /d `"$vault`"",
        'git add -A',
        'git diff --cached --quiet || git commit -m "Brain: Auto-Sync"',
        'git pull --rebase --autostash origin main || git rebase --abort',
        'git push origin main'
    ) | Set-Content -Path $syncScript -Encoding ASCII
    if ((Get-Content $gitignore) -notcontains '.brain-sync.cmd') { Add-Content -Path $gitignore -Value '.brain-sync.cmd' -Encoding UTF8 }

    $action   = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$syncScript`""
    $trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -Hidden
    Register-ScheduledTask -TaskName 'Brain Sync' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Write-Host "Task 'Brain Sync' eingerichtet (alle 30 Minuten)." -ForegroundColor Green
}

Step 'Fertig!'
Write-Host "Dein Brain liegt jetzt privat auf https://github.com/$GitHubUser/$RepoName" -ForegroundColor Green
Write-Host "Starte in der Claude-App eine neue Cloud-Sitzung mit dem Repo '$RepoName' und schreib: 'Verbessere mein Brain'."
