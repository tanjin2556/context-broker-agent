<#
start_agent.ps1 -- run the resident agent natively on Windows (no WSL, no container),
alongside your Claude Code session for this project.

    .\start_agent.ps1            # start
    .\start_agent.ps1 stop       # stop
    .\start_agent.ps1 status     # check

Config comes from .\agent.env if present (KEY=value lines), else the environment.

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

# --- interpreter (claude-agent-sdk needs Python 3.10+) ---------------------- #
$py = if ($env:PYBIN) { $env:PYBIN } else { 'python' }
$ver = & $py -c "import sys;print('%d.%d'%sys.version_info[:2])"
if ([version]$ver -lt [version]'3.10') {
    throw "claude-agent-sdk needs Python 3.10+, but '$py' is $ver. Set PYBIN to a newer interpreter."
}

& $py -m pip install --quiet --disable-pip-version-check claude-agent-sdk aiohttp httpx

# --- launch in the background ----------------------------------------------- #
$p = Start-Process -FilePath $py -ArgumentList 'resident_agent.py' `
        -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err" `
        -WindowStyle Hidden -PassThru
$p.Id | Set-Content $PidFile
Start-Sleep -Seconds 1
"resident agent for '$($env:PROJECT_NAME)' started (pid $($p.Id)) on port $($env:PORT); logs: $LogFile"
"  registering with broker at $($env:BROKER_URL) as $($env:SELF_ENDPOINT)"
