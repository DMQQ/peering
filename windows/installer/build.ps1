# Builds the unsigned Peering Host installer into windows\dist\PeeringHostSetup.exe.
# Needs Inno Setup 6 (ISCC.exe) and the Rust toolchain. Not run on Windows yet; see windows\README.md.

param(
    [string]$Version
)

$ErrorActionPreference = "Stop"
$windowsRoot = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $windowsRoot "target\release\peering-host.exe"

if (-not $Version) {
    $manifestVersion = Select-String -Path (Join-Path $windowsRoot "Cargo.toml") -Pattern '^version = "(.+)"' | Select-Object -First 1
    $Version = $manifestVersion.Matches[0].Groups[1].Value
}

if (-not (Test-Path $exe)) {
    Push-Location $windowsRoot
    try {
        cargo build --release -p peering-host
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }
}

$candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
    (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
)
$iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    throw "Inno Setup 6 was not found. Install it from https://jrsoftware.org/isinfo.php and run this script again."
}

New-Item -ItemType Directory -Force -Path (Join-Path $windowsRoot "dist") | Out-Null
& $iscc "/DMyAppVersion=$Version" "/DSourceExe=$exe" (Join-Path $PSScriptRoot "peering-host.iss")
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

Write-Output (Join-Path $windowsRoot "dist\PeeringHostSetup.exe")
