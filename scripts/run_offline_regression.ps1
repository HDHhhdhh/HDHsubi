[CmdletBinding()]
param(
  [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ManifestPath = (Join-Path $PSScriptRoot 'offline-regression-gates.json'),
  [string]$NodePath = 'node',
  [string]$PlaywrightModule,
  [string]$BrowserPath
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
function Resolve-OfflineGatePath {
  param([string]$Relative)
  if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or
      @($Relative -split '[\\/]' | Where-Object {$_ -in @('','.','..')}).Count) {
    throw 'Gate paths must be canonical, project-relative paths.'
  }
  $full = [IO.Path]::GetFullPath((Join-Path $project $Relative))
  if (-not $full.StartsWith($project + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Gate path leaves ProjectRoot.'
  }
  return $full
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
if ($manifest.schemaVersion -ne 1 -or $manifest.gates -isnot [array] -or $manifest.gates.Count -eq 0) {
  throw 'Invalid or empty offline regression manifest.'
}
$identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($gate in $manifest.gates) {
  if (-not $identities.Add([string]$gate.id) -or [string]::IsNullOrWhiteSpace($gate.id) -or
      $gate.grade -cnotin @('public','private-bundle') -or $gate.requiredPaths -isnot [array] -or
      $gate.parameters -isnot [Collections.IDictionary] -or [string]::IsNullOrWhiteSpace($gate.reason)) {
    throw 'Invalid gate identity, grade, dependencies, parameters, or reason.'
  }
  $scriptPath = Resolve-OfflineGatePath $gate.script
  if ([IO.Path]::GetExtension($scriptPath) -cne '.ps1' -or -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Gate script is missing: $($gate.id)"
  }
  foreach ($relative in $gate.requiredPaths) { $null = Resolve-OfflineGatePath $relative }
  if ($gate.grade -ceq 'public') {
    if ([string]::IsNullOrWhiteSpace($gate.passPattern)) { throw "No PASS marker for public gate: $($gate.id)" }
    $null = [regex]::new($gate.passPattern)
  }
}
# Every archived test suite must remain visible, even when its data is withheld.
if ([IO.Path]::GetFullPath($ManifestPath) -eq [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'offline-regression-gates.json'))) {
  foreach ($file in Get-ChildItem -LiteralPath (Join-Path $project 'mathsecr-paper-builder-kit/scripts') -Filter 'test_*.ps1') {
    $relative = 'mathsecr-paper-builder-kit/scripts/' + $file.Name
    if (@($manifest.gates | Where-Object {$_.script -ceq $relative}).Count -eq 0) { throw "Unclassified test suite: $relative" }
  }
}
$pwsh = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { $pwsh = (Get-Command pwsh -ErrorAction Stop).Source }
$counts = @{PASS=0;FAIL=0;SKIP=0}
foreach ($gate in $manifest.gates) {
  $record = [ordered]@{kind='gate';id=$gate.id;grade=$gate.grade;status='SKIP';elapsedMs=0;
    truthScope='offline-contract';liveProductBehavior=$false}
  if ($gate.grade -ceq 'private-bundle') {
    $record.reason = $gate.reason
    $record.requiredPaths = $gate.requiredPaths
  } else {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
      foreach ($relative in $gate.requiredPaths) {
        if (-not (Test-Path -LiteralPath (Resolve-OfflineGatePath $relative))) { throw "Missing public dependency: $relative" }
      }
      $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Resolve-OfflineGatePath $gate.script))
      foreach ($key in $gate.parameters.Keys) {
        $value = $gate.parameters[$key]
        if ($value -ceq '{projectRoot}') { $value = $project }
        $arguments += @("-$key", [string]$value)
      }
      if ($gate.script -ceq 'mathsecr-paper-builder-kit/scripts/test_search_observation.ps1') {
        $arguments += @('-NodePath',$NodePath)
        if ($PlaywrightModule) { $arguments += @('-PlaywrightModule',$PlaywrightModule) }
        if ($BrowserPath) { $arguments += @('-BrowserPath',$BrowserPath) }
      }
      $previousPreference = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try { $output = @(& $pwsh @arguments 2>&1 | ForEach-Object {[string]$_}); $code = $LASTEXITCODE }
      finally { $ErrorActionPreference = $previousPreference }
      $text = $output -join [Environment]::NewLine
      if ($code -ne 0) { throw "Exit code $code. $text" }
      if (-not [regex]::IsMatch($text, $gate.passPattern)) { throw "Exit code 0 without the required PASS marker. $text" }
      $record.status = 'PASS'
      $record.marker = @($output | Where-Object {[regex]::IsMatch($_, $gate.passPattern)})[-1]
    } catch {
      $record.status = 'FAIL'
      $record.error = $_.Exception.Message
    } finally {
      $timer.Stop()
      $record.elapsedMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 3)
    }
  }
  $counts[$record.status]++
  ConvertTo-Json -InputObject $record -Depth 8 -Compress
}
[ordered]@{kind='summary';status=$(if ($counts.FAIL) {'FAIL'} else {'PASS'});passed=$counts.PASS;failed=$counts.FAIL;
  skipped=$counts.SKIP;fullPrivateRegressionRun=$false;liveProductBehavior=$false} | ConvertTo-Json -Compress
if ($counts.FAIL) { exit 1 }
