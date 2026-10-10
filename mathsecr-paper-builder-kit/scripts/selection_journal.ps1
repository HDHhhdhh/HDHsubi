# Selection journal contract for offline MathSecr selection orchestration.
#
# The journal is a UTF-8, LF-terminated JSONL file.  Existing bytes are never
# rewritten: appends open the file in append mode after validating the current
# prefix.  Replay is deliberately deterministic and treats occurrenceKey as
# the identity of a selected occurrence (problemId is descriptive and may be
# shared by more than one occurrence).

Set-StrictMode -Version Latest

$script:MathSecrSelectionJournalSchemaVersion = 1

function Get-MathSecrSelectionProperty {
  param(
    [AllowNull()][object]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Value) {
    return $null
  }
  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($key in @($Value.Keys)) {
      if ([string]$key -ceq $Name) {
        return $Value[$key]
      }
    }
    return $null
  }
  foreach ($property in @($Value.PSObject.Properties)) {
    if ([string]$property.Name -ceq $Name) {
      return $property.Value
    }
  }
  return $null
}

function Test-MathSecrSelectionPropertyPresent {
  param(
    [AllowNull()][object]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Value) {
    return $false
  }
  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($key in @($Value.Keys)) {
      if ([string]$key -ceq $Name) {
        return $true
      }
    }
    return $false
  }
  foreach ($property in @($Value.PSObject.Properties)) {
    if ([string]$property.Name -ceq $Name) {
      return $true
    }
  }
  return $false
}

function ConvertTo-MathSecrSelectionEventType {
  param([AllowNull()][object]$Value)

  $canonicalValues = @(
    'selection_requested',
    'selection_ack',
    'selection_timeout',
    'selection_retry'
  )
  if ($Value -isnot [string] -or -not ($canonicalValues -ccontains [string]$Value)) {
    throw "Unsupported canonical selection journal eventType '$Value'."
  }
  return [string]$Value
}

function ConvertTo-MathSecrSelectionInt {
  param(
    [AllowNull()][object]$Value,
    [Parameter(Mandatory = $true)][string]$Path
  )

  if ($Value -is [bool]) {
    throw "$Path must be an integer greater than zero."
  }
  $numericTypes = @(
    [System.TypeCode]::SByte, [System.TypeCode]::Byte,
    [System.TypeCode]::Int16, [System.TypeCode]::UInt16,
    [System.TypeCode]::Int32, [System.TypeCode]::UInt32,
    [System.TypeCode]::Int64, [System.TypeCode]::UInt64
  )
  if ($null -eq $Value -or [System.Type]::GetTypeCode($Value.GetType()) -notin $numericTypes) {
    throw "$Path must be an integer greater than zero."
  }
  $number = [long]$Value
  if ($number -le 0 -or $number -gt [int]::MaxValue) {
    throw "$Path must be an integer greater than zero."
  }
  return [int]$number
}

function Assert-MathSecrSelectionString {
  param(
    [AllowNull()][object]$Value,
    [Parameter(Mandatory = $true)][string]$Path
  )

  if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
    throw "$Path must be a non-empty string."
  }
  return [string]$Value
}

