<#
.SYNOPSIS
    Audits a Docker Swarm cluster on Windows Server (MCR, with or without MKE) and reports
    node counts, CPU cores, RAM and per-node details.

.DESCRIPTION
    Windows counterpart of swarm-core-audit.sh, with the same tables, CSV and JSON output.
    It reads the cluster through the docker CLI that MCR installs (docker info, docker version,
    docker node inspect, docker service inspect), so run it on a Swarm manager. It sends
    read-only requests only.

    Without MKE, docker info only describes the node it runs on, so the Operating System column
    is filled in for that node only. Through MKE (with a client bundle loaded via env.ps1), every
    node's operating system is reported.

    Requires Windows PowerShell 5.1 or later (included in Windows Server 2016 and later) and
    the docker CLI. Run PowerShell as Administrator, or as a member of the docker-users group.

.PARAMETER Csv
    Output the summary by node group as CSV.

.PARAMETER NodesCsv
    Output per-node details as CSV, one row per node.

.PARAMETER Json
    Output the summary and per-node details as JSON.

.PARAMETER OutFile
    Write the output to this file as UTF-8 (recommended for -Csv, -NodesCsv and -Json, because
    redirecting with > in Windows PowerShell 5.1 writes UTF-16).

.PARAMETER InputDirectory
    Read info.json, version.json, nodes.json and services.json from this directory instead of
    the docker engine. Used by the tests, and to audit data captured on another machine.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\swarm-core-audit.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\swarm-core-audit.ps1 -NodesCsv -OutFile nodes.csv
#>
[CmdletBinding()]
param(
    [switch]$Csv,
    [switch]$NodesCsv,
    [switch]$Json,
    [string]$OutFile,
    [string]$InputDirectory
)

# Release version, updated by scripts/prepare-release.sh (matches ENV MCR_CLUSTER_CONFIG_VERSION in the Dockerfile)
$ScriptVersion = '0.5.4'

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# --- Logging ---
# Same logrus-style format as the Linux scripts, e.g. "INFO[0000] message", written to stderr.
# Levels are colored only on a terminal that supports it, and when NO_COLOR is unset.
$UseColor = (-not [Console]::IsErrorRedirected) -and (-not $env:NO_COLOR) -and $Host.UI.SupportsVirtualTerminal
$Esc = [char]27
$LevelColors = @{ INFO = "$Esc[36m"; WARN = "$Esc[33m"; FATA = "$Esc[31m" }

function Write-AuditLog([string]$Level, [string]$Message) {
    $elapsed = [int][math]::Floor($Stopwatch.Elapsed.TotalSeconds)
    $name = $Level
    if ($UseColor) { $name = "$($LevelColors[$Level])$Level$Esc[0m" }
    [Console]::Error.WriteLine(("{0}[{1:D4}] {2}" -f $name, $elapsed, $Message))
}
function Write-Info([string]$Message) { Write-AuditLog 'INFO' $Message }
function Write-Warn([string]$Message) { Write-AuditLog 'WARN' $Message }
function Exit-Fatal([string]$Message) { Write-AuditLog 'FATA' $Message; exit 1 }

# Prints a count with a singular or plural noun, e.g. "1 node", "2 nodes"
function Format-Plural([long]$Count, [string]$Noun) {
    if ($Count -eq 1) { return "$Count $Noun" }
    return "$Count ${Noun}s"
}

# --- Formatting helpers (match the jq and bc arithmetic in the Linux scripts) ---
# Per-node GiB: floor to 2 decimals, as jq's two()
function Format-NodeGiB($Bytes) {
    $c = [long][math]::Floor(([double]$Bytes / 1073741824) * 100)
    return ('{0}.{1:D2}' -f [long][math]::Floor($c / 100), ($c % 100))
}
# Group total GiB: truncated to 2 decimals with exact arithmetic, as "scale=2" in bc
function Format-TotalGiB($Bytes) {
    $hundredths = [math]::Truncate(([decimal]$Bytes * 100) / 1073741824)
    return ($hundredths / 100).ToString('F2', $Invariant)
}
function Get-CoreCount($Node) {
    $nano = $Node.Description.Resources.NanoCPUs
    if (-not $nano) { return [long]0 }
    return [long][math]::Floor([double]$nano / 1000000000)
}
# PowerShell 7's ConvertFrom-Json turns ISO timestamps into DateTime values (5.1 keeps strings);
# format both the same way as the Linux scripts: "yyyy-MM-ddTHH:mm:ss" in UTC
function Format-Timestamp($Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss', $Invariant) }
    $text = [string]$Value
    return $text.Substring(0, [math]::Min(19, $text.Length))
}
function ConvertTo-CsvField($Value) {
    return '"' + ([string]$Value).Replace('"', '""') + '"'
}

