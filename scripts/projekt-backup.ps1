# projekt-backup.ps1
# Sichert PAVUR und das Jarvis-Projekt in PRIVATE GitHub-Repos, damit es ein Backup gibt
# und Claude in Cloud-Sitzungen am Code arbeiten kann.
#
# Start (PowerShell):
#   irm https://raw.githubusercontent.com/prassenico-sudo/Jarvis-test-repo/claude/zen-archimedes-2rfbr7/scripts/projekt-backup.ps1 | iex

# 'Continue': git schreibt Fortschritt nach stderr, das darf in PowerShell 5.1 nicht abbrechen.
$ErrorActionPreference = 'Continue'
$GitHubUser = 'prassenico-sudo'

function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Ask($text, $default = 'j') {
    $answer = Read-Host "$text [$default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }
    return $answer.Trim().ToLower().StartsWith('j')
}

# Muster fuer Passwoerter / API-Schluessel
$SecretPattern = '(api[_-]?key|api[_-]?secret|secret[_-]?key|access[_-]?token|password|passwort)\s*[:=]\s*[^A-Za-z0-9]?[A-Za-z0-9_\-\.]{16,}|sk-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|xox[bp]-[A-Za-z0-9-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

$IgnoreRules = @(
    '# --- projekt-backup ---',
    '.env', '.env.*', '!.env.example', '*.pem', '*.key', '*.p12', '*.pfx',
    'secrets.*', 'credentials*.json', 'token*.json',
    'node_modules/', '.next/', 'dist/', 'build/',
    'venv/', '.venv/', 'env/', '__pycache__/', '*.pyc',
    '*.log', '*.wav', '*.mp3', '*.pt', '*.bin', '*.onnx', 'models/',
    'Thumbs.db', 'desktop.ini'
)

function Find-Folder($candidates, $label) {
    foreach ($c in $candidates) { if ($c -and (Test-Path (Join-Path $c '*'))) { return $c } }
    $p = Read-Host "$label nicht gefunden. Bitte den Ordner-Pfad eingeben (leer = ueberspringen)"
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    if (-not (Test-Path $p)) { Write-Host "Pfad nicht gefunden: $p" -ForegroundColor Yellow; return $null }
    return $p
}

function New-GitHubRepo($name) {
    Write-Host "Der Browser oeffnet sich. Pruefe, dass 'Private' ausgewaehlt und README AUS ist, dann 'Create repository'."
    Write-Host 'Falls das Repo schon existiert, schliess den Tab einfach.'
    Start-Process "https://github.com/new?name=$name&visibility=private"
    Read-Host 'Enter druecken, sobald das Repo angelegt ist' | Out-Null
}

function Set-GitHubRemote($url) {
    # Ein vorhandenes 'origin' wird NICHT ueberschrieben, wir nutzen dann 'github'.
    $remotes = @(git remote)
    if ($remotes -contains 'origin') {
        $originUrl = git remote get-url origin
        if ($originUrl -eq $url) { return 'origin' }
        if ($remotes -contains 'github') { git remote set-url github $url } else { git remote add github $url }
        return 'github'
    }
    git remote add origin $url
    return 'origin'
}

