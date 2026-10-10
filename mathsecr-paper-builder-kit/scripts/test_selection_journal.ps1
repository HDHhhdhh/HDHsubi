param(
  [string]$ProjectRoot = (Get-Location).Path,
  [string]$Case = 'All'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
. (Join-Path $PSScriptRoot 'selection_journal.ps1')

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -cne $Expected) {
    throw "$Message. Expected '$Expected', got '$Actual'."
  }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Append-Events {
  param([string]$Path, [object[]]$Events)
  foreach ($event in @($Events)) {
    Add-MathSecrSelectionJournalEvent -Path $Path -Event $event | Out-Null
  }
}

function Read-Bytes {
  param([string]$Path)
  return [System.IO.File]::ReadAllBytes($Path)
}

function Assert-PrefixBytes {
  param([byte[]]$Prefix, [byte[]]$Actual, [string]$Message)
  Assert-True ($Actual.Length -ge $Prefix.Length) "$Message length"
  for ($i = 0; $i -lt $Prefix.Length; $i++) {
    if ($Prefix[$i] -ne $Actual[$i]) { throw "$Message changed byte $i" }
  }
}

function Test-SelectionJournalFileReads {
  param([string]$Root)

  $events = @(
    [ordered]@{ schemaVersion = 1; eventId = 'file-r-z'; eventType = 'selection_requested'; occurrenceKey = 'z-first'; problemId = 'p91'; attempt = 1 },
    [ordered]@{ schemaVersion = 1; eventId = 'file-a-z'; eventType = 'selection_ack'; occurrenceKey = 'z-first'; problemId = 'p91'; attempt = 1; requestEventId = 'file-r-z' },
    [ordered]@{ schemaVersion = 1; eventId = 'file-r-a'; eventType = 'selection_requested'; occurrenceKey = 'a-second'; problemId = 'p12'; attempt = 1 },
    [ordered]@{ schemaVersion = 1; eventId = 'file-a-a'; eventType = 'selection_ack'; occurrenceKey = 'a-second'; problemId = 'p12'; attempt = 1; requestEventId = 'file-r-a' }
  )
  $lfPath = Join-Path $Root 'file-read-lf.jsonl'
  $created = New-MathSecrSelectionJournal -Path $lfPath
  Assert-Equal $created.ByteLength 0 'Created journal byte length'
  Assert-Equal (Read-MathSecrSelectionJournal -Path $lfPath).EventCount 0 'Empty file event count'
  $emptyReplay = Resolve-MathSecrSelectionJournal -Path $lfPath
  Assert-Equal $emptyReplay.EventCount 0 'Empty file replay event count'
  Assert-Equal $emptyReplay.EffectiveOccurrenceCount 0 'Empty file effective count'
  Assert-Equal $emptyReplay.PendingOccurrenceCount 0 'Empty file pending count'

  # This read assertion must precede the fixture replay checks: a parser must
  # not silently turn one real, appended JSONL event into an empty journal.
  Add-MathSecrSelectionJournalEvent -Path $lfPath -Event $events[0] | Out-Null
  $single = Read-MathSecrSelectionJournal -Path $lfPath
  Assert-Equal $single.EventCount 1 'LF single-line read must preserve the appended event'
  Assert-Equal $single.Events[0].eventId 'file-r-z' 'LF single-line event identity'
  $singleReplay = Resolve-MathSecrSelectionJournal -Path $lfPath
  Assert-Equal $singleReplay.EventCount 1 'LF single-line replay event count'
  Assert-Equal $singleReplay.PendingOccurrenceCount 1 'LF single-line pending count'
  Assert-Equal $singleReplay.EffectiveOccurrenceCount 0 'LF single-line effective count'

  Append-Events -Path $lfPath -Events @($events[1], $events[2])
  $multiple = Read-MathSecrSelectionJournal -Path $lfPath
  Assert-Equal $multiple.EventCount 3 'LF multiple-line read event count'
  Assert-Equal (($multiple.Events | ForEach-Object { $_.eventId }) -join ',') 'file-r-z,file-a-z,file-r-a' 'LF multiple-line event order'
  $prefixReplay = Resolve-MathSecrSelectionJournal -Path $lfPath
  Assert-Equal ($prefixReplay.EffectiveOccurrenceKeys -join ',') 'z-first' 'LF prefix effective selection'
  Assert-Equal $prefixReplay.PendingOccurrenceCount 1 'LF prefix pending count'

  Add-MathSecrSelectionJournalEvent -Path $lfPath -Event $events[3] | Out-Null
  $resumed = Resume-MathSecrSelectionJournal -Path $lfPath
  Assert-Equal $resumed.EventCount 4 'File resume event count'
  Assert-Equal $resumed.EffectiveOccurrenceCount 2 'File resume effective count'
  Assert-Equal $resumed.PendingOccurrenceCount 0 'File resume pending count'
  Assert-Equal ($resumed.EffectiveOccurrenceKeys -join ',') 'z-first,a-second' 'File resume must preserve source occurrence order'
  Assert-Equal ($resumed.EffectiveProblemIds -join ',') 'p91,p12' 'File resume must preserve problem order'

  # Imported CRLF files remain accepted. Build these bytes independently of
  # the journal serializer, then compare their replay with the LF file above.
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  foreach ($lineCount in @(1, 4)) {
    $crlfPath = Join-Path $Root ("file-read-crlf-$lineCount.jsonl")
    New-MathSecrSelectionJournal -Path $crlfPath | Out-Null
    $lines = @($events | Select-Object -First $lineCount | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress })
    [System.IO.File]::WriteAllText($crlfPath, (($lines -join "`r`n") + "`r`n"), $utf8)
    $read = Read-MathSecrSelectionJournal -Path $crlfPath
    Assert-Equal $read.EventCount $lineCount "CRLF $lineCount-line read event count"
    $replay = Resolve-MathSecrSelectionJournal -Path $crlfPath
    $expectedReplay = if ($lineCount -eq 1) { $singleReplay } else { $resumed }
    Assert-Equal $replay.ReplayDigest $expectedReplay.ReplayDigest "CRLF $lineCount-line replay equals LF replay"
  }

  # Well-formed final JSON without its terminating LF is still a truncated
  # journal; rejection must leave the original bytes unchanged.
  $truncatedPath = Join-Path $Root 'file-read-non-lf-tail.jsonl'
  $completeBytes = Read-Bytes $lfPath
  [System.IO.File]::WriteAllBytes($truncatedPath, [byte[]]$completeBytes[0..($completeBytes.Length - 2)])
  $truncatedHash = Get-MathSecrSelectionSha256 (Read-Bytes $truncatedPath)
  $truncatedRejected = $false
  try {
    Read-MathSecrSelectionJournal -Path $truncatedPath | Out-Null
  } catch {
    Assert-True ($_.Exception.Message.Contains('truncated/non-LF-terminated tail')) 'Non-LF tail rejection reason'
    $truncatedRejected = $true
  }
  Assert-True $truncatedRejected 'Non-LF final line must be rejected'
  Assert-Equal (Get-MathSecrSelectionSha256 (Read-Bytes $truncatedPath)) $truncatedHash 'Non-LF rejection preserves file bytes'
  Write-Host 'SelectionJournalFileRead PASS positive_cases=6 truncated_tail_rejections=1 lf_crlf_replay_equal=true source_order_preserved=true'
  return [pscustomobject]@{ Passed = 6; RedPassed = 1 }
}