function ConvertTo-MathSecrSelectionCanonicalEvent {
  param(
    [Parameter(Mandatory = $true)][AllowNull()][object]$Event,
    [switch]$AllowGeneratedEventId
  )

  if ($null -eq $Event -or $Event -is [string] -or $Event -is [System.Array]) {
    throw 'Selection journal event must be a JSON object.'
  }

  if (-not (Test-MathSecrSelectionPropertyPresent $Event 'schemaVersion')) {
    throw 'schemaVersion is required.'
  }
  $schemaVersion = Get-MathSecrSelectionProperty $Event 'schemaVersion'
  if ($schemaVersion -is [bool] -or $schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) {
    throw 'schemaVersion must be integer 1.'
  }
  if ([int]$schemaVersion -ne $script:MathSecrSelectionJournalSchemaVersion) {
    throw "Unsupported selection journal schemaVersion '$schemaVersion'."
  }

  $eventId = Get-MathSecrSelectionProperty $Event 'eventId'
  if ($null -eq $eventId -or [string]::IsNullOrWhiteSpace([string]$eventId)) {
    if ($AllowGeneratedEventId) {
      $eventId = [Guid]::NewGuid().ToString('N')
    } else {
      throw 'eventId must be a non-empty string.'
    }
  }
  $eventId = Assert-MathSecrSelectionString $eventId 'eventId'

  if (-not (Test-MathSecrSelectionPropertyPresent $Event 'eventType')) {
    throw 'eventType is required.'
  }
  $eventTypeValue = Get-MathSecrSelectionProperty $Event 'eventType'
  $eventType = ConvertTo-MathSecrSelectionEventType $eventTypeValue
  $occurrenceKey = Assert-MathSecrSelectionString (Get-MathSecrSelectionProperty $Event 'occurrenceKey') 'occurrenceKey'
  $problemId = Assert-MathSecrSelectionString (Get-MathSecrSelectionProperty $Event 'problemId') 'problemId'
  $attempt = ConvertTo-MathSecrSelectionInt (Get-MathSecrSelectionProperty $Event 'attempt') 'attempt'

  $allowed = @(
    'schemaVersion', 'eventId', 'eventType',
    'occurrenceKey', 'problemId', 'attempt', 'requestEventId',
    'retryOfEventId', 'recordedAt', 'reason', 'metadata'
  )
  $actualPropertyNames = @()
  if ($Event -is [System.Collections.IDictionary]) {
    $actualPropertyNames = @($Event.Keys | ForEach-Object { [string]$_ })
  } else {
    $actualPropertyNames = @($Event.PSObject.Properties.Name)
  }
  foreach ($name in $actualPropertyNames) {
    if (-not ($allowed -ccontains $name)) {
      throw "Selection journal event property '$name' is not allowed."
    }
  }

  $canonical = [ordered]@{
    schemaVersion = $script:MathSecrSelectionJournalSchemaVersion
    eventId = $eventId
    eventType = $eventType
    occurrenceKey = $occurrenceKey
    problemId = $problemId
    attempt = $attempt
  }

  foreach ($optionalName in @('requestEventId', 'retryOfEventId', 'recordedAt', 'reason')) {
    if (Test-MathSecrSelectionPropertyPresent $Event $optionalName) {
      $optionalValue = Get-MathSecrSelectionProperty $Event $optionalName
      if ($null -ne $optionalValue) {
        $canonical[$optionalName] = Assert-MathSecrSelectionString $optionalValue $optionalName
      }
    }
  }
  if (Test-MathSecrSelectionPropertyPresent $Event 'metadata') {
    $canonical.metadata = Get-MathSecrSelectionProperty $Event 'metadata'
  }

  return [pscustomobject]$canonical
}

function Get-MathSecrSelectionUtf8 {
  return New-Object System.Text.UTF8Encoding($false, $true)
}

function Get-MathSecrSelectionSha256 {
  param([byte[]]$Bytes)

  $sha = New-Object System.Security.Cryptography.SHA256Managed
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToUpperInvariant()
  } finally {
    $sha.Dispose()
  }
}

function ConvertTo-MathSecrSelectionJsonLine {
  param([Parameter(Mandatory = $true)]$Event)
  return ($Event | ConvertTo-Json -Depth 20 -Compress)
}

function New-MathSecrSelectionJournal {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$Force
  )

  $resolvedPath = [System.IO.Path]::GetFullPath($Path)
  $parent = Split-Path -Parent $resolvedPath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
    if (-not $Force -and (Get-Item -LiteralPath $resolvedPath).Length -gt 0) {
      throw "Selection journal already contains bytes: $resolvedPath"
    }
    if ($Force) {
      $stream = [System.IO.File]::Open($resolvedPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
      try { $stream.SetLength(0); $stream.Flush($true) } finally { $stream.Dispose() }
    }
  } else {
    $stream = [System.IO.File]::Open($resolvedPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try { $stream.Flush($true) } finally { $stream.Dispose() }
  }
  return Read-MathSecrSelectionJournal -Path $resolvedPath
}

