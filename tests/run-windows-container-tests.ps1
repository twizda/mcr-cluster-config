<#
.SYNOPSIS
    Live test of the Windows container image against a real Windows Docker engine in Swarm mode.

.DESCRIPTION
    Runs the image with the engine's named pipe mounted, and requires its output to be identical
    to running windows/swarm-core-audit.ps1 directly on the same host, for every output format.
    Needs Docker in Windows containers mode with process isolation (Windows Server), run as
    Administrator. If the engine isn't in a swarm, a single-node swarm is created for the test and
    left again afterwards; an existing swarm is not changed.

.PARAMETER Image
    The image to test, for example twizda/mcr-cluster-config:0.7.0 or a locally loaded tag.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\run-windows-container-tests.ps1 -Image twizda/mcr-cluster-config:latest
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Image
)
$ErrorActionPreference = 'Stop'
$Tests = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AuditScript = Join-Path (Split-Path -Parent $Tests) 'windows/swarm-core-audit.ps1'
$script:Shell = (Get-Process -Id $PID).Path
. (Join-Path $Tests 'lib.ps1')

# Native-command stderr must not become a terminating error under Windows PowerShell 5.1
function Get-DockerValue([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $value = & docker @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw "docker $($Arguments -join ' ') failed" }
    return ([string]($value -join "`n")).Trim()
}

# Runs the image with the named pipe mounted; returns exit code, stdout and stderr
function Invoke-Container([string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command docker -CommandType Application | Select-Object -First 1).Source
    $all = @('run', '--rm', '-v', '\\.\pipe\docker_engine:\\.\pipe\docker_engine', $Image) + $Arguments
    $psi.Arguments = $all -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{ Code = $process.ExitCode; Out = ($stdout.Result -replace "`r", ''); Err = ($stderr.Result -replace "`r", '') }
}
# Log lines without the elapsed-seconds field, which differs between runs
function ConvertTo-ComparableLog([string]$Text) {
    return (($Text -split "`n" | Where-Object { $_ }) -replace '^(INFO|WARN|FATA)\[\d+\]', '$1') -join "`n"
}

Write-Output "Windows container tests for $Image (PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition))"

$serverOs = Get-DockerValue @('version', '--format', '{{.Server.Os}}')
if ($serverOs -ne 'windows') {
    Write-Output "This test needs Docker in Windows containers mode; the engine reports OS '$serverOs'."
    exit 1
}
$hostBuild = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
Write-Output "Host: Windows build $hostBuild, engine $(Get-DockerValue @('version', '--format', '{{.Server.Version}}'))"

$createdSwarm = $false
if ((Get-DockerValue @('info', '--format', '{{.Swarm.LocalNodeState}}')) -eq 'inactive') {
    Write-Output 'Creating a single-node swarm for the test (it is left again at the end)'
    $null = Get-DockerValue @('swarm', 'init', '--advertise-addr', '127.0.0.1')
    $createdSwarm = $true
} elseif ((Get-DockerValue @('info', '--format', '{{.Swarm.ControlAvailable}}')) -ne 'true') {
    Write-Output 'This engine is in a swarm but is not a manager; run the test on a manager node.'
    exit 1
}

try {
    Write-Output '# image'
    $imageOsVersion = Get-DockerValue @('image', 'inspect', '--format', '{{.OsVersion}}', $Image)
    Assert-Equal 'image matches the host Windows build' ($imageOsVersion.Split('.')[2]) ([string]$hostBuild)
    $scriptVersion = ((Select-String -LiteralPath $script:AuditScript -Pattern "^\`$ScriptVersion = '(.*)'").Matches[0].Groups[1].Value)
    Assert-Equal 'image version label matches the script' (Get-DockerValue @('image', 'inspect', '--format', '{{index .Config.Labels "version"}}', $Image)) $scriptVersion

    Write-Output '# output is identical to running the script directly'
    foreach ($options in @(@(), @('--csv'), @('--nodes-csv'), @('--json'))) {
        $label = if ($options.Count) { $options -join ' ' } else { '(table)' }
        $container = Invoke-Container $options
        $direct = Invoke-Audit $options
        Assert-Equal "$label exits 0" $container.Code 0
        if ($label -eq '--json') {
            # Compared by content: PowerShell 5.1 and 7 escape some characters differently in JSON
            $normalize = { param($text) ConvertTo-Json -InputObject (ConvertFrom-Json -InputObject $text) -Depth 10 -Compress }
            Assert-Equal "$label identical (by content)" (& $normalize $container.Out) (& $normalize $direct.Out)
        } else {
            Assert-Equal "$label identical" $container.Out ($direct.Out -replace "`r", '')
        }
        Assert-Equal "$label log lines identical" (ConvertTo-ComparableLog $container.Err) (ConvertTo-ComparableLog ($direct.Err -replace "`r", ''))
    }
    $result = Invoke-Container @()
    Assert-Substring 'first log line is the version' (($result.Err -split "`n")[0]) "] mcr-cluster-config version $scriptVersion"
    Assert-Substring 'connects through the mounted pipe' $result.Err '] Connected to the Docker engine via npipe:'

    Write-Output '# options and errors'
    $result = Invoke-Container @('--help')
    Assert-Equal '--help exits 0' $result.Code 0
    Assert-Substring '--help prints usage' $result.Out 'Usage: swarm-core-audit.ps1'
    $result = Invoke-Container @('--xml')
    Assert-Equal 'unknown option: exits 1' $result.Code 1
    Assert-Substring 'unknown option: FATA message' $result.Err '] Unknown option: --xml.'
} finally {
    if ($createdSwarm) {
        Write-Output 'Leaving the test swarm'
        $ErrorActionPreference = 'Continue'
        & docker swarm leave --force 2>$null | Out-Null
    }
}

Write-Summary
if ($script:Fail -gt 0) { exit 1 }
