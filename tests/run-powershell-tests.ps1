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
$Script = Join-Path (Split-Path -Parent $Tests) 'windows/swarm-core-audit.ps1'
$Expected = Join-Path $Tests 'expected'
$Shell = (Get-Process -Id $PID).Path
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("ps-audit-tests-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Work | Out-Null

$script:Pass = 0
$script:Fail = 0
function Pass([string]$Name) { $script:Pass++; Write-Output "  ok   - $Name" }
function Fail([string]$Name, [string]$Detail) {
    $script:Fail++
    Write-Output "  FAIL - $Name"
    if ($Detail) { $Detail -split "`n" | Select-Object -First 20 | ForEach-Object { Write-Output "         $_" } }
}
function Assert-Equal([string]$Name, $Actual, $Expected) {
    if ($Actual -ceq $Expected) { Pass $Name } else { Fail $Name "expected: $Expected`nactual:   $Actual" }
}
function Assert-Contains([string]$Name, [string]$Haystack, [string]$Needle) {
    if ($Haystack.Contains($Needle)) { Pass $Name } else { Fail $Name "expected to find: $Needle" }
}
function Assert-NotContains([string]$Name, [string]$Haystack, [string]$Needle) {
    if ($Haystack.Contains($Needle)) { Fail $Name "did not expect: $Needle" } else { Pass $Name }
}

# Runs the audit; returns exit code, stdout and stderr
function Invoke-Audit([string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Shell
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
    $psi.Arguments = ($all | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{ Code = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
}

function Read-Text([string]$Path) { return [System.IO.File]::ReadAllText($Path) }

# Canonical form of a JSON value, with every number as a double, for comparing by content
function ConvertTo-Canonical($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ConvertTo-Json -InputObject $Value -Compress }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [ValueType]) { return ([double]$Value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [System.Collections.IEnumerable]) { return '[' + ((@($Value) | ForEach-Object { ConvertTo-Canonical $_ }) -join ',') + ']' }
    $fields = foreach ($p in $Value.PSObject.Properties) { (ConvertTo-Json -InputObject $p.Name -Compress) + ':' + (ConvertTo-Canonical $p.Value) }
    return '{' + ($fields -join ',') + '}'
}

Write-Output "PowerShell audit tests (PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition))"

try {
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
                if ($actual -ceq $wanted) { Pass "json content matches $(Split-Path -Leaf $expectedFile)" }
                else { Fail "json content matches $(Split-Path -Leaf $expectedFile)" "expected: $wanted`nactual:   $actual" }
            } else {
                $actual = Read-Text $out
                $wanted = Read-Text $expectedFile
                if ($actual -ceq $wanted) { Pass "$mode output matches $(Split-Path -Leaf $expectedFile)" }
                else {
                    $a = $actual -split "`n"; $w = $wanted -split "`n"
                    $diff = for ($i = 0; $i -lt [math]::Max($a.Count, $w.Count); $i++) {
                        if ($i -ge $a.Count -or $i -ge $w.Count -or $a[$i] -cne $w[$i]) { "line $($i + 1):`n  expected: $($w[$i])`n  actual:   $($a[$i])" }
                    }
                    Fail "$mode output matches $(Split-Path -Leaf $expectedFile)" (($diff | Select-Object -First 3) -join "`n")
                }
            }
        }
    }

    Write-Output '# log messages'
    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'))
    $firstLine = ($result.Err -split "`r?`n")[0]
    Assert-Contains 'first line is the version' $firstLine '] mcr-cluster-config version '
    Assert-Contains 'connected node described' $result.Err '] Connected node: WIN-MGR-01, Windows Server 2022 Datacenter'
    Assert-Contains 'node count wording' $result.Err '] Retrieved 4 nodes (managers: 1, workers: 3)'
    Assert-Contains 'OS coverage warning with Windows hint' $result.Err '] Operating system found for 1 of 4 nodes. docker info on this engine only describes this node; run the audit on each node'
    Assert-Contains 'down node warning' $result.Err '] Node WIN-WKR-02: state down, availability active (heartbeat failure)'
    Assert-Contains 'drained node warning' $result.Err '] Node win-wkr-03: state ready, availability drain'
    Assert-Contains 'stdout has the table' $result.Out '| Hostname   | Node ID    |'
    Assert-NotContains 'no log lines on stdout' $result.Out 'INFO['

    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-mke'))
    Assert-Contains 'MKE version through MKE' $result.Err '] MKE version: 3.8.8'
    Assert-Contains 'MSR version from services' $result.Err '] MSR version: 2.9.19'
    Assert-NotContains 'no connected-node line through MKE' $result.Err 'Connected node:'
    Assert-NotContains 'every node has an OS through MKE' $result.Err 'Operating system found for'

    Write-Output '# options and errors'
    $out = Join-Path $Work 'bom-check.csv'
    $null = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'), '-Csv', '-OutFile', $out)
    $bytes = [System.IO.File]::ReadAllBytes($out)
    Assert-Equal '-OutFile writes UTF-8 without a BOM' ($bytes[0] -ne 0xEF -and $bytes[0] -ne 0xFF) $true
    Assert-Equal '-OutFile uses LF line endings' ((Read-Text $out).Contains("`r")) $false
    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'), '-Csv', '-Json')
    Assert-Equal 'conflicting formats: exits 1' $result.Code 1
    Assert-Contains 'conflicting formats: FATA message' $result.Err '] Use only one of -Csv, -NodesCsv and -Json.'
    $result = Invoke-Audit @('-InputDirectory', $Work)
    Assert-Equal 'missing nodes.json: exits 1' $result.Code 1
    Assert-Contains 'missing nodes.json: FATA message' $result.Err '] Unable to find nodes.json'
    $result = Invoke-Audit @('-InputDirectory', (Join-Path $Tests 'fixtures/mock-windows'), '-NodesCsv')
    Assert-Equal 'stdout without -OutFile matches the expected file' ($result.Out -replace "`r", '') (Read-Text (Join-Path $Expected 'audit-mock-windows.nodes-csv.out'))
} finally {
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output "$($script:Pass) passed, $($script:Fail) failed"
if ($script:Fail -gt 0) { exit 1 }
