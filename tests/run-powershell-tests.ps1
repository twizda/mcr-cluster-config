<#
.SYNOPSIS
    Tests windows/swarm-core-audit.ps1 against the mock cluster fixtures.

.DESCRIPTION
    Text, -Csv and -NodesCsv output must match tests/expected/audit-<fixture>.*.out exactly: the
    same files the Linux audit is tested against, so both implementations produce identical
    output. JSON is compared by content (number formatting differs between jq and PowerShell).
    The audit runs in the same PowerShell that runs this script, so run it with both
    powershell.exe (5.1) and pwsh (7.x).

.EXAMPLE
    pwsh -NoProfile -File tests/run-powershell-tests.ps1
#>
$ErrorActionPreference = 'Stop'
$Tests = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AuditScript = Join-Path (Split-Path -Parent $Tests) 'windows/swarm-core-audit.ps1'
$Expected = Join-Path $Tests 'expected'
$script:Shell = (Get-Process -Id $PID).Path
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-audit-tests-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Work | Out-Null

. (Join-Path $Tests 'lib.ps1')

# On PowerShell 7, also run every test with ConvertFrom-Json behaving as in Windows PowerShell 5.1
$Emulate51Modes = @($false)
if ($PSVersionTable.PSVersion.Major -ge 7) { $Emulate51Modes += $true }

function Read-Text([string]$Path) { return [System.IO.File]::ReadAllText($Path) }

Write-Output "PowerShell audit tests (PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition))"