# --- Docker access ---
function Invoke-Docker([string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:DockerPath
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result.Trim(); Err = $stderr.Result.Trim() }
}

# Windows PowerShell 5.1's ConvertFrom-Json returns a JSON array as a single object instead of
# enumerating it (7.x enumerates); assigning the result to a variable first, then using @($var),
# gives a flat array on both.

# Inspects objects in batches of 100: keeps command lines short, and each JSON document well under
# the ~2 MB limit of ConvertFrom-Json in Windows PowerShell 5.1
function Get-DockerObject([string]$Kind, [string[]]$Ids) {
    $objects = @()
    for ($i = 0; $i -lt $Ids.Count; $i += 100) {
        $batch = $Ids[$i..([math]::Min($i + 99, $Ids.Count - 1))]
        $result = Invoke-Docker (@($Kind, 'inspect') + $batch)
        if ($result.ExitCode -ne 0) { return $null }
        $parsed = ConvertFrom-Json -InputObject $result.Out
        $objects += @($parsed)
    }
    return , $objects
}

function Read-InputFile([string]$Name, $Default) {
    $path = Join-Path $InputDirectory $Name
    if (-not (Test-Path -LiteralPath $path)) { return $Default }
    $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))
    return $parsed
}

# --- Options ---
if (@($Csv, $NodesCsv, $Json | Where-Object { $_ }).Count -gt 1) {
    Exit-Fatal 'Use only one of -Csv, -NodesCsv and -Json.'
}

Write-Info "mcr-cluster-config version $ScriptVersion"

# --- Collect cluster data ---
if ($InputDirectory) {
    if (-not (Test-Path -LiteralPath (Join-Path $InputDirectory 'nodes.json'))) {
        Exit-Fatal "Unable to find nodes.json in $InputDirectory."
    }
    $Info = Read-InputFile 'info.json' ([pscustomobject]@{})
    $ServerVersion = [string](Read-InputFile 'version.json' ([pscustomobject]@{})).Version
    $Nodes = @(Read-InputFile 'nodes.json' @())
    $Services = @(Read-InputFile 'services.json' @())
    Write-Info "Reading audit data from $InputDirectory"
} else {
    $command = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { Exit-Fatal 'The docker CLI was not found. Run this on a node with MCR installed, or add docker to PATH.' }
    $script:DockerPath = $command.Source

    $result = Invoke-Docker @('version', '--format', '{{json .Server}}')
    if ($result.ExitCode -ne 0 -or -not $result.Out -or $result.Out -eq 'null') {
        $hint = ''
        if ($result.Err -match 'Access is denied|permission denied') {
            $hint = ' Run PowerShell as Administrator, or as a member of the docker-users group.'
        }
        Exit-Fatal "Unable to connect to the Docker engine: $($result.Err)$hint"
    }
    $ServerVersion = [string](ConvertFrom-Json -InputObject $result.Out).Version
    $endpoint = if ($env:DOCKER_HOST) { $env:DOCKER_HOST } else { 'npipe:////./pipe/docker_engine' }
    if ($ServerVersion.StartsWith('ucp/')) { Write-Info "Connected to MKE at $endpoint" }
    else { Write-Info "Connected to the Docker engine via $endpoint" }

    $result = Invoke-Docker @('node', 'ls', '--quiet')
    if ($result.ExitCode -ne 0) { Exit-Fatal "Unable to list nodes: $($result.Err)" }
    $ids = @($result.Out -split '\s+' | Where-Object { $_ })
    $Nodes = Get-DockerObject 'node' $ids
    if ($null -eq $Nodes) { Exit-Fatal 'Unable to inspect nodes.' }

    $result = Invoke-Docker @('info', '--format', '{{json .}}')
    $Info = [pscustomobject]@{}
    if ($result.ExitCode -eq 0 -and $result.Out) { $Info = ConvertFrom-Json -InputObject $result.Out }

    $Services = @()
    $result = Invoke-Docker @('service', 'ls', '--quiet')
    $serviceIds = @($result.Out -split '\s+' | Where-Object { $_ })
    if ($result.ExitCode -eq 0 -and $serviceIds.Count -gt 0) {
        $inspected = Get-DockerObject 'service' $serviceIds
        if ($null -ne $inspected) { $Services = $inspected }
    }
}

