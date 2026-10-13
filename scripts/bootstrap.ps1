[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectRoot, [string]$CodexHome, [switch]$InstallDependencies, [switch]$Force)
$ErrorActionPreference = 'Stop'
function Find-BootstrapPython {
  $candidates = @('python','python3')
  if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Programs/Python/Python312/python.exe' }
  foreach ($candidate in $candidates) {
    $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
      & $command.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>$null
      if ($LASTEXITCODE -eq 0) { return $command.Source }
    }
  }
}
$pythonPath = Find-BootstrapPython
if (-not $pythonPath -and $InstallDependencies -and (Get-Command winget -ErrorAction SilentlyContinue)) {
  & winget install --id Python.Python.3.12 --exact --source winget --scope user --accept-source-agreements --accept-package-agreements
  if ($LASTEXITCODE -ne 0) { throw 'Python install failed; see docs/installation.md.' }
  $pythonPath = Find-BootstrapPython
}
if (-not $pythonPath) { throw 'Install Python 3.12, then retry. On Windows use -InstallDependencies. On macOS: brew install python@3.12. See docs/installation.md.' }
$arguments = @((Join-Path $PSScriptRoot 'install.py'),'--project-root',$ProjectRoot)
if ($CodexHome) { $arguments += @('--codex-home',$CodexHome) }
if ($InstallDependencies) { $arguments += '--install-tools' }
if ($Force) { $arguments += '--force' }
& $pythonPath @arguments
exit $LASTEXITCODE