function Read-MathSecrSelectionJournal {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Alias('QuarantineTailPath', 'QuarantinePath')][string]$QuarantineCorruptTailPath
  )

  $resolvedPath = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
    throw "Selection journal does not exist: $resolvedPath"
  }
  $bytes = [System.IO.File]::ReadAllBytes($resolvedPath)
  $hash = Get-MathSecrSelectionSha256 $bytes
  $utf8 = Get-MathSecrSelectionUtf8
  try {
    $text = $utf8.GetString($bytes)
  } catch {
    throw "Selection journal contains invalid UTF-8: $resolvedPath"
  }

  if ($bytes.Length -eq 0) {
    return [pscustomobject]@{
      SchemaVersion = $script:MathSecrSelectionJournalSchemaVersion
      Path = $resolvedPath
      Events = @()
      EventCount = 0
      ByteLength = 0
      Sha256 = $hash
      TailQuarantined = $false
      QuarantinePath = $null
    }
  }
  if ($bytes[$bytes.Length - 1] -ne [byte][char]"`n") {
    throw "Selection journal has a truncated/non-LF-terminated tail: $resolvedPath"
  }

  # Split every LF and retain the terminal empty entry on both PS 5.1 and 7.
  # A negative split count means right-to-left limited splitting in PS 7.
  $rawLines = $text -split "`n"
  $events = [System.Collections.Generic.List[object]]::new()
  $eventIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
  $lastContentIndex = $rawLines.Count - 2
  $charOffset = 0
  for ($index = 0; $index -le $lastContentIndex; $index++) {
    $lineWithCr = [string]$rawLines[$index]
    $line = $lineWithCr.TrimEnd("`r")
    $isLastContentLine = $index -eq $lastContentIndex
    if ([string]::IsNullOrWhiteSpace($line)) {
      if ($isLastContentLine -and $null -ne $QuarantineCorruptTailPath) {
        $tailText = $text.Substring($charOffset)
        $quarantineFull = [System.IO.Path]::GetFullPath($QuarantineCorruptTailPath)
        if (Test-Path -LiteralPath $quarantineFull) { throw "Quarantine path already exists: $quarantineFull" }
        New-Item -ItemType Directory -Path (Split-Path -Parent $quarantineFull) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($quarantineFull, $utf8.GetBytes($tailText))
        return [pscustomobject]@{
          SchemaVersion = $script:MathSecrSelectionJournalSchemaVersion
          Path = $resolvedPath
          Events = @($events)
          EventCount = $events.Count
          ByteLength = $bytes.Length
          Sha256 = $hash
          TailQuarantined = $true
          QuarantinePath = $quarantineFull
          CorruptTailReason = 'blank-line'
        }
      }
      throw "Selection journal contains a blank JSONL line at line $($index + 1)."
    }

    $decoded = $null
    try {
      $decoded = $line | ConvertFrom-Json
      $canonical = ConvertTo-MathSecrSelectionCanonicalEvent -Event $decoded
      if (-not $eventIds.Add([string]$canonical.eventId)) {
        throw "Duplicate eventId '$($canonical.eventId)'."
      }
      $events.Add($canonical)
    } catch {
      if ($isLastContentLine -and $null -ne $QuarantineCorruptTailPath) {
        $tailText = $text.Substring($charOffset)
        $quarantineFull = [System.IO.Path]::GetFullPath($QuarantineCorruptTailPath)
        if (Test-Path -LiteralPath $quarantineFull) { throw "Quarantine path already exists: $quarantineFull" }
        New-Item -ItemType Directory -Path (Split-Path -Parent $quarantineFull) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($quarantineFull, $utf8.GetBytes($tailText))
        return [pscustomobject]@{
          SchemaVersion = $script:MathSecrSelectionJournalSchemaVersion
          Path = $resolvedPath
          Events = @($events)
          EventCount = $events.Count
          ByteLength = $bytes.Length
          Sha256 = $hash
          TailQuarantined = $true
          QuarantinePath = $quarantineFull
          CorruptTailReason = $_.Exception.Message
        }
      }
      throw "Selection journal rejected line $($index + 1): $($_.Exception.Message)"
    }
    # Account for the LF which was removed by -split.  The source text is
    # retained byte-for-byte; this offset is used only to copy an explicit
    # quarantine tail.
    $charOffset += $lineWithCr.Length + 1
  }

  return [pscustomobject]@{
    SchemaVersion = $script:MathSecrSelectionJournalSchemaVersion
    Path = $resolvedPath
    Events = @($events)
    EventCount = $events.Count
    ByteLength = $bytes.Length
    Sha256 = $hash
    TailQuarantined = $false
    QuarantinePath = $null
  }
}

