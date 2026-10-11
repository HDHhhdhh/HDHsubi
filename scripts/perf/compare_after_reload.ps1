[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BaselineRoot,
  [Parameter(Mandatory)][string]$CandidateRoot
)
$ErrorActionPreference = 'Stop'
$BaselineRoot = [IO.Path]::GetFullPath($BaselineRoot)
$CandidateRoot = [IO.Path]::GetFullPath($CandidateRoot)
foreach ($codeRoot in @($BaselineRoot,$CandidateRoot)) {
  if (-not (Test-Path -LiteralPath (Join-Path $codeRoot 'mathsecr-paper-builder-kit/scripts/production_validation.ps1') -PathType Leaf)) {
    throw "The checkout has no production validator: $codeRoot"
  }
}
. (Join-Path $CandidateRoot 'scripts/perf/append_history_support.ps1')
$childRunner = Join-Path $PSScriptRoot 'run_after_reload_identity_case.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source

function Find-MathSecrIdentityDifference {
  param($Left, $Right, [string]$Path='$')
  if ($null -eq $Left -or $null -eq $Right) {
    if ($null -ne $Left -or $null -ne $Right) { return $Path }
    return $null
  }
  if ($Left.GetType() -ne $Right.GetType()) { return $Path }
  if ($Left -is [array]) {
    if ($Left.Count -ne $Right.Count) { return ($Path + '.Count') }
    for ($index=0; $index -lt $Left.Count; $index++) {
      $difference = Find-MathSecrIdentityDifference $Left[$index] $Right[$index] ($Path + '[' + $index + ']')
      if ($null -ne $difference) { return $difference }
    }
  } elseif ($Left -is [pscustomobject]) {
    $leftProperties = @($Left.PSObject.Properties)
    $rightProperties = @($Right.PSObject.Properties)
    if ($leftProperties.Count -ne $rightProperties.Count) { return ($Path + '.Properties.Count') }
    for ($index=0; $index -lt $leftProperties.Count; $index++) {
      if ($leftProperties[$index].Name -cne $rightProperties[$index].Name) { return ($Path + '.Properties[' + $index + ']') }
      $next = $Path + "['" + $leftProperties[$index].Name.Replace("'","''") + "']"
      $difference = Find-MathSecrIdentityDifference $leftProperties[$index].Value $rightProperties[$index].Value $next
      if ($null -ne $difference) { return $difference }
    }
  } elseif ($Left -cne $Right) { return $Path }
  return $null
}

function Invoke-MathSecrIdentityChild {
  param([string]$CodeRoot, [string]$Root, [string]$SessionPath, [string]$Name)
  $outputPath = Join-Path $Root ($Name + '-identity.json')
  $output = @(& $pwsh -NoProfile -ExecutionPolicy Bypass -File $childRunner -CodeRoot $CodeRoot -FixtureRoot $Root -SessionPath $SessionPath -OutPath $outputPath 2>&1)
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
    throw "Identity child failed ($Name): $($output -join ' ')"
  }
  return ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8)
}