# --- Cluster details ---
$ClusterId = [string]$Info.Swarm.Cluster.ID
if (-not $ClusterId) { $ClusterId = 'unknown' }
Write-Info "Cluster ID: $ClusterId"

$InfoServerVersion = [string]$Info.ServerVersion
if (-not $InfoServerVersion.StartsWith('ucp/')) {
    $fields = foreach ($pair in @(@($Info.Name, 'unknown'), @($Info.OperatingSystem, 'unknown OS'), @($Info.KernelVersion, 'unknown'), @($Info.ServerVersion, 'unknown'))) {
        if ($pair[0]) { [string]$pair[0] } else { $pair[1] }
    }
    Write-Info ('Connected node: {0}, {1}, kernel {2}, engine {3}' -f $fields)
}

# Operating system per node: MKE lists every node in SystemStatus; a plain engine only describes itself.
# Case-sensitive keys, like jq.
$OsMap = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
$current = $null
foreach ($entry in @($Info.SystemStatus)) {
    if (-not ($entry -is [array]) -or $entry.Count -lt 2) { continue }
    $key = [string]$entry[0]
    if ($key -match '^ [^ ]') {
        $current = $key.Substring(1)
    } elseif ($current -and $key -match 'Labels$') {
        foreach ($label in ([string]$entry[1] -split ', ')) {
            if ($label.StartsWith('operatingsystem=')) {
                if (-not $OsMap.ContainsKey($current)) { $OsMap[$current] = $label.Substring(16) }
                break
            }
        }
    }
}
if ($Info.Name -and $Info.OperatingSystem) { $OsMap[[string]$Info.Name] = [string]$Info.OperatingSystem }

$MkeVersion = ''
if ($ServerVersion.StartsWith('ucp/')) { $MkeVersion = $ServerVersion.Substring(4) }
$MsrVersion = ''
foreach ($service in $Services) {
    $image = [string]$service.Spec.TaskTemplate.ContainerSpec.Image
    if ($image -match '(mirantis|docker)/dtr') {
        $tagged = ($image -split '@')[0] -split ':'
        if ($tagged.Count -gt 1 -and $tagged[1]) { $MsrVersion = $tagged[1]; break }
    }
}
if ($MkeVersion) { Write-Info "MKE version: $MkeVersion" }
if ($MsrVersion) { Write-Info "MSR version: $MsrVersion" }

$managerTotal = @($Nodes | Where-Object { $_.Spec.Role -eq 'manager' }).Count
$noResources = @($Nodes | Where-Object { -not $_.Description.Resources.NanoCPUs }).Count
Write-Info ('Retrieved {0} (managers: {1}, workers: {2})' -f (Format-Plural $Nodes.Count 'node'), $managerTotal, ($Nodes.Count - $managerTotal))
if ($noResources -gt 0) { Write-Warn "$(Format-Plural $noResources 'node') reported no CPU data (excluded from the totals)" }

$found = @($Nodes | Where-Object { $_.Description.Hostname -and $OsMap.ContainsKey([string]$_.Description.Hostname) }).Count
if ($found -lt $Nodes.Count) {
    if ($MkeVersion) { $reason = "MKE's docker info did not list the other nodes." }
    else { $reason = 'docker info on this engine only describes this node; run the audit on each node, or through MKE with a client bundle, to get every node''s operating system.' }
    Write-Warn "Operating system found for $found of $(Format-Plural $Nodes.Count 'node'). $reason"
}

# Flag nodes that are not ready or not active, as "docker node ls" would show them
foreach ($node in $Nodes) {
    $state = [string]$node.Status.State
    $availability = [string]$node.Spec.Availability
    if (($state -and $state -ne 'ready') -or ($availability -and $availability -ne 'active')) {
        $name = if ($node.Description.Hostname) { $node.Description.Hostname } else { $node.ID }
        $message = ''
        if ($node.Status.Message) { $message = " ($($node.Status.Message))" }
        Write-Warn "Node ${name}: state $state, availability $availability$message"
    }
}