function Add-MathSecrSelectionJournalEvent {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowNull()][object]$Event,
    [string]$EventId,
    [string]$EventType,
    [string]$OccurrenceKey,
    [string]$ProblemId,
    [int]$Attempt = 1,
    [string]$RequestEventId,
    [string]$RetryOfEventId,
    [string]$RecordedAt,
    [string]$Reason,
    [switch]$Idempotent
  )

  $resolvedPath = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
    New-MathSecrSelectionJournal -Path $resolvedPath | Out-Null
  }
  $before = Read-MathSecrSelectionJournal -Path $resolvedPath

  if ($null -eq $Event) {
    $built = [ordered]@{
      schemaVersion = $script:MathSecrSelectionJournalSchemaVersion
      eventId = $EventId
      eventType = $EventType
      occurrenceKey = $OccurrenceKey
      problemId = $ProblemId
      attempt = $Attempt
    }
    foreach ($pair in @(
      @{ Name = 'requestEventId'; Value = $RequestEventId },
      @{ Name = 'retryOfEventId'; Value = $RetryOfEventId },
      @{ Name = 'recordedAt'; Value = $RecordedAt },
      @{ Name = 'reason'; Value = $Reason }
    )) {
      # In Windows PowerShell an unbound [string] parameter is `''`, not
      # `$null`; omit those defaults so request/timeout events do not acquire
      # invalid empty optional IDs.
      if ($null -ne $pair.Value -and -not [string]::IsNullOrWhiteSpace([string]$pair.Value)) {
        $built[$pair.Name] = $pair.Value
      }
    }
    $Event = $built
  }
  $canonical = ConvertTo-MathSecrSelectionCanonicalEvent -Event $Event -AllowGeneratedEventId
  foreach ($existing in @($before.Events)) {
    if ([string]$existing.eventId -ceq [string]$canonical.eventId) {
      if ($Idempotent) {
        $existingJson = ConvertTo-MathSecrSelectionJsonLine $existing
        $candidateJson = ConvertTo-MathSecrSelectionJsonLine $canonical
        if ($existingJson -ceq $candidateJson) {
          # A crash-safe caller can replay its last append without creating a
          # second event.  A same-ID/different-payload mutation remains a
          # hard rejection below.
          return $existing
        }
      }
      throw "Duplicate eventId '$($canonical.eventId)' cannot be appended."
    }
  }

  $line = (ConvertTo-MathSecrSelectionJsonLine $canonical) + "`n"
  $utf8 = Get-MathSecrSelectionUtf8
  $appendBytes = $utf8.GetBytes($line)
  $stream = [System.IO.File]::Open($resolvedPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  try {
    # A second length/hash check while holding the exclusive handle prevents a
    # concurrent writer from silently causing a lost append.
    $currentLength = [int]$stream.Length
    if ($currentLength -ne [int]$before.ByteLength) {
      throw 'Selection journal changed while preparing append; retry from a fresh read.'
    }
    $currentBytes = New-Object byte[] $currentLength
    $stream.Position = 0
    $readTotal = 0
    while ($readTotal -lt $currentLength) {
      $readNow = $stream.Read($currentBytes, $readTotal, $currentLength - $readTotal)
      if ($readNow -le 0) { break }
      $readTotal += $readNow
    }
    if ((Get-MathSecrSelectionSha256 $currentBytes) -cne [string]$before.Sha256) {
      throw 'Selection journal changed while preparing append; retry from a fresh read.'
    }
    $stream.Position = $stream.Length
    $stream.Write($appendBytes, 0, $appendBytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }

  return $canonical
}

function Resolve-MathSecrSelectionJournal {
  [CmdletBinding()]
  param(
    [string]$Path,
    [AllowNull()][object[]]$Events,
    [ValidateRange(1, 100)][int]$MaxAttempts = 3,
    [switch]$AllowInvalid
  )

  if ($PSBoundParameters.ContainsKey('Path') -and $PSBoundParameters.ContainsKey('Events')) {
    throw 'Specify either Path or Events, not both.'
  }
  if ($PSBoundParameters.ContainsKey('Path')) {
    $read = Read-MathSecrSelectionJournal -Path $Path
    $Events = @($read.Events)
    $sourcePath = $read.Path
    $sourceHash = $read.Sha256
  } elseif (-not $PSBoundParameters.ContainsKey('Events')) {
    throw 'Resolve requires Path or Events.'
  } else {
    $sourcePath = $null
    $sourceHash = $null
  }

  $canonicalEvents = [System.Collections.Generic.List[object]]::new()
  $eventIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
  foreach ($inputEvent in @($Events)) {
    $canonicalEvent = ConvertTo-MathSecrSelectionCanonicalEvent -Event $inputEvent
    if (-not $eventIds.Add([string]$canonicalEvent.eventId)) {
      throw "Duplicate eventId '$($canonicalEvent.eventId)'."
    }
    $canonicalEvents.Add($canonicalEvent)
  }

  # occurrenceKey is an opaque, case-sensitive identity.  Do not use a
  # PowerShell hashtable here: its default comparer is case-insensitive and
  # would merge distinct keys such as `occ` and `OCC` during replay.
  $states = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
  $stateOrder = [System.Collections.Generic.List[string]]::new()
  $ignored = [System.Collections.Generic.List[object]]::new()
  $semanticErrors = [System.Collections.Generic.List[string]]::new()

  function Add-SelectionSemanticError {
    param([string]$Message)
    $semanticErrors.Add($Message)
  }

  foreach ($event in @($canonicalEvents)) {
    $key = [string]$event.occurrenceKey
    if (-not $states.ContainsKey($key)) {
      $states[$key] = @{
        OccurrenceKey = $key
        ProblemId = [string]$event.problemId
        Requests = @{}
        Timeouts = @{}
        RetryEvents = @{}
        NextAttempt = $null
        Effective = $null
      }
      $stateOrder.Add($key)
    }
    $state = $states[$key]
    if ([string]$state.ProblemId -cne [string]$event.problemId) {
      # occurrenceKey is stable identity, but problemId remains an immutable
      # consistency field.  A post-ACK event with a different problemId is a
      # corrupt/mixed stream, not an ignorable timer race.
      Add-SelectionSemanticError "Occurrence '$key' changed problemId from '$($state.ProblemId)' to '$($event.problemId)'."
      continue
    }
    if ($null -ne $state.Effective) {
      $ignoredReason = switch ([string]$event.eventType) {
        'selection_requested' { 'request_after_effective_ack'; break }
        'selection_timeout' { 'timeout_after_effective_ack'; break }
        'selection_retry' { 'retry_after_effective_ack'; break }
        'selection_ack' { 'ack_after_effective_ack'; break }
        default { 'event_after_effective_ack'; break }
      }
      # Once an occurrence has an effective ACK, every later event for that
      # occurrence is a network/timer race observation.  It is retained as an
      # ignored receipt and cannot create a new request, timeout, retry, or
      # effective selection.
      $ignored.Add([pscustomobject]@{
        EventId = [string]$event.eventId
        EventType = [string]$event.eventType
        OccurrenceKey = $key
        ProblemId = [string]$event.problemId
        Attempt = [int]$event.attempt
        Reason = $ignoredReason
      })
      continue
    }

    switch ([string]$event.eventType) {
      'selection_requested' {
        $attempt = [int]$event.attempt
        if ($state.Requests.ContainsKey($attempt)) {
          Add-SelectionSemanticError "Occurrence '$key' has duplicate request attempt $attempt."
          continue
        }
        if ($attempt -gt $MaxAttempts) {
          Add-SelectionSemanticError "Occurrence '$key' exceeded MaxAttempts=$MaxAttempts at request attempt $attempt."
          continue
        }
        if ($attempt -eq 1) {
          if ($state.Requests.Count -ne 0) {
            Add-SelectionSemanticError "Occurrence '$key' cannot restart at request attempt 1."
            continue
          }
        } else {
          if ($null -eq $state.NextAttempt -or [int]$state.NextAttempt -ne $attempt) {
            Add-SelectionSemanticError "Occurrence '$key' request attempt $attempt lacks the preceding timeout/retry pair."
            continue
          }
          $state.NextAttempt = $null
        }
        $state.Requests[$attempt] = $event
      }
      'selection_timeout' {
        $attempt = [int]$event.attempt
        if (-not $state.Requests.ContainsKey($attempt)) {
          Add-SelectionSemanticError "Occurrence '$key' timeout attempt $attempt has no request."
          continue
        }
        if (Test-MathSecrSelectionPropertyPresent $event 'requestEventId') {
          if ([string]$event.requestEventId -cne [string]$state.Requests[$attempt].eventId) {
            Add-SelectionSemanticError "Occurrence '$key' timeout attempt $attempt references the wrong request event."
            continue
          }
        }
        if ($state.Timeouts.ContainsKey($attempt)) {
          Add-SelectionSemanticError "Occurrence '$key' has duplicate timeout attempt $attempt."
          continue
        }
        $state.Timeouts[$attempt] = $event
      }
      'selection_retry' {
        $attempt = [int]$event.attempt
        if ($attempt -gt $MaxAttempts) {
          Add-SelectionSemanticError "Occurrence '$key' exceeded MaxAttempts=$MaxAttempts at retry attempt $attempt."
          continue
        }
        $previousAttempt = $attempt - 1
        if (-not $state.Timeouts.ContainsKey($previousAttempt)) {
          Add-SelectionSemanticError "Occurrence '$key' retry attempt $attempt lacks timeout for attempt $previousAttempt."
          continue
        }
        if ($state.Requests.ContainsKey($attempt) -or $null -ne $state.NextAttempt) {
          Add-SelectionSemanticError "Occurrence '$key' has duplicate/out-of-order retry attempt $attempt."
          continue
        }
        if (Test-MathSecrSelectionPropertyPresent $event 'retryOfEventId') {
          if ([string]$event.retryOfEventId -cne [string]$state.Timeouts[$previousAttempt].eventId) {
            Add-SelectionSemanticError "Occurrence '$key' retry attempt $attempt does not reference timeout event $($state.Timeouts[$previousAttempt].eventId)."
            continue
          }
        }
        $state.NextAttempt = $attempt
        $state.RetryEvents[$attempt] = $event
      }
      'selection_ack' {
        $attempt = [int]$event.attempt
        if (-not $state.Requests.ContainsKey($attempt)) {
          Add-SelectionSemanticError "Occurrence '$key' ACK attempt $attempt has no request."
          continue
        }
        if (Test-MathSecrSelectionPropertyPresent $event 'requestEventId') {
          if ([string]$event.requestEventId -cne [string]$state.Requests[$attempt].eventId) {
            Add-SelectionSemanticError "Occurrence '$key' ACK attempt $attempt references the wrong request event."
            continue
          }
        }
        $state.Effective = [ordered]@{
          OccurrenceKey = $key
          ProblemId = [string]$state.ProblemId
          EffectiveAttempt = $attempt
          RequestEventId = [string]$state.Requests[$attempt].eventId
          AckEventId = [string]$event.eventId
        }
      }
      default {
        Add-SelectionSemanticError "Unsupported canonical event type '$($event.eventType)'."
      }
    }
  }

  if ($semanticErrors.Count -gt 0 -and -not $AllowInvalid) {
    throw "Selection journal replay rejected: $($semanticErrors -join ' | ')"
  }

  $effective = [System.Collections.Generic.List[object]]::new()
  $pending = [System.Collections.Generic.List[object]]::new()
  foreach ($key in @($stateOrder)) {
    $state = $states[$key]
    if ($null -ne $state.Effective) {
      $effective.Add([pscustomobject]$state.Effective)
    } else {
      $pending.Add([pscustomobject]@{
        OccurrenceKey = $key
        ProblemId = [string]$state.ProblemId
        LastAttempt = if ($state.Requests.Count -eq 0) { 0 } else { [int](($state.Requests.Keys | Sort-Object -Descending | Select-Object -First 1)) }
        AwaitingRetryRequest = $null -ne $state.NextAttempt
      })
    }
  }

  $effectiveOccurrenceKeys = @($effective | ForEach-Object { [string]$_.OccurrenceKey })
  $effectiveProblemIds = @($effective | ForEach-Object { [string]$_.ProblemId })
  $digestState = [ordered]@{
    schemaVersion = $script:MathSecrSelectionJournalSchemaVersion
    effective = @($effective)
    pending = @($pending)
    ignored = @($ignored)
    errors = @($semanticErrors)
  }
  $digestText = ConvertTo-MathSecrSelectionJsonLine ([pscustomobject]$digestState)
  $digest = Get-MathSecrSelectionSha256 ((Get-MathSecrSelectionUtf8).GetBytes($digestText))

  return [pscustomobject]@{
    SchemaVersion = $script:MathSecrSelectionJournalSchemaVersion
    Path = $sourcePath
    SourceSha256 = $sourceHash
    MaxAttempts = $MaxAttempts
    EventCount = $canonicalEvents.Count
    Status = if ($semanticErrors.Count -gt 0) { 'rejected' } else { 'resolved' }
    Valid = $semanticErrors.Count -eq 0
    Errors = @($semanticErrors)
    EffectiveSelections = @($effective)
    EffectiveOccurrenceKeys = $effectiveOccurrenceKeys
    EffectiveProblemIds = $effectiveProblemIds
    EffectiveOccurrenceCount = $effective.Count
    PendingSelections = @($pending)
    PendingOccurrenceCount = $pending.Count
    IgnoredEvents = @($ignored)
    IgnoredEventCount = $ignored.Count
    ReplayDigest = $digest
  }
}

function Append-MathSecrSelectionEvent {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowNull()][object]$Event,
    [string]$EventId,
    [string]$EventType,
    [string]$OccurrenceKey,
    [string]$ProblemId,
    [int]$Attempt = 1,
    [string]$RequestEventId,
    [string]$RetryOfEventId,
    [string]$RecordedAt,
    [string]$Reason,
    [switch]$Idempotent
  )
  return Add-MathSecrSelectionJournalEvent @PSBoundParameters
}

