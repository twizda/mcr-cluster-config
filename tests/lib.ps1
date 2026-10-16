<#
.SYNOPSIS
    Assertion helpers shared by the PowerShell test scripts (dot-source this file).
    The caller sets $Script (the audit script) and $Shell (the PowerShell to run it with).
#>
$script:Pass = 0
$script:Fail = 0
function Write-Pass([string]$Name) { $script:Pass++; Write-Output "  ok   - $Name" }
function Write-Fail([string]$Name, [string]$Detail) {
    $script:Fail++
    Write-Output "  FAIL - $Name"
    if ($Detail) { $Detail -split "`n" | Select-Object -First 20 | ForEach-Object { Write-Output "         $_" } }
}
function Assert-Equal([string]$Name, $Actual, $Expected) {
    if ($Actual -ceq $Expected) { Write-Pass $Name } else { Write-Fail $Name "expected: $Expected`nactual:   $Actual" }
}
function Assert-Contains([string]$Name, [string]$Haystack, [string]$Needle) {
    if ($Haystack.Contains($Needle)) { Write-Pass $Name } else { Write-Fail $Name "expected to find: $Needle" }
}
function Assert-NotContains([string]$Name, [string]$Haystack, [string]$Needle) {
    if ($Haystack.Contains($Needle)) { Write-Fail $Name "did not expect: $Needle" } else { Write-Pass $Name }
}

# When $script:Emulate51 is set (PowerShell 7 only), the audit runs with ConvertFrom-Json behaving
# as in Windows PowerShell 5.1, which returns a JSON array as a single object instead of enumerating it
$script:Emulate51 = $false
$Shim51 = 'function ConvertFrom-Json { param([Parameter(ValueFromPipeline = $true)]$InputObject) Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject -NoEnumerate }'

# Runs the audit; returns exit code, stdout and stderr
function Invoke-Audit([string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Shell
    if ($script:Emulate51) {
        $quoted = ($Arguments | ForEach-Object { if ($_ -like '-*') { $_ } else { "'" + $_.Replace("'", "''") + "'" } }) -join ' '
        $command = "$Shim51; & '$Script' $quoted; exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    } else {
        $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
        $psi.Arguments = ($all | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    }
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

function Write-Summary {
    Write-Output ''
    Write-Output "$($script:Pass) passed, $($script:Fail) failed"
}