# --- Per-node details (same fields and order as NODE_JQ in the Linux scripts) ---
$NodeRows = New-Object System.Collections.Generic.List[object]
foreach ($node in $Nodes) {
    $labels = $node.Spec.Labels
    $orchestrators = @()
    if ($labels -and $labels.'com.docker.ucp.orchestrator.swarm' -eq 'true') { $orchestrators += 'swarm' }
    if ($labels -and $labels.'com.docker.ucp.orchestrator.kubernetes' -eq 'true') { $orchestrators += 'kube' }
    $hostname = [string]$node.Description.Hostname
    $role = [string]$node.Spec.Role
    if ($node.ManagerStatus -and $node.ManagerStatus.Leader -eq $true) { $role = 'leader' }
    $operatingSystem = ''
    if ($hostname -and $OsMap.ContainsKey($hostname)) { $operatingSystem = $OsMap[$hostname] }
    $collection = ''
    if ($labels) { $collection = [string]$labels.'com.docker.ucp.access.label' }
    $NodeRows.Add([pscustomobject][ordered]@{
        hostname         = $hostname
        id               = [string]$node.ID
        role             = $role
        availability     = [string]$node.Spec.Availability
        state            = [string]$node.Status.State
        addr             = [string]$node.Status.Addr
        os               = [string]$node.Description.Platform.OS
        arch             = [string]$node.Description.Platform.Architecture
        operating_system = $operatingSystem
        engine           = [string]$node.Description.Engine.EngineVersion
        cpus             = Get-CoreCount $node
        mem_gib          = Format-NodeGiB $node.Description.Resources.MemoryBytes
        orchestrators    = $orchestrators
        collection       = $collection
        created          = Format-Timestamp $node.CreatedAt
        updated          = Format-Timestamp $node.UpdatedAt
        status_message   = [string]$node.Status.Message
    })
}
# Leader, then managers, then workers; hostnames in ordinal (case-sensitive) order, like jq
$RoleOrder = @{ leader = 0; manager = 1 }
$NodeRows.Sort([System.Comparison[object]]{
    param($a, $b)
    $ra = if ($RoleOrder.ContainsKey($a.role)) { $RoleOrder[$a.role] } else { 2 }
    $rb = if ($RoleOrder.ContainsKey($b.role)) { $RoleOrder[$b.role] } else { 2 }
    if ($ra -ne $rb) { return $ra.CompareTo($rb) }
    return [string]::CompareOrdinal($a.hostname, $b.hostname)
})

# Totals for a role/OS group; only nodes that report CPU data are counted (as in the Linux scripts)
function Get-GroupStatistic([string]$Role, [string]$Os) {
    $members = @($Nodes | Where-Object {
        ($Role -eq 'all' -or $_.Spec.Role -eq $Role) -and
        (-not $Os -or $_.Description.Platform.OS -eq $Os) -and
        $_.Description.Resources.NanoCPUs
    })
    $cores = [long]0
    $bytes = [decimal]0
    foreach ($member in $members) {
        $cores += Get-CoreCount $member
        if ($member.Description.Resources.MemoryBytes) { $bytes += [decimal]$member.Description.Resources.MemoryBytes }
    }
    return [pscustomobject]@{ Nodes = $members.Count; Cores = $cores; Gib = Format-TotalGiB $bytes }
}

# Bordered table from rows of cells (first row is the header); long cells are truncated
function Format-BorderedTable([object[]]$Rows, [int[]]$RightAligned) {
    $cells = @(foreach ($row in $Rows) {
        , @($row | ForEach-Object { $v = [string]$_; if ($v.Length -gt 60) { $v.Substring(0, 57) + '...' } else { $v } })
    })
    $widths = @()
    for ($i = 0; $i -lt $cells[0].Count; $i++) {
        $widths += ($cells | ForEach-Object { $_[$i].Length } | Measure-Object -Maximum).Maximum
    }
    $border = '+' + (($widths | ForEach-Object { '-' * ($_ + 2) }) -join '+') + '+'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($border)
    for ($r = 0; $r -lt $cells.Count; $r++) {
        $parts = for ($i = 0; $i -lt $widths.Count; $i++) {
            if ($RightAligned -contains ($i + 1)) { $cells[$r][$i].PadLeft($widths[$i]) } else { $cells[$r][$i].PadRight($widths[$i]) }
        }
        $lines.Add('| ' + ($parts -join ' | ') + ' |')
        if ($r -eq 0) { $lines.Add($border) }
    }
    $lines.Add($border)
    return $lines
}

