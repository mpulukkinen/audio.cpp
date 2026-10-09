[CmdletBinding()]
param(
    [int]$Jobs = 0,
    [string]$Version = "dev",
    [switch]$Vulkan,
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
$backend = if ($Vulkan) { "vulkan" } else { "cpu" }
$buildDir = Join-Path $repoRoot "build\windows-arm64-$backend-release"
$binDir = Join-Path $buildDir "bin"
$vulkanEnabled = if ($Vulkan) { "ON" } else { "OFF" }

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
    "-DENGINE_ENABLE_VULKAN=$vulkanEnabled",
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

if ($Vulkan) {
    if (-not $env:VULKAN_SDK) {
        throw "Vulkan build requested but VULKAN_SDK is not set"
    }

    $vulkanLibrary = Join-Path $env:VULKAN_SDK "Lib-ARM64\vulkan-1.lib"
    $vulkanInclude = Join-Path $env:VULKAN_SDK "Include"
    $glslc = Join-Path $env:VULKAN_SDK "Bin\glslc.exe"

    foreach ($required in @($vulkanLibrary, $vulkanInclude, $glslc)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Missing Vulkan SDK component required for ARM64 cross-build: $required"
        }
    }

    $configureArgs += @(
        "-DVulkan_LIBRARY=$vulkanLibrary",
        "-DVulkan_INCLUDE_DIR=$vulkanInclude",
        "-DVulkan_GLSLC_EXECUTABLE=$glslc"
    )
}

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
    # Multi-config Visual Studio generators place Release outputs under bin\Release.
    # Prefer that exact location, then fall back to a recursive search while
    # ignoring the flattened destination copy in $binDir itself.
    $releaseBinary = Join-Path $binDir "Release\$name"
    if (Test-Path -LiteralPath $releaseBinary) {
        $binary = Get-Item -LiteralPath $releaseBinary
    } else {
        $destinationBinary = Join-Path $binDir $name
        $binary = Get-ChildItem -LiteralPath $buildDir -Recurse -File -Filter $name |
            Where-Object { $_.FullName -ne $destinationBinary } |
            Select-Object -First 1
    }

    if (-not $binary) {
        throw "Missing $name under $buildDir"
    }

    $destinationBinary = Join-Path $binDir $name
    if ($binary.FullName -ne $destinationBinary) {
        Copy-Item -LiteralPath $binary.FullName -Destination $destinationBinary -Force
    }
}

Get-ChildItem -LiteralPath $buildDir -Recurse -File -Filter "*.dll" |
    Where-Object { $_.DirectoryName -ne $binDir } |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $binDir -Force }

if ($Vulkan) {
    $cache = Join-Path $buildDir "CMakeCache.txt"
    # CMake accepts several canonical true spellings; validate the value semantically.
    foreach ($settingName in @(
        "ENGINE_ENABLE_VULKAN",
        "GGML_VULKAN"
    )) {
        $match = Select-String -LiteralPath $cache -Pattern ("^" + [regex]::Escape($settingName) + ":BOOL=(ON|TRUE|YES|1)$")
        if (-not $match) {
            throw "ARM64 Vulkan configure validation failed: '$settingName' is not enabled in CMakeCache.txt"
        }
    }

    # The Vulkan backend ultimately links against the Windows Vulkan loader.
    # Check the flattened release executables themselves so a CPU-only binary
    # cannot be accidentally published under the Vulkan package name.
    foreach ($name in @("audiocpp_cli.exe", "audiocpp_server.exe")) {
        $path = Join-Path $binDir $name
        $binaryText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($path))
        if ($binaryText.IndexOf("vulkan-1.dll", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "$name does not reference vulkan-1.dll; refusing to publish a CPU-only ARM64 Vulkan build"
        }
    }
}

Write-Host "Windows ARM64 $backend build ready in $binDir"
