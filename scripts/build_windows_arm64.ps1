[CmdletBinding()]
param(
    [int]$Jobs = 0,
    [string]$Version = "dev",
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )

    Write-Host "> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
    }
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$buildDir = Join-Path $repoRoot "build\windows-arm64-cpu-release"
$binDir = Join-Path $buildDir "bin"

if ($Clean) {
    Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
}

$configureArgs = @(
    "-S", $repoRoot,
    "-B", $buildDir,
    "-G", "Visual Studio 17 2022",
    "-A", "ARM64",
    "-T", "ClangCL",
    "-DAUDIOCPP_VERSION=$Version",
    "-DAUDIOCPP_DEPLOYMENT_BUILD=ON",
    "-DENGINE_ENABLE_CUDA=OFF",
    "-DENGINE_ENABLE_HIP=OFF",
    "-DENGINE_ENABLE_VULKAN=OFF",
    "-DENGINE_ENABLE_METAL=OFF",
    "-DENGINE_ENABLE_LLAMAFILE=OFF",
    "-DENGINE_ENABLE_CUDA_GRAPHS=OFF",
    "-DENGINE_ENABLE_NATIVE_CPU=OFF",
    "-DENGINE_ENABLE_OPENMP=OFF",
    "-DGGML_OPENMP=OFF",
    "-DENGINE_ENABLE_CPU_ALL_VARIANTS=OFF",
    "-DENGINE_BUILD_TESTS=OFF",
    "-DENGINE_BUILD_EXAMPLES=OFF",
    "-DGGML_CPU_ARM_ARCH=armv8-a",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"
)

Invoke-Checked "cmake.exe" $configureArgs

$effectiveJobs = if ($Jobs -gt 0) {
    $Jobs
} else {
    [Math]::Max(2, [Environment]::ProcessorCount)
}

foreach ($target in @("audiocpp_cli", "audiocpp_server", "audiocpp_gguf")) {
    Invoke-Checked "cmake.exe" @(
        "--build", $buildDir,
        "--config", "Release",
        "--target", $target,
        "-j", $effectiveJobs.ToString()
    )
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null

$expected = @("audiocpp_cli.exe", "audiocpp_server.exe", "audiocpp_gguf.exe")
foreach ($name in $expected) {
    $binary = Get-ChildItem -LiteralPath $buildDir -Recurse -File -Filter $name |
        Where-Object { $_.FullName -notlike "$binDir\*" } |
        Select-Object -First 1

    if (-not $binary) {
        $binary = Get-ChildItem -LiteralPath $binDir -File -Filter $name | Select-Object -First 1
    }
    if (-not $binary) {
        throw "Missing $name under $buildDir"
    }

    if ($binary.DirectoryName -ne $binDir) {
        Copy-Item -LiteralPath $binary.FullName -Destination $binDir -Force
    }
}

Get-ChildItem -LiteralPath $buildDir -Recurse -File -Filter "*.dll" |
    Where-Object { $_.DirectoryName -ne $binDir } |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $binDir -Force }

Write-Host "Windows ARM64 CPU build ready in $binDir"
