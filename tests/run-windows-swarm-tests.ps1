<#
.SYNOPSIS
    Live test of windows/swarm-core-audit.ps1 against a real Windows Docker engine in Swarm mode.

.DESCRIPTION
    Needs Docker in Windows containers mode (MCR on Windows Server, or Docker Desktop switched to
    Windows containers), run as Administrator or a member of docker-users. If the engine isn't in
    a swarm, a single-node swarm is created for the test and left again afterwards; an existing
    swarm is not changed. The audit's output is checked against docker info, docker version and
    docker node ls. Run it with both powershell.exe (5.1) and pwsh (7.x).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\run-windows-swarm-tests.ps1
#>
$ErrorActionPreference = 'Stop'
$Tests = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script = Join-Path (Split-Path -Parent $Tests) 'windows/swarm-core-audit.ps1'
$Shell = (Get-Process -Id $PID).Path
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-swarm-tests-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Work | Out-Null
. (Join-Path $Tests 'lib.ps1')

# Native-command stderr must not become a terminating error under Windows PowerShell 5.1
function Get-DockerValue([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $value = & docker @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw "docker $($Arguments -join ' ') failed" }
    return ([string]($value -join "`n")).Trim()
}

Write-Output "Windows Swarm tests (PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition))"

$serverOs = Get-DockerValue @('version', '--format', '{{.Server.Os}}')
if ($serverOs -ne 'windows') {
    Write-Output "This test needs Docker in Windows containers mode; the engine reports OS '$serverOs'."
    exit 1
}

$createdSwarm = $false
$swarmState = Get-DockerValue @('info', '--format', '{{.Swarm.LocalNodeState}}')
if ($swarmState -eq 'inactive') {
    Write-Output 'Creating a single-node swarm for the test (it is left again at the end)'
    $null = Get-DockerValue @('swarm', 'init', '--advertise-addr', '127.0.0.1')
    $createdSwarm = $true
} elseif ((Get-DockerValue @('info', '--format', '{{.Swarm.ControlAvailable}}')) -ne 'true') {
    Write-Output 'This engine is in a swarm but is not a manager; run the test on a manager node.'
    exit 1
}

try {
    # What the engine reports directly, to compare the audit against
    $hostname = Get-DockerValue @('info', '--format', '{{.Name}}')
    $operatingSystem = Get-DockerValue @('info', '--format', '{{.OperatingSystem}}')
    $engine = Get-DockerValue @('version', '--format', '{{.Server.Version}}')
    $cpus = Get-DockerValue @('info', '--format', '{{.NCPU}}')
    $memBytes = [double](Get-DockerValue @('info', '--format', '{{.MemTotal}}'))
    $memGib = '{0}.{1:D2}' -f [math]::Floor([math]::Floor($memBytes / 1073741824 * 100) / 100), ([long][math]::Floor($memBytes / 1073741824 * 100) % 100)
    $nodeCount = @((Get-DockerValue @('node', 'ls', '--quiet')) -split '\s+' | Where-Object { $_ }).Count
    Write-Output "Engine: $hostname, $operatingSystem, MCR $engine, $cpus CPUs, $memGib GiB, $nodeCount node(s)"

    Write-Output '# table'
    $result = Invoke-Audit @()
    Assert-Equal 'exits 0' $result.Code 0
    Assert-Contains 'connects through the named pipe' $result.Err '] Connected to the Docker engine via npipe:'
    Assert-Contains 'connected node is this engine' $result.Err "] Connected node: $hostname, $operatingSystem, kernel "
    Assert-Contains 'node count' $result.Err "] Retrieved $nodeCount node"
    Assert-Contains 'table header' $result.Out '| Hostname '
    Assert-Contains 'Windows total row' $result.Out ('| Windows    | {0,5} |' -f $nodeCount)
    $row = @(($result.Out -split "`r?`n") | Where-Object { $_.StartsWith("| $hostname ") })
    Assert-Equal 'one table row for this node' $row.Count 1
    if ($row.Count -eq 1) {
        Assert-Contains 'row shows windows platform' $row[0] '| windows/'
        Assert-Contains 'row shows the operating system' $row[0] "| $($operatingSystem.Substring(0, [math]::Min(57, $operatingSystem.Length)))"
    }

    Write-Output '# -NodesCsv'
    $csvFile = Join-Path $Work 'nodes.csv'
    $result = Invoke-Audit @('-NodesCsv', '-OutFile', $csvFile)
    Assert-Equal '-NodesCsv exits 0' $result.Code 0
    $rows = @(Import-Csv -LiteralPath $csvFile)
    Assert-Equal 'one CSV row per node' $rows.Count $nodeCount
    $me = @($rows | Where-Object { $_.Hostname -eq $hostname })
    Assert-Equal 'CSV has this node' $me.Count 1
    if ($me.Count -eq 1) {
        Assert-Equal 'role is leader or manager' (@('leader', 'manager') -contains $me[0].Role) $true
        Assert-Equal 'OS is windows' $me[0].OS 'windows'
        Assert-Equal 'OperatingSystem matches docker info' $me[0].OperatingSystem $operatingSystem
        Assert-Equal 'EngineVersion matches docker version' $me[0].EngineVersion $engine
        Assert-Equal 'vCPUs match docker info' $me[0].vCPUs $cpus
        Assert-Equal 'RAM_GiB matches docker info' $me[0].RAM_GiB $memGib
        Assert-Equal 'timestamps are ISO 8601' ($me[0].Created -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$') $true
    }

    Write-Output '# -Json and -Csv'
    $jsonFile = Join-Path $Work 'audit.json'
    $result = Invoke-Audit @('-Json', '-OutFile', $jsonFile)
    Assert-Equal '-Json exits 0' $result.Code 0
    $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($jsonFile))
    Assert-Equal 'JSON has every node' @($parsed.nodes).Count $nodeCount
    Assert-Equal 'JSON windows group counts every node' ([int](@($parsed.groups) | Where-Object { $_.os -eq 'windows' }).nodes) $nodeCount
    $result = Invoke-Audit @('-Csv')
    Assert-Equal '-Csv exits 0' $result.Code 0
    Assert-Contains '-Csv windows group' $result.Out (",all,windows,$nodeCount,")
} finally {
    if ($createdSwarm) {
        Write-Output 'Leaving the test swarm'
        $ErrorActionPreference = 'Continue'
        & docker swarm leave --force 2>$null | Out-Null
    }
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}

Write-Summary
if ($script:Fail -gt 0) { exit 1 }
