#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds the Perch Windows client (core library + WPF app).

.DESCRIPTION
    Cross-builds the WPF app for win-x64 on any host SDK via EnableWindowsTargeting, so
    this also runs on Linux CI. Native exit codes propagate through Invoke-Native.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Complete-Script {
    $dotnet = Test-DotnetAvailable
    Write-Step "Building Perch Windows ($Configuration)"
    Write-Info "dotnet: $dotnet"

    Invoke-Native -FilePath $dotnet -What 'dotnet build' -Arguments @(
        'build', $Solution,
        '--configuration', $Configuration,
        '-nologo'
    )

    Write-Step "Build succeeded ($Configuration)."
}
