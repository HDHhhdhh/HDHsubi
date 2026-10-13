$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../mathsecr-paper-builder-kit/scripts/state_machine.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('hdhsubi-paths-' + [guid]::NewGuid().ToString('N'))
try {
  $null = New-Item -ItemType Directory -Path (Join-Path $root 'images') -Force
  $image = Join-Path $root 'images/source.png'
  [IO.File]::WriteAllBytes($image,[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))
  foreach ($relative in @('images/source.png','images\source.png')) {
    $resolved = Resolve-MathSecrStateArtifactPath -ProjectRoot $root -RelativePath $relative
    if ($resolved -cne $image) { throw "Cross-platform artifact resolution failed: $relative" }
  }
  foreach ($relative in @('../source.png','images/../images/source.png','C:/source.png')) {
    if ($null -ne (Resolve-MathSecrStateArtifactPath -ProjectRoot $root -RelativePath $relative)) { throw 'Traversal was accepted.' }
  }
  Write-Output 'RuntimePaths PASS'
} finally {
  $full = [IO.Path]::GetFullPath($root)
  $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($tempPrefix,[StringComparison]::Ordinal) -or [IO.Path]::GetFileName($full) -notmatch '^hdhsubi-paths-[a-f0-9]{32}$') { throw 'Unsafe test cleanup root.' }
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
