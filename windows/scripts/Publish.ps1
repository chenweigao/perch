#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Publishes the Perch Windows client for win-x64.

.DESCRIPTION
    Produces a framework-dependent (default) or self-contained publish under
    windows/dist/. Cross-publishes from any host SDK via EnableWindowsTargeting, so this
    also runs on Linux CI. Native exit codes propagate through Invoke-Native.

.EXAMPLE
    ./Publish.ps1
    ./Publish.ps1 -SelfContained
    ./Publish.ps1 -Runtime win-x64 -Configuration Release
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Runtime = 'win-x64',

    # Self-contained bundles the .NET runtime; framework-dependent needs the .NET 8
    # Desktop Runtime already installed on the Windows machine.
    [switch] $SelfContained,

    [string] $Output
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Complete-Script {
    $dotnet = Test-DotnetAvailable
    $target = $Output
    if (-not $target) {
        $target = Join-Path $WindowsRoot 'dist' $Runtime
    }

    Write-Step "Publishing Perch ($Configuration, $Runtime, self-contained=$([bool]$SelfContained))"
    $publishArgs = @(
        'publish', $AppProject,
        '--configuration', $Configuration,
        '--runtime', $Runtime,
        '--self-contained', $SelfContained.IsPresent.ToString().ToLowerInvariant(),
        '--output', $target,
        '-nologo'
    )
    Invoke-Native -FilePath $dotnet -What 'dotnet publish' -Arguments $publishArgs

    $exe = Join-Path $target 'Perch.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Publish did not produce $exe."
    }
    Write-Step "Published to $target"
    Write-Info "Run on Windows: $exe"
}
