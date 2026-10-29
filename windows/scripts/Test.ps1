#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs the Perch Windows core tests (protocol, SSH arguments, state, secrets).

.DESCRIPTION
    The tests have no WPF or Windows dependency, so they run under `dotnet test` on
    Linux as well as Windows. Optionally regenerates the fixtures from the real bridge
    first (needs python3). Native exit codes propagate through Invoke-Native.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug',

    # Regenerate fixtures from remote/native-agent-service.py before testing. Off by
    # default so a run with no python3 still tests the committed fixtures.
    [switch] $RegenerateFixtures,

    # Extra filter passed to `dotnet test --filter`.
    [string] $Filter
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Complete-Script {
    $dotnet = Test-DotnetAvailable

    if ($RegenerateFixtures) {
        $python = Get-Command python3 -ErrorAction SilentlyContinue
        if ($null -eq $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
        if ($null -eq $python) {
            throw 'RegenerateFixtures 需要 python3，但未在 PATH 中找到。'
        }
        Write-Step 'Regenerating fixtures from the real bridge'
        $generator = Join-Path $WindowsRoot 'tools' 'generate-fixtures.py'
        Invoke-Native -FilePath $python.Source -What 'generate-fixtures.py' -Arguments @($generator)
    }

    Write-Step "Testing Perch Windows core ($Configuration)"
    $testArgs = @('test', $TestProject, '--configuration', $Configuration, '-nologo')
    if ($Filter) { $testArgs += @('--filter', $Filter) }
    Invoke-Native -FilePath $dotnet -What 'dotnet test' -Arguments $testArgs

    Write-Step 'Tests passed.'
}
