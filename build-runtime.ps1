# build-runtime.ps1 — Windows environment shim for this repo's bash recipes.
#
# Peer to build-runtime.sh: on Windows every bash recipe (build-runtime.sh,
# test/consumer/run.sh) must run under the Visual Studio dev shell via Git-Bash.
# This script is that setup, once: vswhere -> Launch-VsDevShell (cl/cmake/ninja/
# INCLUDE/LIB) -> explicit Git-Bash -> exec the target with args verbatim.
#
# Usage: pwsh -File build-runtime.ps1 <script> [args...]
#   <script> is passed to bash as-is (repo-relative like ./dist/build-runtime.sh,
#   or Windows-form like C:\repo\build-runtime.sh). cwd is NOT changed: relative
#   scripts and the recipe's cwd expectations resolve against the caller's cwd.
#
# CI: when GITHUB_PATH is set, the VS LLVM bin dir is appended so LATER bash
# steps (build-windows' Structural checks) still get llvm-nm -- the dev shell
# env is process-local and dies with this script.
param(
  [Parameter(Mandatory, Position = 0)]
  [string]$Script,
  [Parameter(ValueFromRemainingArguments)]
  [string[]]$ScriptArgs
)
$ErrorActionPreference = 'Stop'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -property installationPath
if (-not $vsPath) { throw "vswhere found no Visual Studio installation" }

$llvmBin = "$vsPath\VC\Tools\Llvm\x64\bin"
if (-not (Test-Path "$llvmBin\llvm-nm.exe")) {
  throw "llvm-nm.exe not found under $llvmBin -- build_smoke.sh would silently skip its symbol checks"
}
if ($env:GITHUB_PATH) { Add-Content -Path $env:GITHUB_PATH -Value $llvmBin }

& "$vsPath\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -SkipAutomaticLocation
if ($LASTEXITCODE -ne 0) { throw "Launch-VsDevShell failed (exit $LASTEXITCODE)" }

$bash = "${env:ProgramFiles}\Git\bin\bash.exe"
if (-not (Test-Path $bash)) { throw "Git Bash not found at $bash -- WSL bash is NOT acceptable" }

& $bash $Script @ScriptArgs
exit $LASTEXITCODE
