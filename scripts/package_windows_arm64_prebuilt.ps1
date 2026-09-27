[CmdletBinding()]
param(
    [int]$Jobs = 0,
    [string]$OutputDir = ""
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
if ($OutputDir -eq "") {
    $OutputDir = Join-Path $repoRoot "build\prebuilt"
}

$packageName = "audiocpp-windows-arm64-cpu"
$stageDir = Join-Path $OutputDir $packageName
$zipPath = Join-Path $OutputDir "$packageName.zip"

Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

$configureArgs = @(
    "-S", $repoRoot,
    "-B", $buildDir,
    "-G", "Visual Studio 17 2022",
    "-A", "ARM64",
    "-T", "ClangCL",
    "-DAUDIOCPP_DEPLOYMENT_BUILD=ON",
    "-DENGINE_ENABLE_CUDA=OFF",
    "-DENGINE_ENABLE_HIP=OFF",
    "-DENGINE_ENABLE_VULKAN=OFF",
    "-DENGINE_ENABLE_METAL=OFF",
    "-DENGINE_ENABLE_LLAMAFILE=OFF",
    "-DENGINE_ENABLE_CUDA_GRAPHS=OFF",
    "-DENGINE_ENABLE_NATIVE_CPU=OFF",
    "-DENGINE_ENABLE_OPENMP=OFF",
    "-DENGINE_ENABLE_CPU_ALL_VARIANTS=OFF",
    "-DENGINE_BUILD_TESTS=OFF",
    "-DENGINE_BUILD_EXAMPLES=OFF",
    "-DGGML_CPU_ARM_ARCH=armv8-a",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"
)
Invoke-Checked "cmake.exe" $configureArgs

$effectiveJobs = if ($Jobs -gt 0) { $Jobs } else { [Math]::Max(2, [Environment]::ProcessorCount) }
foreach ($target in @("audiocpp_cli", "audiocpp_server", "audiocpp_gguf")) {
    Invoke-Checked "cmake.exe" @(
        "--build", $buildDir,
        "--config", "Release",
        "--target", $target,
        "-j", $effectiveJobs.ToString()
    )
}

$expected = @("audiocpp_cli.exe", "audiocpp_server.exe", "audiocpp_gguf.exe")
foreach ($name in $expected) {
    $binary = Get-ChildItem -LiteralPath $buildDir -Recurse -File -Filter $name | Select-Object -First 1
    if (-not $binary) {
        throw "Missing $name under $buildDir"
    }
    Copy-Item -LiteralPath $binary.FullName -Destination $stageDir -Force
}

Get-ChildItem -LiteralPath $buildDir -Recurse -File -Filter "*.dll" |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stageDir -Force }

$readme = @'
# audio.cpp Windows ARM64 CPU Prebuilt

Native Windows ARM64 build for Snapdragon-class Windows devices.

This package contains:

- `audiocpp_cli.exe`
- `audiocpp_server.exe`
- `audiocpp_gguf.exe`

The package is CPU-only and uses a conservative ARMv8-A baseline. CUDA, Vulkan,
HIP, OpenMP and llamafile are intentionally disabled for the first native ARM64
release so the package has the smallest possible compatibility surface.

Models are downloaded separately.
'@
Set-Content -LiteralPath (Join-Path $stageDir "README.md") -Value $readme -Encoding UTF8

Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath -Force
Write-Host "Created $zipPath"
