<#
start_agent.ps1 -- run the resident agent natively on Windows (no WSL, no container),
alongside your Claude Code session for this project.

    .\start_agent.ps1            # start
    .\start_agent.ps1 stop       # stop
    .\start_agent.ps1 status     # check

Config comes from .\agent.env if present (KEY=value lines), else the environment.
Set AGENT_PYTHON there if this cannot find a Python 3.10+ by itself.

WINDOWS-SPECIFIC NOTES
  * Each project needs its OWN port (they all share one host now): 9100, 9101, ...
  * If the broker runs in a Docker Desktop container, the broker reaches this
    agent via host.docker.internal, so set:
        SELF_ENDPOINT=http://host.docker.internal:<PORT>
  * And this agent reaches the broker on the published port:
        BROKER_URL=http://localhost:8000
  * Allow the port through Windows Firewall the first time you're prompted.
#>
[CmdletBinding()]
param([ValidateSet('start','stop','status')][string]$Action = 'start')

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$StateDir = Join-Path $PSScriptRoot '.agent'
$PidFile  = Join-Path $StateDir 'agent.pid'
$LogFile  = Join-Path $StateDir 'agent.log'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Get-AgentProcess {
    if (-not (Test-Path $PidFile)) { return $null }
    $procId = Get-Content $PidFile | Select-Object -First 1
    return Get-Process -Id $procId -ErrorAction SilentlyContinue
}

switch ($Action) {
    'stop' {
        $p = Get-AgentProcess
        if ($p) { Stop-Process -Id $p.Id -Force; Remove-Item $PidFile -Force; 'stopped' }
        else    { 'not running' }
        return
    }
    'status' {
        $p = Get-AgentProcess
        if ($p) { "running (pid $($p.Id)); logs: $LogFile" } else { 'not running' }
        return
    }
}

# --- load agent.env (KEY=value, # comments) --------------------------------- #
$envFile = Join-Path $PSScriptRoot 'agent.env'
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $val = $matches[2].Trim().Trim('"')
            [Environment]::SetEnvironmentVariable($matches[1], $val, 'Process')
        }
    }
}

# --- required config -------------------------------------------------------- #
if (-not $env:PROJECT_NAME) { throw 'set PROJECT_NAME (e.g. in agent.env)' }
if (-not $env:PROJECT_REPO) { $env:PROJECT_REPO = (Get-Location).Path }
if (-not $env:BROKER_URL)   { $env:BROKER_URL   = 'http://localhost:8000' }
if (-not $env:PORT)         { $env:PORT         = '9100' }
if (-not $env:SELF_ENDPOINT) {
    # Default assumes the broker runs in Docker Desktop and reaches back to the host.
    $env:SELF_ENDPOINT = "http://host.docker.internal:$($env:PORT)"
}
if (-not $env:CLAUDE_CODE_OAUTH_TOKEN) { throw 'set CLAUDE_CODE_OAUTH_TOKEN (run: claude setup-token)' }

# An API key would shadow the subscription token.
if ($env:ANTHROPIC_API_KEY -or $env:ANTHROPIC_AUTH_TOKEN) {
    throw 'ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN is set; remove it so the subscription token is used.'
}

if (Get-AgentProcess) { "already running; .\start_agent.ps1 stop first."; return }

# --- interpreter (claude-agent-sdk needs Python 3.10+ with pip) ------------- #
# Being on PATH is not proof of being a Python. Windows ships App Execution
# Aliases at WindowsApps\python.exe and python3.exe that open the Microsoft
# Store and exit without running anything, so a bare `& python -c ...` returns
# an empty string and the version check then fails naming no cause. Probe
# candidates and take the first that actually answers -- the same approach as
# pick_python() in start_agent.sh, which reads AGENT_PYTHON for the override.
function Test-Python([string[]]$cmd) {
    $ErrorActionPreference = 'Continue'   # a candidate that fails is data, not an error
    $exe  = $cmd[0]
    $rest = @(); if ($cmd.Length -gt 1) { $rest = $cmd[1..($cmd.Length - 1)] }
    try { $out = & $exe @rest -c "import sys;print('%d.%d' % sys.version_info[:2])" 2>$null }
    catch { return $null }
    if ($LASTEXITCODE -ne 0) { return $null }
    $line = $out | Select-Object -First 1
    if (-not $line) { return $null }      # the Store alias lands here: no output
    $v = $null
    if (-not [version]::TryParse($line.Trim(), [ref]$v)) { return $null }
    if ($v -lt [version]'3.10') { return $null }
    # -m pip is how the SDK gets installed below; an interpreter without it
    # would pass the version test and fail two lines later.
    & $exe @rest -m pip --version 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $v
}

$candidates = New-Object System.Collections.ArrayList
# An explicit override wins. AGENT_PYTHON is the name start_agent.sh uses;
# PYBIN is honoured too, since this script asked for it before they agreed.
foreach ($o in @($env:AGENT_PYTHON, $env:PYBIN)) { if ($o) { [void]$candidates.Add(@($o)) } }
# py.exe is the launcher python.org installs. It is never the Store alias, and
# an explicit -3.x asks it for a version rather than whatever the default is.
foreach ($v in '3.13', '3.12', '3.11', '3.10') { [void]$candidates.Add(@('py', "-$v")) }
[void]$candidates.Add(@('python'))
[void]$candidates.Add(@('python3'))
# Last resort: the usual install roots, newest first. Reached when PATH holds
# only the Store alias -- the exact case this whole block exists for.
foreach ($root in @("$env:LOCALAPPDATA\Programs\Python", $env:ProgramFiles, 'C:\')) {
    if (-not $root -or -not (Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Filter 'Python3*' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | ForEach-Object {
            $exe = Join-Path $_.FullName 'python.exe'
            if (Test-Path $exe) { [void]$candidates.Add(@($exe)) }
        }
}

$py = $null; $pyArgs = @(); $tried = @()
foreach ($c in $candidates) {
    $label = $c -join ' '
    if ($tried -contains $label) { continue }
    $tried += $label
    $found = Test-Python $c
    if ($found) {
        $py = $c[0]
        if ($c.Length -gt 1) { $pyArgs = $c[1..($c.Length - 1)] }
        "using Python $found ($label)"
        break
    }
}
if (-not $py) {
    throw @"
No usable Python found -- claude-agent-sdk needs 3.10+ with pip.
Tried: $($tried -join ', ')

If python.exe on your PATH opens the Microsoft Store, that is an App Execution
Alias, not an interpreter: turn it off under Settings > Apps > Advanced app
settings > App execution aliases, or install python.org's build.
To point at one directly, set AGENT_PYTHON in agent.env, e.g.
  AGENT_PYTHON=C:\Users\you\AppData\Local\Programs\Python\Python313\python.exe
"@
}

& $py @pyArgs -m pip install --quiet --disable-pip-version-check claude-agent-sdk aiohttp httpx

# --- launch in the background ----------------------------------------------- #
$p = Start-Process -FilePath $py -ArgumentList ($pyArgs + 'resident_agent.py') `
        -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err" `
        -WindowStyle Hidden -PassThru
$p.Id | Set-Content $PidFile
Start-Sleep -Seconds 1
"resident agent for '$($env:PROJECT_NAME)' started (pid $($p.Id)) on port $($env:PORT); logs: $LogFile"
"  registering with broker at $($env:BROKER_URL) as $($env:SELF_ENDPOINT)"