function Get-MathSecrSelectionJournal {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Alias('QuarantineTailPath', 'QuarantinePath')][string]$QuarantineCorruptTailPath
  )
  return Read-MathSecrSelectionJournal @PSBoundParameters
}

function Replay-MathSecrSelectionJournal {
  [CmdletBinding()]
  param(
    [string]$Path,
    [AllowNull()][object[]]$Events,
    [ValidateRange(1, 100)][int]$MaxAttempts = 3,
    [switch]$AllowInvalid
  )
  return Resolve-MathSecrSelectionJournal @PSBoundParameters
}

function Invoke-MathSecrSelectionJournal {
  [CmdletBinding()]
  param(
    [string]$Path,
    [AllowNull()][object[]]$Events,
    [ValidateRange(1, 100)][int]$MaxAttempts = 3,
    [switch]$AllowInvalid
  )
  return Resolve-MathSecrSelectionJournal @PSBoundParameters
}

function Resume-MathSecrSelectionJournal {
  [CmdletBinding()]
  param(
    [string]$Path,
    [AllowNull()][object[]]$Events,
    [ValidateRange(1, 100)][int]$MaxAttempts = 3,
    [switch]$AllowInvalid
  )
  # Resume is intentionally a pure replay.  The caller appends any recovered
  # suffix first (using -Idempotent when re-emitting an acknowledged append),
  # then resolves the complete immutable event prefix + suffix.
  return Resolve-MathSecrSelectionJournal @PSBoundParameters
}