$root = $null
try {
  foreach ($historyDepth in @(1,2,6)) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('mathsecr-phase0-identity-' + [guid]::NewGuid().ToString('N'))
    $fixture = New-MathSecrAppendHistoryFixture -ProblemCount 15 -HistoryDepth $historyDepth -OutRoot $root
    $capturePath = Join-Path $root $fixture.Session.persistedCardObservationArtifact.path
    $captureBytes = [IO.File]::ReadAllBytes($capturePath)
    $pngPath = Join-Path $root 'source-1.png'
    $pngBytes = [IO.File]::ReadAllBytes($pngPath)
    $pdfSessions = @(foreach ($entry in $fixture.Manifest.sessions) {
      $historySession = ConvertFrom-MathSecrContractJson (Get-Content -LiteralPath (Join-Path $root $entry.artifact.path) -Raw -Encoding UTF8)
      if ($historySession.failureReportPdf -cne '없음') { $historySession }
    })
    if ($pdfSessions.Count -ne $historyDepth) { throw "H=$historyDepth failure PDF inventory differs from the fixture history." }
    foreach ($case in @('normal','prior-hash','missing-confirm','raw-visible-db','png-bytes','updated-hash-invalid-schema','pdf-truncated-latest','pdf-truncated-earliest')) {
      $session = Copy-MathSecrBenchmarkObject $fixture.Session
      $changedPdfPath = $null
      $changedPdfBytes = $null
      try {
      switch ($case) {
        'prior-hash' { $session.snapshot.editAppendReceipt.priorSessionArtifact.sha256 = '0' * 64 }
        'missing-confirm' { $session.snapshot.editAppendReceipt.PSObject.Properties.Remove('confirmActionArtifact') }
        'raw-visible-db' { $session.persistedCards[0].rawVisibleDbName = 'invented DB' }
        'png-bytes' { [IO.File]::WriteAllBytes($pngPath, [byte[]]($pngBytes + [byte]0x20)) }
        'updated-hash-invalid-schema' {
          $capture = ConvertFrom-MathSecrContractJson ([Text.Encoding]::UTF8.GetString($captureBytes))
          $capture.schemaVersion = 2
          [IO.File]::WriteAllText($capturePath, (ConvertTo-Json -InputObject $capture -Depth 100 -Compress), [Text.UTF8Encoding]::new($false))
          $session.persistedCardObservationArtifact.sha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
        }
        {$_ -cin @('pdf-truncated-latest','pdf-truncated-earliest')} {
          $pdfSession = if ($case -ceq 'pdf-truncated-latest') {$pdfSessions[-1]} else {$pdfSessions[0]}
          $changedPdfPath = $pdfSession.failureReportPdf
          $changedPdfBytes = [IO.File]::ReadAllBytes($changedPdfPath)
          [IO.File]::WriteAllBytes($changedPdfPath, [byte[]]$changedPdfBytes[0..([int][Math]::Floor($changedPdfBytes.Length / 2) - 1)])
        }
      }
      $sessionPath = Join-Path $root 'identity-input.json'
      [IO.File]::WriteAllText($sessionPath, (ConvertTo-Json -InputObject $session -Depth 100 -Compress), [Text.UTF8Encoding]::new($false))
      # Both versions consume this exact file and artifact root, in separate
      # processes. No candidate functions can leak into the baseline process.
      $before = Invoke-MathSecrIdentityChild $BaselineRoot $root $sessionPath 'baseline'
      $after = Invoke-MathSecrIdentityChild $CandidateRoot $root $sessionPath 'candidate'
      if ($case -ceq 'normal') {
        if (-not $before.accepted -or -not $after.accepted) {
          throw "H=$historyDepth normal acceptance differs: baseline=$($before.error); candidate=$($after.error)"
        }
        if ($before.resultJson -cne $after.resultJson) {
          $difference = Find-MathSecrIdentityDifference (ConvertFrom-MathSecrContractJson $before.resultJson) (ConvertFrom-MathSecrContractJson $after.resultJson)
          if ($null -eq $difference) { $difference = '$ (serialized representation)' }
          throw "H=$historyDepth normal result differs at $difference"
        }
        $typeDifference = Find-MathSecrIdentityDifference $before.scalarTypes $after.scalarTypes
        if ($null -ne $typeDifference) {
          $valuePath = $typeDifference
          if ($typeDifference -match '^\$\[([0-9]+)\]') { $valuePath = $before.scalarTypes[[int]$Matches[1]].path }
          throw "H=$historyDepth CLR scalar types differ at $valuePath ($typeDifference)"
        }
      } else {
        if ($before.accepted -or $after.accepted) { throw "H=$historyDepth case=$case was not rejected by both versions." }
        if ($case -clike 'pdf-truncated-*' -and -not $before.error.StartsWith('Failed-problem report PDF validation failed: ')) {
          throw "H=$historyDepth case=$case did not reach PDF validation: $($before.error)"
        }
        if ($before.error -cne $after.error) {
          throw "H=$historyDepth case=$case error differs: baseline=$($before.error); candidate=$($after.error)"
        }
      }
      Write-Output (ConvertTo-Json -InputObject ([pscustomobject]@{
        problemCount=15;historyDepth=$historyDepth;case=$case;status='PASS'
        scalarCount=@($before.scalarTypes).Count;truthScope='offline-contract'
      }) -Compress)
      } finally {
        [IO.File]::WriteAllBytes($capturePath, $captureBytes)
        [IO.File]::WriteAllBytes($pngPath, $pngBytes)
        if ($null -ne $changedPdfPath -and $null -ne $changedPdfBytes) { [IO.File]::WriteAllBytes($changedPdfPath, $changedPdfBytes) }
      }
    }
    Remove-MathSecrOwnedBenchmarkRoot $root
    $root = $null
  }
  Write-Output 'AfterReloadIdentity PASS'
} catch {
  Write-Error $_
  exit 1
} finally {
  if ($null -ne $root -and (Test-Path -LiteralPath $root)) { Remove-MathSecrOwnedBenchmarkRoot $root }
}
