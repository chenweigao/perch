#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Shared helpers for the Perch Windows build/test/publish scripts. Dot-source it:
        . (Join-Path $PSScriptRoot 'Common.ps1')

.DESCRIPTION
    Every native command goes through Invoke-Native, which checks $LASTEXITCODE and
    throws on failure. This is the one place that decides how exit codes propagate, so a
    non-zero ssh/dotnet/git status can never be masked by a later successful command.
    Paths with spaces and Chinese characters are passed as structured arguments, never
    interpolated into a shell string.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The exit code of the last native command that failed, so Complete-Script can re-emit it
# verbatim instead of collapsing every failure to 1.
$script:LastNativeExitCode = 0

# Resolve the windows/ directory from this script's own location, so the scripts work
# no matter what the current directory is and no matter what characters the path holds.
# $PSScriptRoot is set when dot-sourced or run directly under PowerShell 7.
$scriptsDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$WindowsRoot = Split-Path -Parent $scriptsDir
$RepoRoot = Split-Path -Parent $WindowsRoot
$Solution = Join-Path $WindowsRoot 'Perch.Windows.sln'
$AppProject = Join-Path $WindowsRoot 'src' 'Perch.App' 'Perch.App.csproj'
$CoreProject = Join-Path $WindowsRoot 'src' 'Perch.Core' 'Perch.Core.csproj'
$TestProject = Join-Path $WindowsRoot 'tests' 'Perch.Core.Tests' 'Perch.Core.Tests.csproj'

function Write-Step {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Assert-LastExitCode {
    param(
        [Parameter(Mandatory)][string] $What,
        [int] $Code = $LASTEXITCODE
    )
    if ($Code -ne 0) {
        $script:LastNativeExitCode = $Code
        throw "$What failed with exit code $Code."
    }
}

<#
    Runs a native executable and streams its output. On a non-zero exit code it records
    that code in $script:LastNativeExitCode and throws, so a failing dotnet/git/ssh can
    never be masked by a later successful command, and the exact native exit code is
    preserved for Complete-Script to re-emit.
#>
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter()][string[]] $Arguments = @(),
        [Parameter()][string] $What = $FilePath
    )
    Write-Info "$FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    Assert-LastExitCode -What $What
}

<#
    Runs a script body, exiting 0 on success. On failure it prints the error and exits
    with the native command's own exit code when one caused the failure (otherwise 1),
    so CI sees the real code rather than a collapsed one. `exit` here terminates the
    dot-sourcing script.
#>
function Complete-Script {
    param([Parameter(Mandatory)][scriptblock] $Body)
    try {
        & $Body
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $code = $script:LastNativeExitCode
        if (-not $code) { $code = 1 }
        exit $code
    }
    exit 0
}

function Test-DotnetAvailable {
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'dotnet 未在 PATH 中找到。请安装 .NET 8 SDK 后重试。'
    }
    return $command.Source
}
