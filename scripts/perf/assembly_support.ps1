# Public Phase 2 synthetic fixtures and subprocess helpers. No live product claims.
. (Join-Path $PSScriptRoot 'append_history_support.ps1')

function New-MathSecrAssemblySession {
  param($Fixture)
  $session=Copy-MathSecrBenchmarkObject $Fixture.Session
  $session.snapshot.nextClicked=$false
  $session.snapshot.PSObject.Properties.Remove('edit')
  $session.snapshot.PSObject.Properties.Remove('persistence')
  return $session
}

function New-MathSecrAssemblyObservationInput {
  param($Packet)
  return [pscustomobject]@{
    schemaVersion=1
    literalEvidence=[pscustomobject]@{body=@('본문','조건');printedMetadata=@();visibleUiMetadata=@();formula=@()}
    candidateRecoveryEvidence=[pscustomobject]@{routes=@();coverage=@()}
    attempts=@([pscustomobject]@{
      attemptId=$Packet.attemptId;scope='initial-scope';phase='initial'
      chips=@([pscustomobject]@{value='본문';provenance='literal-body';evidenceReceipt='synthetic-body'},
        [pscustomobject]@{value='조건';provenance='literal-body';evidenceReceipt='synthetic-condition'})
      resetBefore=$true;clearReceipt='synthetic-clean';removedChips=@()
      submission=$Packet.submission;beforeSubmit=$Packet.beforeSubmit;observations=$Packet.observations
    })
  }
}

function New-MathSecrAssemblyJudgment {
  param([string]$AttemptId,[string]$CandidateId)
  return [pscustomobject]@{
    comparator='phase2-synthetic-contract-test';comparedAtUtc='2026-10-11T00:00:05.000Z'
    policy='body-only-v1';verdict='exact';candidateId=$CandidateId;searchAttemptId=$AttemptId
    comparison=[pscustomobject]@{bodyText='match';conditions='match';formulas='match';figures='not-present';
      pointLabels='not-present';requiredValue='match';internalStatements='not-present'}
    sourceRenderScale=2;candidateRenderScale=1;unresolvedGlyphs=$false
  }
}

function Start-MathSecrResidentValidation {
  param([string]$CodeRoot,[string]$ProjectRoot)
  $process=[Diagnostics.Process]::new()
  $info=[Diagnostics.ProcessStartInfo]::new()
  $info.FileName=(Get-Command pwsh -ErrorAction Stop).Source
  $info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $encoding=[Text.UTF8Encoding]::new($false)
  $info.StandardInputEncoding=$encoding;$info.StandardOutputEncoding=$encoding;$info.StandardErrorEncoding=$encoding
  foreach ($arg in @('-NoProfile','-File',(Join-Path $CodeRoot 'mathsecr-paper-builder-kit/scripts/validate_production_session.ps1'),
      '-ProjectRoot',$ProjectRoot)) {$info.ArgumentList.Add($arg)}
  $process.StartInfo=$info
  try {
    if (-not $process.Start()) {throw 'Resident validator did not start.'}
    return [pscustomobject]@{Process=$process;Stderr=$process.StandardError.ReadToEndAsync()}
  } catch {$process.Dispose();throw}
}

function Invoke-MathSecrResidentCommand {
  param($Worker,$Command,[string]$RawLine)
  $process=$Worker.Process
  if ($process.HasExited) {throw "Resident validator exited: $($Worker.Stderr.GetAwaiter().GetResult())"}
  $line=if ($PSBoundParameters.ContainsKey('RawLine')) {$RawLine} else {ConvertTo-Json -InputObject $Command -Depth 10 -Compress}
  $process.StandardInput.WriteLine($line);$process.StandardInput.Flush()
  $response=$process.StandardOutput.ReadLineAsync()
  if (-not $response.Wait(120000)) {throw 'Resident validation response timed out.'}
  $json=$response.GetAwaiter().GetResult()
  if ([string]::IsNullOrWhiteSpace($json)) {throw "Resident validator returned no response: $($Worker.Stderr.GetAwaiter().GetResult())"}
  return ConvertFrom-MathSecrContractJson $json
}

function Stop-MathSecrResidentValidation {
  param($Worker,[switch]$Eof)
  $process=$Worker.Process
  try {
    if (-not $process.HasExited) {
      if (-not $Eof) {$process.StandardInput.WriteLine('{"step":"exit"}');$process.StandardInput.Flush()}
      $process.StandardInput.Close()
      if (-not $process.WaitForExit(5000)) {$process.Kill();throw 'Resident validator did not exit within five seconds.'}
    }
    $stderr=$Worker.Stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($stderr)) {
      throw "Resident validator shutdown failed: $stderr"
    }
  } finally {
    if (-not $process.HasExited) {$process.Kill();$process.WaitForExit()}
    $process.Dispose()
  }
}