# --- Output ---
$Groups = @(@('all', ''), @('manager', ''), @('worker', ''), @('all', 'linux'), @('all', 'windows'))
$Output = New-Object System.Collections.Generic.List[string]

if ($Json) {
    $groupObjects = foreach ($group in $Groups) {
        $stats = Get-GroupStatistic $group[0] $group[1]
        [ordered]@{ role = $group[0]; os = $group[1]; nodes = $stats.Nodes; cores = $stats.Cores; mem_gib = [double]::Parse($stats.Gib, $Invariant) }
    }
    $nodeObjects = foreach ($row in $NodeRows) {
        $copy = [ordered]@{}
        foreach ($property in $row.PSObject.Properties) { $copy[$property.Name] = $property.Value }
        $copy['mem_gib'] = [double]::Parse($row.mem_gib, $Invariant)
        $copy['orchestrators'] = @($row.orchestrators)
        $copy
    }
    $document = [ordered]@{
        cluster_id  = $ClusterId
        mke_version = $MkeVersion
        msr_version = $MsrVersion
        groups      = @($groupObjects)
        nodes       = @($nodeObjects)
    }
    $Output.Add((ConvertTo-Json -InputObject $document -Depth 6 -Compress))
} elseif ($Csv) {
    $Output.Add('ClusterID,Role,OS,NodeCount,TotalCores,TotalGiB')
    foreach ($group in $Groups) {
        $stats = Get-GroupStatistic $group[0] $group[1]
        $Output.Add(('{0},{1},{2},{3},{4},{5}' -f $ClusterId, $group[0], $group[1], $stats.Nodes, $stats.Cores, $stats.Gib))
    }
} elseif ($NodesCsv) {
    $Output.Add('"ClusterID","Hostname","NodeID","Role","Availability","State","Address","OS","Arch","OperatingSystem","EngineVersion","vCPUs","RAM_GiB","Created","Updated"')
    foreach ($row in $NodeRows) {
        $quoted = foreach ($value in @($ClusterId, $row.hostname, $row.id, $row.role, $row.availability, $row.state, $row.addr, $row.os, $row.arch, $row.operating_system, $row.engine)) {
            ConvertTo-CsvField $value
        }
        $Output.Add((($quoted -join ',') + ',' + $row.cpus + ',' + $row.mem_gib + ',' + (ConvertTo-CsvField $row.created) + ',' + (ConvertTo-CsvField $row.updated)))
    }
} else {
    # Per-node details
    $rows = @(, @('Hostname', 'Node ID', 'Role', 'Avail', 'State', 'Address', 'OS/Arch', 'Operating System', 'Engine', 'vCPUs', 'RAM (GiB)'))
    foreach ($row in $NodeRows) {
        $osArch = (@($row.os, $row.arch) | Where-Object { $_ }) -join '/'
        $id = $row.id.Substring(0, [math]::Min(10, $row.id.Length))
        $values = @($row.hostname, $id, $row.role, $row.availability, $row.state, $row.addr, $osArch,
            $row.operating_system, $row.engine, [string]$row.cpus, $row.mem_gib) |
            ForEach-Object { if ($_) { $_ } else { '-' } }
        $rows += , @($values)
    }
    $Output.Add('')
    foreach ($line in (Format-BorderedTable $rows @(10, 11))) { $Output.Add($line) }

    # Summary by node group
    $border = '+------------+-------+-------------+-----------------+'
    $rowFormat = '| {0,-10} | {1,5} | {2,11} | {3,15} |'
    $Output.Add('')
    $Output.Add($border)
    $Output.Add(($rowFormat -f 'Node Group', 'Nodes', 'Total Cores', 'Total RAM (GiB)'))
    $Output.Add($border)
    foreach ($entry in @(@('Managers', 'manager', ''), @('Workers', 'worker', ''), '-', @('Linux', 'all', 'linux'), @('Windows', 'all', 'windows'), '-', @('Total', 'all', ''))) {
        if ($entry -eq '-') { $Output.Add($border); continue }
        $stats = Get-GroupStatistic $entry[1] $entry[2]
        $Output.Add(($rowFormat -f $entry[0], $stats.Nodes, $stats.Cores, $stats.Gib))
    }
    $Output.Add($border)
}

if ($OutFile) {
    $path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $OutFile))
    [System.IO.File]::WriteAllText($path, (($Output -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
    Write-Info "Output written to $path"
} else {
    $Output
}