try {
  foreach ($emulate in $Emulate51Modes) {
    $script:Emulate51 = $emulate
    if ($emulate) { Write-Output '## again, with ConvertFrom-Json behaving as in Windows PowerShell 5.1' }
    foreach ($fixture in @('mock-mke', 'mock-windows')) {
        Write-Output "# $fixture"
        $fixtureDir = Join-Path $Tests "fixtures/$fixture"
        foreach ($mode in @('text', 'csv', 'nodes-csv', 'json')) {
            $out = Join-Path $Work "$fixture.$mode.out"
            $arguments = @('-InputDirectory', $fixtureDir, '-OutFile', $out)
            switch ($mode) { 'csv' { $arguments += '-Csv' } 'nodes-csv' { $arguments += '-NodesCsv' } 'json' { $arguments += '-Json' } }
            $result = Invoke-Audit $arguments
            Assert-Equal "$mode exits 0" $result.Code 0
            $expectedFile = Join-Path $Expected "audit-$fixture.$mode.out"
            if ($mode -eq 'json') {
                $actual = ConvertTo-Canonical (ConvertFrom-Json -InputObject (Read-Text $out))
                $wanted = ConvertTo-Canonical (ConvertFrom-Json -InputObject (Read-Text $expectedFile))
                if ($actual -ceq $wanted) { Write-Pass "json content matches $(Split-Path -Leaf $expectedFile)" }
                else { Write-Fail "json content matches $(Split-Path -Leaf $expectedFile)" "expected: $wanted`nactual:   $actual" }
            } else {
                $actual = Read-Text $out
                $wanted = Read-Text $expectedFile
                if ($actual -ceq $wanted) { Write-Pass "$mode output matches $(Split-Path -Leaf $expectedFile)" }
                else {
                    $a = $actual -split "`n"; $w = $wanted -split "`n"
                    $diff = for ($i = 0; $i -lt [math]::Max($a.Count, $w.Count); $i++) {
                        if ($i -ge $a.Count -or $i -ge $w.Count -or $a[$i] -cne $w[$i]) { "line $($i + 1):`n  expected: $($w[$i])`n  actual:   $($a[$i])" }
                    }
                    Write-Fail "$mode output matches $(Split-Path -Leaf $expectedFile)" (($diff | Select-Object -First 3) -join "`n")
                }
            }
        }
    }

    Write-Output '# log messages'
    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'))
    $firstLine = ($result.Err -split "`r?`n")[0]
    Assert-Substring 'first line is the version' $firstLine '] mcr-cluster-config version '
    Assert-Substring 'connected node described' $result.Err '] Connected node: WIN-MGR-01, Windows Server 2022 Datacenter'
    Assert-Substring 'node count wording' $result.Err '] Retrieved 4 nodes (managers: 1, workers: 3)'
    Assert-Substring 'OS coverage warning with Windows hint' $result.Err '] Operating system found for 1 of 4 nodes. docker info on this engine only describes this node; run the audit on each node'
    Assert-Substring 'down node warning' $result.Err '] Node WIN-WKR-02: state down, availability active (heartbeat failure)'
    Assert-Substring 'drained node warning' $result.Err '] Node win-wkr-03: state ready, availability drain'
    Assert-Substring 'stdout has the table' $result.Out '| Hostname   | Node ID    |'
    Assert-NoSubstring 'no log lines on stdout' $result.Out 'INFO['

    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-mke'))
    Assert-Substring 'MKE version through MKE' $result.Err '] MKE version: 3.8.8'
    Assert-Substring 'MSR version from services' $result.Err '] MSR version: 2.9.19'
    Assert-NoSubstring 'no connected-node line through MKE' $result.Err 'Connected node:'
    Assert-NoSubstring 'every node has an OS through MKE' $result.Err 'Operating system found for'

    Write-Output '# options and errors'
    $out = Join-Path $Work 'bom-check.csv'
    $null = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'), '-Csv', '-OutFile', $out)
    $bytes = [System.IO.File]::ReadAllBytes($out)
    Assert-Equal '-OutFile writes UTF-8 without a BOM' ($bytes[0] -ne 0xEF -and $bytes[0] -ne 0xFF) $true
    Assert-Equal '-OutFile uses LF line endings' ((Read-Text $out).Contains("`r")) $false
    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'), '-Csv', '-Json')
    Assert-Equal 'conflicting formats: exits 1' $result.Code 1
    Assert-Substring 'conflicting formats: FATA message' $result.Err '] Use only one of -Csv, -NodesCsv and -Json.'
    $result = Invoke-Audit @('-InputDirectory', $Work)
    Assert-Equal 'missing nodes.json: exits 1' $result.Code 1
    Assert-Substring 'missing nodes.json: FATA message' $result.Err '] Unable to find nodes.json'
    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'), '-NodesCsv')
    Assert-Equal 'stdout without -OutFile matches the expected file' ($result.Out -replace "`r", '') (Read-Text (Join-Path $Expected 'audit-mock-windows.nodes-csv.out'))

    Write-Output '# Linux-style options (same commands as the Linux image)'
    foreach ($mode in @('csv', 'nodes-csv')) {
        $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'), "--$mode")
        Assert-Equal "--$mode exits 0" $result.Code 0
        Assert-Equal "--$mode matches the expected file" ($result.Out -replace "`r", '') (Read-Text (Join-Path $Expected "audit-mock-windows.$mode.out"))
    }
    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'), '--json')
    Assert-Equal '--json exits 0' $result.Code 0
    Assert-Substring '--json outputs JSON' $result.Out '{"cluster_id":"w1nclust3r0000000000000000"'
    $result = Invoke-Audit @('--help')
    Assert-Equal '--help exits 0' $result.Code 0
    Assert-Substring '--help prints usage' $result.Out 'Usage: swarm-core-audit.ps1 [--json | --csv | --nodes-csv]'
    Assert-NoSubstring '--help prints no log lines' $result.Err 'INFO['
    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'), '--xml')
    Assert-Equal 'unknown option: exits 1' $result.Code 1
    Assert-Substring 'unknown option: FATA message' $result.Err '] Unknown option: --xml.'
    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'), '--csv', '--json')
    Assert-Equal '--csv with --json: exits 1' $result.Code 1
  }
} finally {
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}

Write-Summary
if ($script:Fail -gt 0) { exit 1 }