function Backup-Project($path, $repoName, $label) {
    Step "$label sichern ($path -> $GitHubUser/$repoName)"
    Set-Location $path
    $url = "https://github.com/$GitHubUser/$repoName.git"

    if (Test-Path (Join-Path $path '.git')) {
        # Bestehendes Repo: nichts am Arbeitsstand aendern, nur alle Branches hochladen.
        Write-Host 'Bestehendes Git-Repo gefunden. Branches:'
        git branch -vv
        $branches = @(git for-each-ref --format='%(refname:short)' refs/heads)

        # Geheimnisse in bereits committeten Dateien suchen (alle Branches)
        $trackedEnv = @(git ls-files | Where-Object { $_ -match '(^|/)\.env(\.|$)' -and $_ -notmatch '\.example$|\.sample$|\.template$' })
        $hits = @()
        foreach ($b in $branches) {
            $hits += @(git grep -l -I -i -E $SecretPattern $b -- . ':!*.lock' ':!*lock.json')
        }
        if ($trackedEnv.Count -gt 0 -or $hits.Count -gt 0) {
            Write-Host ''
            Write-Host 'ACHTUNG: Im Git-Verlauf liegen Dateien, die nach Passwoertern/API-Schluesseln aussehen:' -ForegroundColor Yellow
            ($trackedEnv + $hits) | Sort-Object -Unique | Select-Object -First 30 | ForEach-Object { Write-Host "  - $_" }
            Write-Host 'Das Repo wird PRIVAT sein. Trotzdem: Schluessel, die hier auftauchen, spaeter erneuern.' -ForegroundColor Yellow
            if (-not (Ask 'Trotzdem sichern?' 'n')) { Write-Host "$label uebersprungen." -ForegroundColor Yellow; return $false }
        } else {
            Write-Host 'Keine offensichtlichen Geheimnisse im Verlauf gefunden.'
        }
    } else {
        # Kein Git-Repo: neu anlegen, Geheimnisse und grosse Dateien ausschliessen.
        Write-Host 'Noch kein Git-Repo. Lege eines an.'
        $gitignore = Join-Path $path '.gitignore'
        $existing = if (Test-Path $gitignore) { Get-Content $gitignore } else { @() }
        $missing = $IgnoreRules | Where-Object { $existing -notcontains $_ }
        if ($missing) { Add-Content -Path $gitignore -Value $missing -Encoding UTF8 }

        git init -b main | Out-Null
        if (-not (git config user.name))  { git config user.name  $GitHubUser }
        if (-not (git config user.email)) { git config user.email "$GitHubUser@users.noreply.github.com" }

        # Dateien > 50 MB ausschliessen (GitHub lehnt > 100 MB ab)
        git add -A
        $big = @(git ls-files -s | ForEach-Object { ($_ -split "`t", 2)[1] } | Where-Object { (Test-Path $_) -and (Get-Item $_).Length -gt 50MB })
        foreach ($f in $big) { Write-Host "Zu gross, wird ausgeschlossen: $f" -ForegroundColor Yellow; Add-Content $gitignore $f; git rm --cached -q -- $f }

        # Geheimnisse in den vorgemerkten Dateien suchen
        $hits = @(git grep --cached -l -I -i -E $SecretPattern)
        if ($hits.Count -gt 0) {
            Write-Host ''
            Write-Host 'ACHTUNG: Diese Dateien sehen aus, als enthielten sie Passwoerter oder API-Schluessel:' -ForegroundColor Yellow
            $hits | ForEach-Object { Write-Host "  - $_" }
            if (Ask 'Diese Dateien NICHT hochladen? (empfohlen)') {
                foreach ($f in $hits) { Add-Content $gitignore $f; git rm --cached -q -- $f }
                Write-Host 'Ausgeschlossen.' -ForegroundColor Green
            }
        }
        git add .gitignore
        git commit -q -m "$label`: erstes Backup"
    }

    New-GitHubRepo $repoName
    $remote = Set-GitHubRemote $url
    git push $remote --all
    if ($LASTEXITCODE -ne 0) { Write-Host "Hochladen von $label fehlgeschlagen." -ForegroundColor Red; return $false }
    git push $remote --tags
    Write-Host "$label gesichert: https://github.com/$GitHubUser/$repoName" -ForegroundColor Green
    return $true
}

# --- Git pruefen ----------------------------------------------------------
Step 'Pruefe Git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git fehlt. Bitte zuerst brain-sync.ps1 ausfuehren oder Git installieren.' }
Write-Host (git --version)

$results = @{}

# --- PAVUR ----------------------------------------------------------------
$pavur = Find-Folder @("$HOME\pavur", 'C:\Users\User\pavur', "$HOME\Desktop\pavur") 'PAVUR'
if ($pavur) { $results['PAVUR'] = Backup-Project $pavur 'pavur' 'PAVUR' }

# --- Jarvis ---------------------------------------------------------------
$jarvis = Find-Folder @("$HOME\Jarvis-projekt", "$HOME\Desktop\Jarvis-projekt", "$HOME\Documents\Jarvis-projekt",
                       "$HOME\OneDrive\Dokumente\Jarvis-projekt", "$HOME\OneDrive\Desktop\Jarvis-projekt") 'Jarvis-projekt'
if ($jarvis) { $results['Jarvis'] = Backup-Project $jarvis 'jarvis' 'Jarvis' }

# --- Ergebnis -------------------------------------------------------------
Step 'Ergebnis'
foreach ($k in $results.Keys) {
    if ($results[$k]) { Write-Host "  $k : gesichert" -ForegroundColor Green } else { Write-Host "  $k : NICHT gesichert" -ForegroundColor Yellow }
}
Write-Host ''
Write-Host 'Schick Claude einen Screenshot von diesem Fenster.'
