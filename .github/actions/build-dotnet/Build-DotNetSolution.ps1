﻿param (
    [string] $Solution,
    [string] $Verbosity,
    [string] $EnableCodeAnalysis,
    [string] $Version,
    [string] $Switches,
    [string] $ExpectedCodeAnalysisErrors)

function ConvertTo-Array([string] $rawInput)
{
    $rawInput.Replace("`r", "").Split("`n") |
        % { $_.Trim() } |
        ? { -not [string]::IsNullOrEmpty($_) }
}

Write-Output ".NET version number: $Version"

# Notes on build switches that aren't self-explanatory:
# - -p:Retries and -p:RetryDelayMilliseconds are to retry builds if it fails the first time due to random locks.
# - --warnAsMessage:MSB3026 is also to prevent random locks along the lines of "warning MSB3026: Could not copy dlls
#   errors." from breaking the build (since we treat warnings as errors).

$buildSwitches = ConvertTo-Array @"
    --configuration:Release
    --nologo
    --verbosity:$Verbosity
    --warnaserror
    --warnAsMessage:MSB3026
    --consoleLoggerParameters:NoSummary
    -p:TreatWarningsAsErrors=true
    -p:RunAnalyzersDuringBuild=$EnableCodeAnalysis
    -p:Retries=4
    -p:RetryDelayMilliseconds=1000
    -p:Version=$Version
    $Switches
"@

[array] $expectedErrorCodes = ConvertTo-Array $ExpectedCodeAnalysisErrors | % { $_.Split(':')[0] } | Sort-Object
$noErrors = $expectedErrorCodes.Count -eq 0

if (Test-Path src/Utilities/Lombiq.Gulp.Extensions/Lombiq.Gulp.Extensions.csproj)
{
    Write-Output "::group::Gulp Extensions found. It needs to be explicitly built before the solution."

    $startTime = [DateTime]::Now
    dotnet build src/Utilities/Lombiq.Gulp.Extensions/Lombiq.Gulp.Extensions.csproj @buildSwitches
    $endTime = [DateTime]::Now

    Write-Output ("Gulp Extensions build took {0:0.###} seconds." -f ($endTime - $startTime).TotalSeconds)
    Write-Output "::endgroup::"
}

Write-Output "Building solution with ``dotnet build $Solution $($buildSwitches -join " ")``."

$errorFormat = '^(.*)\((\d+),(\d+)\): error (.*)'
$errorLines = New-Object "System.Collections.Generic.List[string]"
$errorCodes = New-Object "System.Collections.Generic.List[string]"

dotnet build $Solution @buildSwitches 2>&1 >build.log
[array] $log = (Get-Content -Raw build.log).Replace("`r", "") -split "`n"

$log | % {
    if ($_ -notmatch $errorFormat) { return $_ }

    ($null, $file, $line, $column, $message) = [regex]::Match($_, $errorFormat).Groups.Value

    $errorLines.Add($_)
    if ($message.Contains(":")) { $errorCodes.Add($message.Split(":")[0].Trim()) }
    if ($noErrors) { Write-Output "::error file=$file,line=$line,col=$column::$message" }
}

if ($expectedErrorCodes)
{
    $errorCodes = $errorCodes | Sort-Object
    $fail = 0
    $report = New-Object "System.Text.StringBuilder" "`n"

    $length = [System.Math]::Max($errorCodes.Count, $expectedErrorCodes.Count)
    foreach ($index in 0..($length - 1))
    {
        $actual = $errorCodes[$index]
        $expected = $expectedErrorCodes[$index]

        if ($actual -eq $expected)
        {
            $report.AppendLine("#$index OK ($actual)") | Out-Null
        } else
        {
            $report.AppendLine("#$index FAIL (expected: $expected; actual: $actual)") | Out-Null
            $fail++
        }
    }

    if ($fail -gt 0) {
        Write-Warning $report.ToString() # We use warning so it doesn't stop prematurely.
        Write-Output ("::error::Verification Mismatch " + ($errorLines -join " "))
        exit 1
    }

    Write-Output "Verification complete, the solution only has the expected errors!"
    exit 0
}