$fixturePath = Join-Path $ProjectRoot 'mathsecr-paper-builder-kit\test-fixtures\selection-journal\cases.json'
$fixture = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Equal $fixture.schema_version 1 'Selection journal fixture schema'
Assert-Equal $fixture.contract.format 'utf8-lf-jsonl' 'Selection journal format'
Assert-Equal $fixture.contract.occurrence_identity 'occurrenceKey' 'Occurrence identity contract'

$cases = @($fixture.cases | Where-Object { $Case -eq 'All' -or $_.name -ceq $Case })
if ($cases.Count -eq 0) { throw "No selection-journal fixture matched case '$Case'." }

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mathsecr-selection-journal-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$passed = 0
$redPassed = 0
$fileReadPassed = 0
try {
  if ($Case -eq 'All') {
    $fileReads = Test-SelectionJournalFileReads -Root $tempRoot
    $fileReadPassed = $fileReads.Passed
    $redPassed += $fileReads.RedPassed
  }
  foreach ($fixtureCase in $cases) {
    $journalPath = Join-Path $tempRoot ($fixtureCase.name + '.jsonl')
    New-MathSecrSelectionJournal -Path $journalPath | Out-Null

    if ($fixtureCase.name -ceq 'CrashResume') {
      Append-Events -Path $journalPath -Events @($fixtureCase.prefixEvents)
      $prefixResult = Resolve-MathSecrSelectionJournal -Path $journalPath -MaxAttempts ([int]$fixtureCase.maxAttempts)
      Assert-Equal $prefixResult.EffectiveOccurrenceCount $fixtureCase.expected.prefixEffectiveOccurrenceCount 'Crash prefix effective count'
      Assert-Equal $prefixResult.PendingOccurrenceCount $fixtureCase.expected.prefixPendingOccurrenceCount 'Crash prefix pending count'

      Append-Events -Path $journalPath -Events @($fixtureCase.resumeEvents)
      $result = Resolve-MathSecrSelectionJournal -Path $journalPath -MaxAttempts ([int]$fixtureCase.maxAttempts)
      Assert-Equal $result.EffectiveOccurrenceCount $fixtureCase.expected.effectiveOccurrenceKeys.Count 'Crash resumed effective count'
      Assert-Equal $result.PendingOccurrenceCount $fixtureCase.expected.pendingOccurrenceCount 'Crash resumed pending count'
      Assert-Equal ($result.EffectiveOccurrenceKeys -join ',') ($fixtureCase.expected.effectiveOccurrenceKeys -join ',') 'Crash resumed occurrence order'
      Assert-Equal ($result.EffectiveProblemIds -join ',') ($fixtureCase.expected.effectiveProblemIds -join ',') 'Crash resumed problem order'
      Assert-Equal ([int]$result.EffectiveSelections[0].EffectiveAttempt) ([int]$fixtureCase.expected.effectiveAttempts[0]) 'Crash resumed effective attempt'

      $replays = @(
        (Resolve-MathSecrSelectionJournal -Path $journalPath -MaxAttempts 3),
        (Resolve-MathSecrSelectionJournal -Path $journalPath -MaxAttempts 3),
        (Resolve-MathSecrSelectionJournal -Path $journalPath -MaxAttempts 3)
      )
      Assert-Equal $replays[0].ReplayDigest $replays[1].ReplayDigest 'Replay digest 1/2'
      Assert-Equal $replays[1].ReplayDigest $replays[2].ReplayDigest 'Replay digest 2/3'
      $passed++
      continue
    }

    $rejectedProperty = $fixtureCase.expected.PSObject.Properties['rejected']
    if ($null -ne $rejectedProperty -and [bool]$rejectedProperty.Value) {
      $redEventProperty = $fixtureCase.PSObject.Properties['redEvent']
      $caught = $false
      try {
        if ($null -ne $redEventProperty) {
          Resolve-MathSecrSelectionJournal -Events @($redEventProperty.Value) | Out-Null
        } else {
          Append-Events -Path $journalPath -Events @($fixtureCase.events)
          Resolve-MathSecrSelectionJournal -Path $journalPath -MaxAttempts ([int]$fixtureCase.maxAttempts) | Out-Null
        }
      } catch {
        $caught = $true
        Assert-True ($_.Exception.Message.Contains([string]$fixtureCase.expected.errorContains)) "$($fixtureCase.name) error text"
      }
      Assert-True $caught "$($fixtureCase.name) must reject the intentional red case"
      $redPassed++
      continue
    }

    Append-Events -Path $journalPath -Events @($fixtureCase.events)
    $result = Resolve-MathSecrSelectionJournal -Path $journalPath -MaxAttempts ([int]$fixtureCase.maxAttempts)
    Assert-Equal $result.EffectiveOccurrenceCount $fixtureCase.expected.effectiveOccurrenceKeys.Count "$($fixtureCase.name) effective count"
    Assert-Equal ($result.EffectiveOccurrenceKeys -join ',') ($fixtureCase.expected.effectiveOccurrenceKeys -join ',') "$($fixtureCase.name) occurrence order"
    Assert-Equal ($result.EffectiveProblemIds -join ',') ($fixtureCase.expected.effectiveProblemIds -join ',') "$($fixtureCase.name) problem order"
    $actualAttempts = @($result.EffectiveSelections | ForEach-Object { [int]$_.EffectiveAttempt })
    $expectedAttempts = @($fixtureCase.expected.effectiveAttempts | ForEach-Object { [int]$_ })
    Assert-Equal ($actualAttempts -join ',') ($expectedAttempts -join ',') "$($fixtureCase.name) effective attempts"
    Assert-Equal $result.IgnoredEventCount $fixtureCase.expected.ignoredEventCount "$($fixtureCase.name) ignored count"
    $ignoredReasonsProperty = $fixtureCase.expected.PSObject.Properties['ignoredReasons']
    if ($null -ne $ignoredReasonsProperty) {
      $actualIgnoredReasons = @($result.IgnoredEvents | ForEach-Object { [string]$_.Reason })
      Assert-Equal ($actualIgnoredReasons -join ',') ($ignoredReasonsProperty.Value -join ',') "$($fixtureCase.name) ignored reasons"
    }
    Assert-Equal $result.PendingOccurrenceCount $fixtureCase.expected.pendingOccurrenceCount "$($fixtureCase.name) pending count"
    $passed++
  }

  # Appending must preserve every prior byte and reject duplicate event IDs
  # before mutating the file.
  $appendPath = Join-Path $tempRoot 'append-preservation.jsonl'
  New-MathSecrSelectionJournal -Path $appendPath | Out-Null
  $eventA = [ordered]@{ schemaVersion = 1; eventId = 'append-r1'; eventType = 'selection_requested'; occurrenceKey = 'append-o'; problemId = 'append-p'; attempt = 1 }
  Add-MathSecrSelectionJournalEvent -Path $appendPath -Event $eventA | Out-Null
  $prefixBytes = Read-Bytes $appendPath
  $eventB = [ordered]@{ schemaVersion = 1; eventId = 'append-a1'; eventType = 'selection_ack'; occurrenceKey = 'append-o'; problemId = 'append-p'; attempt = 1; requestEventId = 'append-r1' }
  Add-MathSecrSelectionJournalEvent -Path $appendPath -Event $eventB | Out-Null
  $afterAppendBytes = Read-Bytes $appendPath
  Assert-PrefixBytes -Prefix $prefixBytes -Actual $afterAppendBytes -Message 'Append-only prefix'
  $beforeDuplicateHash = Get-MathSecrSelectionSha256 $afterAppendBytes
  $duplicateCaught = $false
  try {
    Add-MathSecrSelectionJournalEvent -Path $appendPath -Event $eventB | Out-Null
  } catch {
    $duplicateCaught = $true
  }
  Assert-True $duplicateCaught 'Duplicate eventId must be rejected'
  Assert-Equal (Get-MathSecrSelectionSha256 (Read-Bytes $appendPath)) $beforeDuplicateHash 'Duplicate rejection byte preservation'
  $idempotentResult = Add-MathSecrSelectionJournalEvent -Path $appendPath -Event $eventB -Idempotent
  Assert-Equal $idempotentResult.eventId 'append-a1' 'Idempotent duplicate returns existing event'
  Assert-Equal (Get-MathSecrSelectionSha256 (Read-Bytes $appendPath)) $beforeDuplicateHash 'Idempotent duplicate byte preservation'
  $idempotentMutationCaught = $false
  try {
    Add-MathSecrSelectionJournalEvent -Path $appendPath -Event ([ordered]@{ schemaVersion = 1; eventId = 'append-a1'; eventType = 'selection_ack'; occurrenceKey = 'append-o'; problemId = 'different-problem'; attempt = 1; requestEventId = 'append-r1' }) -Idempotent | Out-Null
  } catch {
    $idempotentMutationCaught = $true
  }
  Assert-True $idempotentMutationCaught 'Idempotent same-ID payload mutation must be rejected'

  # A malformed final JSONL line is rejected by default, and only returned as
  # a prefix plus explicit quarantine metadata when a quarantine path is given.
  $corruptPath = Join-Path $tempRoot 'corrupt-tail.jsonl'
  New-MathSecrSelectionJournal -Path $corruptPath | Out-Null
  Add-MathSecrSelectionJournalEvent -Path $corruptPath -Event $eventA | Out-Null
  $validCorruptPrefix = Read-Bytes $corruptPath
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($corruptPath, '{"schemaVersion":1,"eventId":"tail-bad"' + "`n", $utf8)
  $corruptRejected = $false
  try {
    Read-MathSecrSelectionJournal -Path $corruptPath | Out-Null
  } catch {
    $corruptRejected = $true
  }
  Assert-True $corruptRejected 'Corrupt final line must be rejected without quarantine'
  $quarantinePath = Join-Path $tempRoot 'quarantine\tail.jsonl'
  $corruptHashBeforeQuarantine = Get-MathSecrSelectionSha256 (Read-Bytes $corruptPath)
  $quarantineResult = Read-MathSecrSelectionJournal -Path $corruptPath -QuarantineCorruptTailPath $quarantinePath
  Assert-True $quarantineResult.TailQuarantined 'Explicit quarantine must be reported'
  Assert-True (Test-Path -LiteralPath $quarantinePath -PathType Leaf) 'Explicit quarantine artifact must exist'
  $expectedTailText = '{"schemaVersion":1,"eventId":"tail-bad"' + "`n"
  $expectedTailBytes = $utf8.GetBytes($expectedTailText)
  $actualTailBytes = Read-Bytes $quarantinePath
  Assert-Equal $actualTailBytes.Length $expectedTailBytes.Length 'Quarantined tail byte length'
  for ($tailIndex = 0; $tailIndex -lt $expectedTailBytes.Length; $tailIndex++) {
    if ($actualTailBytes[$tailIndex] -ne $expectedTailBytes[$tailIndex]) {
      throw "Quarantined tail byte mismatch at offset $tailIndex"
    }
  }
  $actualTailText = (Get-MathSecrSelectionUtf8).GetString($actualTailBytes)
  Assert-Equal $actualTailText $expectedTailText 'Quarantined tail exact content'
  $corruptHashAfterQuarantine = Get-MathSecrSelectionSha256 (Read-Bytes $corruptPath)
  Assert-Equal $corruptHashAfterQuarantine $corruptHashBeforeQuarantine 'Corrupt source remains unchanged'
  Assert-PrefixBytes -Prefix $validCorruptPrefix -Actual (Read-Bytes $corruptPath) -Message 'Corrupt source prefix remains unchanged'
  $redPassed += 2

  Write-Host "SelectionJournal PASS cases=$passed file_read_cases=$fileReadPassed intentional_red_cases=$redPassed append_prefix_preserved=true duplicate_event_rejected=true corrupt_tail_rejected=true explicit_quarantine=true three_replays_equal=true"
} finally {
  $resolvedTempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
  $resolvedTestRoot = [System.IO.Path]::GetFullPath($tempRoot).TrimEnd('\', '/')
  $expectedPrefix = Join-Path $resolvedTempBase 'mathsecr-selection-journal-'
  if (-not $resolvedTestRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
      -not [string]::Equals((Split-Path -Parent $resolvedTestRoot), $resolvedTempBase, [System.StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $resolvedTestRoot) -cnotmatch '^mathsecr-selection-journal-[0-9a-f]{32}$') {
    throw "Refusing selection-journal cleanup outside its owned system-temp prefix: $resolvedTestRoot"
  }
  if (Test-Path -LiteralPath $resolvedTestRoot) {
    $tempItem = Get-Item -LiteralPath $resolvedTestRoot -Force
    Assert-True ($tempItem.PSIsContainer -and ($tempItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) 'Test cleanup root must be a real directory'
    $reparseItems = @(Get-ChildItem -LiteralPath $resolvedTestRoot -Force -Recurse | Where-Object {
      ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    })
    Assert-True ($reparseItems.Count -eq 0) 'Test cleanup must not cross a reparse point'
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
  }
}
