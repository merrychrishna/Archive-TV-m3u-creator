#requires -Version 5.1
<#
ARCHIVE TV SOURCE LIBRARY MANAGER - FRESH V4.8
- Starts with empty manager state unless a v4 state file already exists.
- Archive.org import options:
    1 Scraping API (recommended; cursor pagination)
    2 Advanced Search API (page pagination)
    3 Paste an Archive.org search-results URL (parsed and sent to Scraping API)
    4 Custom HTTPS endpoint returning a complete M3U
- Search URL auto-discovery tests plausible query interpretations using independent Advanced Search count-only requests.
- The /details/movies category URL is treated as mediatype:movies, not collection:movies.
- Full-search source M3Us are preserved separately from operational playlists.
- Programme and Commercial sources, collections and profiles are separate.
- Does not alter Docker, existing master playlists, or existing channel playlists.
- Never overwrites an existing M3U; new outputs receive unique names.
- Refuses to repeat an already-registered identical source query/type.
- Full-source imports have no maximum result/page cap; Scraping API cursor pagination runs to completion.
- Optional expected counts default to zero and are verification only.
- Parses Archive.org file extensions without treating metadata names as filesystem paths.
- Autosaves resumable Scrape API checkpoints and JSONL journals on D:.
- Resumes interrupted queries; final short page without cursor is treated as terminal.
- Aggregates no-video warnings on screen while retaining per-item details in the log.
- Blank unattended menu input exits cleanly.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProjectRoot = 'D:\Archive-TV\Archive_TV_System'
$ArchiveRoot = Join-Path $ProjectRoot 'archived_large_M3Us'
$ProgrammeSources = Join-Path $ArchiveRoot 'programme-sources'
$CommercialSources = Join-Path $ArchiveRoot 'commercial-sources'
$CheckpointRoot = Join-Path $ArchiveRoot 'checkpoints'
$PlaylistRoot = Join-Path $ProjectRoot 'channel-playlists'
$CommercialPlaylistRoot = Join-Path $ProjectRoot 'commercial-playlists'
$StateRoot = Join-Path $ProjectRoot 'system\source-library-manager-v4'
$StateFile = Join-Path $StateRoot 'manager-state.json'
$LogRoot = Join-Path $ProjectRoot 'logs'
$LogFile = Join-Path $LogRoot ("Fresh-v4.8-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$ScrapeEndpoint = 'https://archive.org/services/search/v1/scrape'
$AdvancedEndpoint = 'https://archive.org/advancedsearch.php'
$MetadataEndpoint = 'https://archive.org/metadata/'
$script:NoVideoSkipped = 0
$script:MetadataFailures = 0

function Initialize-ManagerFolders {
    foreach ($path in @($ProjectRoot,$ArchiveRoot,$ProgrammeSources,$CommercialSources,
        $CheckpointRoot,$PlaylistRoot,$CommercialPlaylistRoot,$StateRoot,$LogRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Write-Log {
    param([string]$Message,[string]$Level='INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Write-LogFileOnly {
    param([string]$Message,[string]$Level='WARN')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Write-CheckpointJson {
    param([string]$Path,$Value)
    $temp = $Path + '.tmp'
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Add-CheckpointLine {
    param([string]$Path,[string]$Value)
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::AppendAllText($Path,$Value + [Environment]::NewLine,$encoding)
}

function Read-Default {
    param([string]$Prompt,[string]$Default)
    $answer = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Get-SafeFileName {
    param([string]$Value)
    $name = [regex]::Replace($Value,'[^\w.-]+','_').Trim('._')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'archive-search' }
    if ($name.Length -gt 100) { $name = $name.Substring(0,100) }
    return $name
}

function Get-UniqueOutputPath {
    param([string]$Directory,[string]$BaseName,[string]$Extension)
    $path = Join-Path $Directory ($BaseName + $Extension)
    $n = 1
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $Directory ("{0}_{1:000}{2}" -f $BaseName,$n,$Extension)
        $n++
    }
    return $path
}

function Save-State {
    $temp = $StateFile + '.tmp'
    $script:State | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $StateFile -Force
}

function Load-State {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $s = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in @('sources','collections','profiles','channels')) {
                if ($null -eq $s.PSObject.Properties[$property]) {
                    $s | Add-Member -NotePropertyName $property -NotePropertyValue @()
                }
            }
            return $s
        } catch {
            Write-Host "WARNING: Existing v4 state could not be read: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    return [pscustomobject]@{ sources=@(); collections=@(); profiles=@(); channels=@() }
}

function Invoke-GetWithRetry {
    param([string]$Uri,[int]$Retries=5)
    for ($attempt=1; $attempt -le $Retries; $attempt++) {
        try {
            return Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec 120 -Headers @{
                'User-Agent'='ArchiveTV-Source-Library-Manager/4.8'
            }
        } catch {
            if ($attempt -eq $Retries) { throw }
            $delay = [Math]::Min(30,[Math]::Pow(2,$attempt))
            Write-Log "Request failed; retry $attempt/$Retries in $delay seconds. $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds $delay
        }
    }
}

function Encode-Value {
    param([string]$Value)
    return [uri]::EscapeDataString($Value)
}

function ConvertFrom-ArchiveSearchUrl {
    param([string]$SearchUrl)
    $uri = $null
    if (-not [uri]::TryCreate($SearchUrl,[System.UriKind]::Absolute,[ref]$uri)) {
        throw 'Enter a valid absolute Archive.org search-results URL.'
    }
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('archive.org','www.archive.org')) {
        throw 'Search URL mode accepts HTTPS URLs from archive.org only.'
    }
    $values = @{}
    foreach ($pair in ($uri.Query.TrimStart('?') -split '&')) {
        if (-not $pair) { continue }
        $parts = $pair -split '=',2
        $key = [uri]::UnescapeDataString($parts[0].Replace('+',' '))
        $value = ''
        if ($parts.Count -gt 1) { $value = [uri]::UnescapeDataString($parts[1].Replace('+',' ')) }
        $values[$key] = $value
    }
    $query = $values['query']
    if ([string]::IsNullOrWhiteSpace($query)) { $query = $values['q'] }
    if ([string]::IsNullOrWhiteSpace($query)) {
        throw 'No query= or q= parameter was found. Paste a search-results URL, not an item details URL.'
    }

    # /details/movies is an Archive.org browse/category page, not a collection
    # identifier. Preserve candidates so the Scraping API can identify the
    # interpretation matching the user's expected result count.
    $segments = @($uri.AbsolutePath.Trim('/') -split '/')
    $script:ArchiveAutoCandidates = @()
    $script:ArchiveAutoDiscovery = $false
    if ($segments.Count -ge 2 -and $segments[0] -ieq 'details' -and
        $values['tab'] -ieq 'collection') {
        $contextId = [uri]::UnescapeDataString($segments[1])
        if ($contextId -ieq 'movies') {
            $script:ArchiveAutoDiscovery = $true
            $script:ArchiveAutoCandidates = @(
                ('({0}) AND mediatype:movies' -f $query),
                ('({0}) AND mediatype:collection' -f $query),
                ('collection:movies AND ({0})' -f $query),
                $query
            ) | Select-Object -Unique
            Write-Host "Archive.org movie-category context detected: $contextId"
            Write-Host 'The URL tab is collection-oriented, so automatic discovery will compare movie items, collection records, the movies collection filter, and the unfiltered query.'
        } else {
            if ($contextId -notmatch '^[A-Za-z0-9._-]+$') {
                throw "The collection identifier '$contextId' contains unsupported characters; refusing to guess the collection filter."
            }
            $query = 'collection:{0} AND ({1})' -f $contextId,$query
            Write-Host "Collection context detected from URL: $contextId"
            Write-Host "Translated Archive.org query: $query"
        }
    }
    return $query
}

function Add-Source {
    param([string]$Name,[string]$Type,[string]$Path,[string]$Query,[int]$Count)
    $script:State.sources = @($script:State.sources) + @([pscustomobject]@{
        id=[guid]::NewGuid().ToString()
        name=$Name; type=$Type; path=$Path; query=$Query; itemCount=$Count
        created=(Get-Date).ToString('o')
    })
    Save-State
}

function Get-OptionalPropertyValue {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-PlayableArchiveFile {
    param($Metadata)
    $extensions = @('.mp4','.m4v','.mkv','.webm','.avi','.mov','.mpeg','.mpg','.ogv','.wmv')
    $candidates = New-Object System.Collections.Generic.List[object]
    $filesValue = Get-OptionalPropertyValue -Object $Metadata -Name 'files' -Default @()
    foreach ($file in @($filesValue)) {
        $fileName = [string](Get-OptionalPropertyValue -Object $file -Name 'name' -Default '')
        if ([string]::IsNullOrWhiteSpace($fileName)) { continue }
        # Archive.org filenames are untrusted metadata and may contain characters
        # that .NET considers illegal in filesystem paths. Determine the extension
        # lexically from the final URL path segment instead of calling GetExtension.
        $leafName = @($fileName -split '[\\/]')[-1]
        $extensionMatch = [regex]::Match($leafName,'(\.[A-Za-z0-9]{1,10})$')
        if (-not $extensionMatch.Success) { continue }
        $ext = $extensionMatch.Groups[1].Value.ToLowerInvariant()
        if ($ext -notin $extensions) { continue }
        $sourceValue = [string](Get-OptionalPropertyValue -Object $file -Name 'source' -Default '')
        if ($sourceValue -eq 'metadata') { continue }
        # Archive.org omits the private flag on many public file records. Missing means not explicitly private.
        $privateValue = Get-OptionalPropertyValue -Object $file -Name 'private' -Default $null
        if ($null -ne $privateValue -and ([string]$privateValue -eq 'true' -or [string]$privateValue -eq '1')) { continue }
        $size = 0L
        $sizeValue = Get-OptionalPropertyValue -Object $file -Name 'size' -Default $null
        if ($null -ne $sizeValue) { [void][long]::TryParse([string]$sizeValue,[ref]$size) }
        $rank = if ($ext -eq '.mp4') { 1 } else { 0 }
        $candidates.Add([pscustomobject]@{ file=$file; size=$size; rank=$rank })
    }
    if ($candidates.Count -eq 0) { return $null }
    return ($candidates.ToArray() | Sort-Object @{Expression={$_.rank};Descending=$true},@{Expression={$_.size};Descending=$true} | Select-Object -First 1).file
}

function Get-ArchiveRecord {
    param($Item)
    $identifier = [string](Get-OptionalPropertyValue -Object $Item -Name 'identifier' -Default '')
    if ([string]::IsNullOrWhiteSpace($identifier)) { return $null }
    $metadata = Invoke-GetWithRetry -Uri ($MetadataEndpoint + (Encode-Value $identifier))
    $mediaFile = Get-PlayableArchiveFile -Metadata $metadata
    if ($null -eq $mediaFile) {
        $script:NoVideoSkipped++
        Write-LogFileOnly "No eligible public video file for item '$identifier'; skipped." 'WARN'
        if (($script:NoVideoSkipped % 100) -eq 0) {
            Write-Log "Skipped $($script:NoVideoSkipped) identifiers without eligible public video files so far; individual identifiers are recorded in the detailed log." 'WARN'
        }
        return $null
    }
    $fileParts = @(([string]$mediaFile.name -split '/') | ForEach-Object { Encode-Value $_ })
    $filePath = $fileParts -join '/'
    $url = 'https://archive.org/download/{0}/{1}' -f (Encode-Value $identifier),$filePath
    $title = [string](Get-OptionalPropertyValue -Object $Item -Name 'title' -Default '')
    if ([string]::IsNullOrWhiteSpace($title)) { $title = $identifier }
    $year = ''
    $itemYear = Get-OptionalPropertyValue -Object $Item -Name 'year' -Default $null
    $metadataObject = Get-OptionalPropertyValue -Object $metadata -Name 'metadata' -Default $null
    $metadataYear = Get-OptionalPropertyValue -Object $metadataObject -Name 'year' -Default $null
    if ($itemYear) { $year = [string]$itemYear }
    elseif ($metadataYear) { $year = [string]$metadataYear }
    return [pscustomobject]@{
        identifier=$identifier; title=$title; year=$year; url=$url; group='Archive.org'
    }
}

function Write-M3UFile {
    param([string]$Path,[object[]]$Records,[string]$Description)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('#EXTM3U')
    foreach ($record in $Records) {
        $id = ([string]$record.identifier).Replace('"','')
        $title = ([string]$record.title).Replace('"','')
        $group = ([string]$record.group).Replace('"','')
        $lines.Add(('#EXTINF:-1 tvg-id="{0}" tvg-name="{1}" group-title="{2}",{1}' -f $id,$title,$group))
        $lines.Add([string]$record.url)
    }
    Set-Content -LiteralPath $Path -Value $lines.ToArray() -Encoding UTF8
    [pscustomobject]@{
        description=$Description; created=(Get-Date).ToString('o')
        entries=$Records.Count; playlist=$Path
        caveat='Archive.org search results can change while a scrape is running; entries is the number actually retrieved and accepted.'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([IO.Path]::ChangeExtension($Path,'.manifest.json')) -Encoding UTF8
}

function Get-AdvancedSearchCount {
    param([string]$Query)
    # Independent count source: Advanced Search returns response.numFound. Used for query interpretation and optional verification, never as an import cap.
    # rows=0 requests no item documents and avoids relying on Scrape total_only,
    # whose cached responses can repeat counts from a different q value.
    $countUri = $AdvancedEndpoint + '?q=' + (Encode-Value $Query) + '&rows=0&output=json'
    $countResponse = Invoke-GetWithRetry -Uri $countUri
    $responseProperty = $countResponse.PSObject.Properties['response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) {
        throw "Advanced Search count request for '$Query' did not return a response object."
    }
    $totalProperty = $responseProperty.Value.PSObject.Properties['numFound']
    if ($null -eq $totalProperty -or $null -eq $totalProperty.Value) {
        throw "Advanced Search count request for '$Query' did not return response.numFound."
    }
    return [long]$totalProperty.Value
}

function Invoke-ScrapePostWithRetry {
    param([string]$Uri,[int]$Retries=5)
    for ($attempt=1; $attempt -le $Retries; $attempt++) {
        try {
            # POST avoids the stale GET-cache path observed on Scrape API count
            # and search requests while retaining the documented query parameters.
            return Invoke-RestMethod -Method Post -Uri $Uri -TimeoutSec 180 -Headers @{
                'User-Agent'='ArchiveTV-Source-Library-Manager/4.8'
                'Cache-Control'='no-cache'
                'Pragma'='no-cache'
            }
        } catch {
            if ($attempt -eq $Retries) { throw }
            $delay = [Math]::Min(30,[Math]::Pow(2,$attempt))
            Write-Log "Scrape POST failed; retry $attempt/$Retries in $delay seconds. $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds $delay
        }
    }
}

function Resolve-AutoScrapeQuery {
    param([string[]]$Candidates,[long]$ExpectedCount=0)
    $candidateResults = New-Object System.Collections.Generic.List[object]
    Write-Host ''
    Write-Host 'QUERY INTERPRETATION CHECK - count-only checks; no metadata or playlists are being downloaded.'
    $candidateNumber = 0
    foreach ($candidate in @($Candidates | Select-Object -Unique)) {
        $candidateNumber++
        $candidateCount = $null
        try {
            $candidateCount = Get-AdvancedSearchCount -Query $candidate
            Write-Host ("  {0}. {1}  =>  {2} results" -f $candidateNumber,$candidate,$candidateCount)
        } catch {
            Write-Host ("  {0}. {1}  =>  count unavailable ({2})" -f $candidateNumber,$candidate,$_.Exception.Message) -ForegroundColor Yellow
        }
        $candidateResults.Add([pscustomobject]@{ number=$candidateNumber; query=[string]$candidate; count=$candidateCount })
    }

    if ($ExpectedCount -gt 0) {
        $matches = @($candidateResults | Where-Object { $_.count -eq $ExpectedCount })
        if ($matches.Count -eq 1) {
            Write-Host ''
            Write-Host "Selected the only query matching the optional verification count: $($matches[0].query)" -ForegroundColor Green
            return [string]$matches[0].query
        }
        if ($matches.Count -gt 1) {
            Write-Host "More than one interpretation matches $ExpectedCount; choose the intended one below." -ForegroundColor Yellow
        } else {
            Write-Host "No candidate exactly matches the optional count $ExpectedCount. Choose the interpretation that matches the Archive.org results page, or cancel and rerun with expected count 0 if you do not want count verification." -ForegroundColor Yellow
        }
    } else {
        Write-Host 'No expected count is being enforced. Choose the interpretation that matches the Archive.org results page.'
    }

    while ($true) {
        $selection = Read-Host 'Select query interpretation number (Q=cancel)'
        if ($selection.Trim() -ieq 'q') { throw 'Query selection cancelled. No metadata was downloaded and no source playlist was saved.' }
        $number = 0
        if ([int]::TryParse($selection,[ref]$number)) {
            $selected = @($candidateResults | Where-Object { $_.number -eq $number })
            if ($selected.Count -eq 1) {
                Write-Host ''
                Write-Host "SELECTED QUERY: $($selected[0].query)" -ForegroundColor Green
                return [string]$selected[0].query
            }
        }
        Write-Host ("Enter a number from 1 to {0}, or Q to cancel." -f $candidateResults.Count) -ForegroundColor Yellow
    }
}

function Import-ScrapeApi {
    param([string]$Query,[string]$OutputDirectory,[string]$BaseName,[long]$ExpectedCount=0)

    $checkpoint = Join-Path $CheckpointRoot ($BaseName + '.checkpoint.json')
    $seenFile = Join-Path $CheckpointRoot ($BaseName + '.seen.txt')
    $recordsFile = Join-Path $CheckpointRoot ($BaseName + '.records.jsonl')
    $partialM3U = Join-Path $CheckpointRoot ($BaseName + '.partial.m3u')
    $meta = $null
    $cursor = $null
    $page = 0
    $seen = @{}
    $recordSeen = @{}
    $records = New-Object System.Collections.Generic.List[object]
    $reportedTotal = $null
    $resumeTerminal = $false
    $script:NoVideoSkipped = 0
    $script:MetadataFailures = 0

    # A completed checkpoint is reused if the process stopped after writing the
    # full M3U but before registering it in manager-state.json.
    if (Test-Path -LiteralPath $checkpoint) {
        try { $meta = Get-Content -LiteralPath $checkpoint -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { throw "Checkpoint '$checkpoint' is unreadable. It has been preserved; no new import was started. $($_.Exception.Message)" }
        if ([string]$meta.query -ne $Query -or [string]$meta.baseName -ne $BaseName) {
            throw "Checkpoint name collision: '$checkpoint' belongs to a different query. Existing checkpoint was preserved."
        }
        if ([string]$meta.status -eq 'complete' -and (Test-Path -LiteralPath ([string]$meta.outputPath))) {
            Write-Log "Found a completed autosave for this query; reusing $($meta.outputPath)."
            return [pscustomobject]@{path=[string]$meta.outputPath;count=[int]$meta.playableCount}
        }
        if ([string]$meta.status -eq 'terminal') { $resumeTerminal = $true }
        Write-Log "Resuming saved import checkpoint for '$Query'. Previously examined: $($meta.examinedCount); playable records saved: $($meta.playableCount)."
        if (Test-Path -LiteralPath $seenFile) {
            foreach ($idLine in (Get-Content -LiteralPath $seenFile -Encoding UTF8)) {
                $id = [string]$idLine
                if (-not [string]::IsNullOrWhiteSpace($id)) { $seen[$id] = $true }
            }
        }
        if (Test-Path -LiteralPath $recordsFile) {
            $loadedRecordIds = @{}
            foreach ($recordLine in (Get-Content -LiteralPath $recordsFile -Encoding UTF8)) {
                if ([string]::IsNullOrWhiteSpace($recordLine)) { continue }
                try {
                    $recordObject = $recordLine | ConvertFrom-Json
                    $recordId = [string](Get-OptionalPropertyValue -Object $recordObject -Name 'identifier' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($recordId) -and -not $loadedRecordIds.ContainsKey($recordId)) {
                        $loadedRecordIds[$recordId] = $true
                        $recordSeen[$recordId] = $true
                        $records.Add($recordObject)
                    }
                } catch { Write-LogFileOnly "Ignoring an unreadable checkpoint record line: $($_.Exception.Message)" 'WARN' }
            }
        }
        $cursorValue = Get-OptionalPropertyValue -Object $meta -Name 'requestCursor' -Default ''
        if (-not [string]::IsNullOrWhiteSpace([string]$cursorValue)) { $cursor = [string]$cursorValue }
        $page = [int](Get-OptionalPropertyValue -Object $meta -Name 'page' -Default 0)
        $reportedValue = Get-OptionalPropertyValue -Object $meta -Name 'reportedTotal' -Default $null
        if ($null -ne $reportedValue) { $reportedTotal = [long]$reportedValue }
    } else {
        $meta = [pscustomobject]@{
            version=1; query=$Query; baseName=$BaseName; outputDirectory=$OutputDirectory
            requestCursor=''; page=0; reportedTotal=$null; examinedCount=0; playableCount=0
            status='running'; outputPath=''; created=(Get-Date).ToString('o'); updated=(Get-Date).ToString('o')
        }
        if (Test-Path -LiteralPath $seenFile) { Remove-Item -LiteralPath $seenFile -Force }
        if (Test-Path -LiteralPath $recordsFile) { Remove-Item -LiteralPath $recordsFile -Force }
        Write-CheckpointJson -Path $checkpoint -Value $meta
        Write-Log "Created autosave checkpoint on D: $checkpoint"
    }

    # Independent count is informational. Scrape API cursor exhaustion is the
    # pagination authority; Advanced Search can differ slightly as its index updates.
    $preflightTotal = $null
    try {
        $preflightTotal = Get-AdvancedSearchCount -Query $Query
        Write-Log "Independent Advanced Search count-only check: $preflightTotal matching items for '$Query'. Verification only; it is never an import cap."
    } catch {
        Write-Log "Advanced Search count-only check unavailable: $($_.Exception.Message). Continuing with unlimited Scraping API cursor pagination." 'WARN'
        if ($ExpectedCount -gt 0) { throw 'An expected count was entered, but Advanced Search could not verify it. Set expected count to 0 to proceed without count verification.' }
    }
    if ($ExpectedCount -gt 0 -and $null -ne $preflightTotal -and $preflightTotal -ne $ExpectedCount) {
        throw "Expected $ExpectedCount identifiers but Advanced Search reports $preflightTotal. Import stopped before further processing; checkpoint preserved."
    }

    $pageSize = 1000
    $terminal = $resumeTerminal
    while (-not $terminal) {
        $requestCursor = $cursor
        $requestPage = $page + 1
        $request = 'q={0}&fields=identifier,title,mediatype,year&count={1}' -f (Encode-Value $Query),$pageSize
        if (-not [string]::IsNullOrWhiteSpace([string]$requestCursor)) { $request += '&cursor=' + (Encode-Value ([string]$requestCursor)) }
        $response = Invoke-ScrapePostWithRetry -Uri ($ScrapeEndpoint + '?' + $request)
        if ($null -eq $response) { throw "Archive.org Scraping API returned an empty response on page $requestPage. Autosave checkpoint preserved." }

        $responseProperties = @($response.PSObject.Properties | ForEach-Object { $_.Name })
        if ($responseProperties -notcontains 'items') {
            $detail = ($responseProperties -join ', ')
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'no readable response properties' }
            throw "Unexpected Archive.org Scraping API response on page $requestPage. Expected 'items'; found: $detail. Autosave checkpoint preserved."
        }
        $itemsProperty = $response.PSObject.Properties['items']
        $items = @()
        if ($null -ne $itemsProperty -and $null -ne $itemsProperty.Value) { $items = @($itemsProperty.Value) }

        $totalProperty = $response.PSObject.Properties['total']
        if ($null -eq $reportedTotal -and $null -ne $totalProperty -and $null -ne $totalProperty.Value) {
            $reportedTotal = [long]$totalProperty.Value
        }
        $cursorProperty = $response.PSObject.Properties['cursor']
        $next = ''
        if ($null -ne $cursorProperty -and $null -ne $cursorProperty.Value) { $next = [string]$cursorProperty.Value }

        Write-Log "Scrape page $requestPage returned $($items.Count) items."
        if ($items.Count -eq 0) {
            if ($seen.Count -eq 0) { throw "Archive.org Scraping API returned zero results for '$Query'. Check the query. Checkpoint preserved." }
            if (-not [string]::IsNullOrWhiteSpace($next)) {
                throw "Archive.org returned an empty page with a continuation cursor on page $requestPage. Refusing to skip a page; checkpoint preserved."
            }
            if ($null -ne $reportedTotal -and [long]$reportedTotal -gt $seen.Count) {
                throw "Archive.org returned an empty terminal page after $($seen.Count) identifiers, but its reported total is $reportedTotal. Checkpoint preserved; no complete M3U published."
            }
            $terminal = $true
            $page = $requestPage
            $meta.status = 'terminal'
            $meta.requestCursor = ''
            $meta.page = $page
            $meta.reportedTotal = $reportedTotal
            $meta.examinedCount = $seen.Count
            $meta.playableCount = $records.Count
            $meta.updated = (Get-Date).ToString('o')
            Write-CheckpointJson -Path $checkpoint -Value $meta
            break
        }

        foreach ($item in $items) {
            $id = [string](Get-OptionalPropertyValue -Object $item -Name 'identifier' -Default '')
            if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
            $record = $null
            try {
                $record = Get-ArchiveRecord -Item $item
            } catch {
                Write-LogFileOnly "Metadata failure for '$id': $($_.Exception.Message)" 'WARN'
                $script:MetadataFailures++
            }
            if ($null -ne $record -and -not $recordSeen.ContainsKey($id)) {
                # Write record first, then mark identifier seen. If interrupted
                # between writes, resume deduplicates records by identifier.
                Add-CheckpointLine -Path $recordsFile -Value ($record | ConvertTo-Json -Compress -Depth 10)
                $records.Add($record)
                $recordSeen[$id] = $true
            }
            Add-CheckpointLine -Path $seenFile -Value $id
            $seen[$id] = $true
            if (($seen.Count % 25) -eq 0) {
                $meta.requestCursor = [string]$requestCursor
                $meta.page = $requestPage - 1
                $meta.reportedTotal = $reportedTotal
                $meta.examinedCount = $seen.Count
                $meta.playableCount = $records.Count
                $meta.updated = (Get-Date).ToString('o')
                Write-CheckpointJson -Path $checkpoint -Value $meta
            }
        }

        $page = $requestPage
        if ([string]::IsNullOrWhiteSpace($next)) {
            # Archive.org may omit cursor on the final short page. A short page
            # with no cursor is the terminal signal; a full 1,000-item page with
            # no cursor is ambiguous and must not be certified as complete.
            if ($items.Count -ge $pageSize) {
                $meta.requestCursor = [string]$requestCursor
                $meta.page = $requestPage - 1
                $meta.examinedCount = $seen.Count
                $meta.playableCount = $records.Count
                $meta.updated = (Get-Date).ToString('o')
                Write-CheckpointJson -Path $checkpoint -Value $meta
                throw "Archive.org returned a full $pageSize-item page $requestPage without a continuation cursor. Completeness cannot be verified; checkpoint preserved."
            }
            if ($null -ne $reportedTotal -and [long]$reportedTotal -gt $seen.Count) {
                $meta.requestCursor = [string]$requestCursor
                $meta.page = $requestPage - 1
                $meta.examinedCount = $seen.Count
                $meta.playableCount = $records.Count
                $meta.updated = (Get-Date).ToString('o')
                Write-CheckpointJson -Path $checkpoint -Value $meta
                throw "Archive.org cursor ended after $($seen.Count) identifiers, but its reported total is $reportedTotal. Checkpoint preserved; no complete M3U published."
            }
            $terminal = $true
        } else {
            if (-not [string]::IsNullOrWhiteSpace([string]$requestCursor) -and $next -eq [string]$requestCursor) {
                throw "Archive.org returned the same cursor again on page $requestPage. Checkpoint preserved to prevent an infinite loop."
            }
            $cursor = $next
        }

        # Page boundary checkpoint: next request cursor is committed only after
        # every identifier in the current page has been processed.
        $meta.requestCursor = [string]$cursor
        $meta.page = $page
        $meta.status = if ($terminal) { 'terminal' } else { 'running' }
        $meta.reportedTotal = $reportedTotal
        $meta.examinedCount = $seen.Count
        $meta.playableCount = $records.Count
        $meta.updated = (Get-Date).ToString('o')
        Write-CheckpointJson -Path $checkpoint -Value $meta

        # Keep a clearly marked partial M3U snapshot in checkpoints, never in the
        # source-library folders. The JSONL journal remains the resume authority.
        if (($seen.Count % 5000) -lt $items.Count -and $records.Count -gt 0) {
            Write-M3UFile -Path $partialM3U -Records $records.ToArray() -Description ("INCOMPLETE CHECKPOINT - " + $Query)
            $partialManifest = [pscustomobject]@{status='in-progress';query=$Query;identifiersExamined=$seen.Count;playableEntries=$records.Count;updated=(Get-Date).ToString('o')}
            $partialManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ([IO.Path]::ChangeExtension($partialM3U,'.manifest.json')) -Encoding UTF8
        }
        Write-Log "Progress: $($seen.Count) identifiers examined; $($records.Count) playable files collected."
    }

    if ($ExpectedCount -gt 0 -and $seen.Count -ne $ExpectedCount) {
        throw "Expected $ExpectedCount identifiers but the Scraping API returned $($seen.Count). Checkpoint preserved; no complete M3U published."
    }
    if ($seen.Count -eq 0) { throw "Scrape completed without retrieving identifiers for '$Query'. Checkpoint preserved." }
    if ($records.Count -eq 0) { throw "Scrape retrieved $($seen.Count) identifiers but none had eligible public video files. Checkpoint preserved." }

    if ($null -ne $preflightTotal -and [long]$preflightTotal -ne $seen.Count) {
        Write-Log "Terminal cursor received after $($seen.Count) identifiers; independent Advanced Search currently reports $preflightTotal. This cross-endpoint count difference is recorded for review; Scrape API supplied no continuation cursor on its final short page." 'WARN'
    }
    if ($script:NoVideoSkipped -gt 0) { Write-Log "Import skipped $($script:NoVideoSkipped) identifiers without eligible public video files; full per-item details are in $LogFile." 'WARN' }
    if ($script:MetadataFailures -gt 0) { Write-Log "Import encountered $($script:MetadataFailures) metadata failures; per-item details are in $LogFile." 'WARN' }

    $output = Get-UniqueOutputPath -Directory $OutputDirectory -BaseName $BaseName -Extension '.m3u'
    Write-M3UFile -Path $output -Records $records.ToArray() -Description $Query
    $meta.status = 'complete'
    $meta.outputPath = $output
    $meta.examinedCount = $seen.Count
    $meta.playableCount = $records.Count
    $meta.reportedTotal = $reportedTotal
    $meta.preflightTotal = $preflightTotal
    $meta.completed = (Get-Date).ToString('o')
    $meta.updated = (Get-Date).ToString('o')
    Write-CheckpointJson -Path $checkpoint -Value $meta
    if (Test-Path -LiteralPath $partialM3U) { Remove-Item -LiteralPath $partialM3U -Force }
    if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($partialM3U,'.manifest.json'))) { Remove-Item -LiteralPath ([IO.Path]::ChangeExtension($partialM3U,'.manifest.json')) -Force }
    Write-Log "FULL SOURCE M3U AUTOSAVED: $output"
    Write-Log "Scrape complete. Examined=$($seen.Count); playable=$($records.Count); API total=$reportedTotal; Advanced Search count=$preflightTotal."
    return [pscustomobject]@{path=$output;count=$records.Count}
}

function Import-AdvancedApi {
    param([string]$Query,[string]$OutputDirectory,[string]$BaseName)
    $pageSize = 500
    $page = 1
    $total = $null
    $seen = @{}
    $records = New-Object System.Collections.Generic.List[object]
    do {
        $request = 'q={0}&fl[]=identifier&fl[]=title&fl[]=year&fl[]=mediatype&rows={1}&page={2}&output=json' -f (Encode-Value $Query),$pageSize,$page
        $response = Invoke-GetWithRetry -Uri ($AdvancedEndpoint + '?' + $request)
        $docs = @($response.response.docs)
        if ($null -eq $total) { $total = [int]$response.response.numFound }
        if ($docs.Count -eq 0) { break }
        foreach ($item in $docs) {
            $id = [string]$item.identifier
            if (-not $id -or $seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            try {
                $record = Get-ArchiveRecord -Item $item
                if ($null -ne $record) { $records.Add($record) }
            } catch { Write-Log "Metadata failure for '$id': $($_.Exception.Message)" 'WARN' }
        }
        Write-Log "Advanced Search page ${page}: examined $($seen.Count) of $total."
        $page++
    } while ($seen.Count -lt $total)

    $output = Get-UniqueOutputPath -Directory $OutputDirectory -BaseName $BaseName -Extension '.m3u'
    Write-M3UFile -Path $output -Records $records.ToArray() -Description $Query
    return [pscustomobject]@{path=$output;count=$records.Count}
}

function Import-CustomM3U {
    param([string]$Endpoint,[string]$OutputDirectory,[string]$BaseName)
    if ($Endpoint -notmatch '^https://') { throw 'Custom endpoint must use HTTPS.' }
    $response = Invoke-WebRequest -Uri $Endpoint -Method Get -TimeoutSec 120
    if ([string]$response.Content -notmatch '(?m)^#EXTM3U') {
        throw 'Custom endpoint did not return a complete M3U body.'
    }
    $output = Get-UniqueOutputPath -Directory $OutputDirectory -BaseName $BaseName -Extension '.m3u'
    Set-Content -LiteralPath $output -Value ([string]$response.Content) -Encoding UTF8
    return [pscustomobject]@{path=$output;count=0}
}

function Register-ExistingSource {
    $path = Read-Host 'Full path to existing source M3U'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Log 'File not found.' 'WARN'; return }
    if ([IO.Path]::GetExtension($path).ToLowerInvariant() -notin @('.m3u','.m3u8')) {
        Write-Log 'Select an .m3u or .m3u8 file.' 'WARN'; return
    }
    $typeChoice = Read-Default '1=Programme, 2=Commercial' '1'
    $type = if ($typeChoice -eq '2') { 'Commercial' } else { 'Programme' }
    $name = Read-Default 'Source name' ([IO.Path]::GetFileNameWithoutExtension($path))
    Add-Source -Name $name -Type $type -Path $path -Query '' -Count 0
    Write-Log "Registered source '$name'; original was not changed."
}

function Get-NormalizedArchiveQuery {
    param([string]$Query)
    if ($null -eq $Query) { return '' }
    return ([regex]::Replace($Query.Trim(),'\s+',' ')).ToLowerInvariant()
}

function Import-ArchiveSource {
    Write-Host ''
    Write-Host 'Choose an Archive.org endpoint or search input:'
    Write-Host '1 Scraping API - recommended default, cursor pagination'
    Write-Host '2 Advanced Search API - page pagination'
    Write-Host '3 Paste Archive.org search-results URL - parsed and routed to Scraping API'
    Write-Host '4 Custom HTTPS endpoint returning a complete M3U'
    $choice = Read-Default 'Endpoint option' '1'
    $query = ''
    $customEndpoint = ''
    $script:ArchiveAutoCandidates = @()
    $script:ArchiveAutoDiscovery = $false

    switch ($choice) {
        '1' {
            Write-Host "Endpoint: $ScrapeEndpoint"
            Write-Host 'Pagination: cursor-based; 1,000 items per API batch; continues until Archive.org supplies no next cursor (no total-result cap).'
            $query = Read-Host 'Exact full-search query or Archive.org search-results URL'
            if ($query -match '^https://(www\.)?archive\.org/') {
                $query = ConvertFrom-ArchiveSearchUrl -SearchUrl $query
                Write-Host "Detected Archive.org search URL. Extracted query: $query"
                Write-Host 'Using the unlimited cursor-paginated Scraping API.'
            }
        }
        '2' {
            Write-Host "Endpoint: $AdvancedEndpoint"
            $query = Read-Host 'Exact full-search query (plain text)'
        }
        '3' {
            $url = Read-Host 'Paste Archive.org search-results URL'
            $query = ConvertFrom-ArchiveSearchUrl -SearchUrl $url
            Write-Host "Extracted search query: $query"
            Write-Host "Using recommended endpoint: $ScrapeEndpoint"
        }
        '4' {
            $customEndpoint = Read-Host 'Custom HTTPS endpoint'
            $query = Read-Host 'Label for this source'
        }
        default { Write-Log 'Invalid endpoint option.' 'WARN'; return }
    }
    if ([string]::IsNullOrWhiteSpace($query)) { Write-Log 'Search query cannot be empty.' 'WARN'; return }

    $expectedCount = 0L
    if ($choice -eq '1' -or $choice -eq '3') {
        $expectedText = Read-Default 'Optional expected Archive.org matching item count (0=do not enforce; verification only, never a cap)' '0'
        if (-not [long]::TryParse($expectedText,[ref]$expectedCount) -or $expectedCount -lt 0) {
            throw 'Expected item count must be a non-negative whole number.'
        }
    }
    if ($script:ArchiveAutoDiscovery -and ($choice -eq '1' -or $choice -eq '3')) {
        $query = Resolve-AutoScrapeQuery -Candidates $script:ArchiveAutoCandidates -ExpectedCount $expectedCount
    }

    $typeChoice = Read-Default '1=Programme source, 2=Commercial source' '1'
    $type = if ($typeChoice -eq '2') { 'Commercial' } else { 'Programme' }
    $directory = if ($type -eq 'Commercial') { $CommercialSources } else { $ProgrammeSources }
    $baseName = Get-SafeFileName ("{0}_{1}" -f $type,$query)

    # Prevent repeating an already registered full-search import. Existing M3Us
    # are never modified or removed; the user is simply returned to the menu.
    $normalizedQuery = Get-NormalizedArchiveQuery -Query $query
    $existingMatches = @($State.sources | Where-Object {
        $_.type -eq $type -and
        (Get-NormalizedArchiveQuery -Query ([string]$_.query)) -eq $normalizedQuery -and
        (Test-Path -LiteralPath ([string]$_.path))
    })
    if ($existingMatches.Count -gt 0) {
        Write-Host ''
        Write-Host "An identical $type source query is already registered. No new import will be started." -ForegroundColor Yellow
        foreach ($existing in $existingMatches) {
            Write-Host ("  {0} | {1} entries | {2}" -f $existing.name,$existing.itemCount,$existing.path)
        }
        Write-Host 'Existing source files and manager records were left unchanged.'
        return
    }

    if ($choice -eq '4') {
        $result = Import-CustomM3U -Endpoint $customEndpoint -OutputDirectory $directory -BaseName $baseName
    } elseif ($choice -eq '2') {
        $result = Import-AdvancedApi -Query $query -OutputDirectory $directory -BaseName $baseName
    } else {
        $result = Import-ScrapeApi -Query $query -OutputDirectory $directory -BaseName $baseName -ExpectedCount $expectedCount
    }
    Add-Source -Name $baseName -Type $type -Path $result.path -Query $query -Count $result.count
    Write-Host ''
    Write-Host "Saved source: $($result.path)"
    Write-Host "Playable entries recorded: $($result.count)"
}

function Create-Collection {
    $name = Read-Host 'Collection name'
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $typeChoice = Read-Default '1=Programme Master Library, 2=Commercial Master Library' '1'
    $type = if ($typeChoice -eq '2') { 'Commercial' } else { 'Programme' }
    $sources = @($State.sources | Where-Object { $_.type -eq $type })
    if ($sources.Count -eq 0) { Write-Log "No $type sources registered." 'WARN'; return }
    for ($i=0; $i -lt $sources.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$sources[$i].name) }
    $selection = Read-Host 'Source numbers separated by commas'
    $ids = @()
    foreach ($part in ($selection -split ',')) {
        $n=0
        if ([int]::TryParse($part.Trim(),[ref]$n) -and $n -ge 1 -and $n -le $sources.Count) { $ids += $sources[$n-1].id }
    }
    $State.collections = @($State.collections) + @([pscustomobject]@{
        id=[guid]::NewGuid().ToString();name=$name;type=$type;sourceIds=@($ids);created=(Get-Date).ToString('o')
    })
    Save-State
    Write-Log "Created $type collection '$name'."
}

function Create-Profile {
    $name = Read-Host 'Profile name'
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $typeChoice = Read-Default '1=Programme, 2=Commercial' '1'
    $type = if ($typeChoice -eq '2') { 'Commercial' } else { 'Programme' }
    $collections = @($State.collections | Where-Object { $_.type -eq $type })
    if ($collections.Count -eq 0) { Write-Log "No $type collections available." 'WARN'; return }
    for ($i=0; $i -lt $collections.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$collections[$i].name) }
    $selection = Read-Host 'Collection numbers separated by commas'
    $ids = @()
    foreach ($part in ($selection -split ',')) {
        $n=0
        if ([int]::TryParse($part.Trim(),[ref]$n) -and $n -ge 1 -and $n -le $collections.Count) { $ids += $collections[$n-1].id }
    }
    $State.profiles = @($State.profiles) + @([pscustomobject]@{
        id=[guid]::NewGuid().ToString();name=$name;type=$type;collectionIds=@($ids);created=(Get-Date).ToString('o')
    })
    Save-State
    Write-Log "Created $type profile '$name'."
}

function Define-Channel {
    $name = Read-Host 'Programme channel name'
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $profiles = @($State.profiles | Where-Object { $_.type -eq 'Programme' })
    if ($profiles.Count -eq 0) { Write-Log 'Create a Programme Profile first.' 'WARN'; return }
    for ($i=0; $i -lt $profiles.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$profiles[$i].name) }
    $selection = Read-Default 'Programme profile number' '1'
    $n=0
    if (-not [int]::TryParse($selection,[ref]$n) -or $n -lt 1 -or $n -gt $profiles.Count) { return }

    $commercialProfiles = @($State.profiles | Where-Object { $_.type -eq 'Commercial' })
    $commercialIds = @()
    if ($commercialProfiles.Count -gt 0) {
        Write-Host 'Optional commercial profiles to merge:'
        for ($i=0; $i -lt $commercialProfiles.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$commercialProfiles[$i].name) }
        $cs = Read-Host 'Commercial profile numbers separated by commas, or Enter for none'
        foreach ($part in ($cs -split ',')) {
            $j=0
            if ([int]::TryParse($part.Trim(),[ref]$j) -and $j -ge 1 -and $j -le $commercialProfiles.Count) {
                $commercialIds += $commercialProfiles[$j-1].id
            }
        }
    }
    $State.channels = @($State.channels) + @([pscustomobject]@{
        id=[guid]::NewGuid().ToString();name=$name;programmeProfileId=$profiles[$n-1].id
        commercialProfileIds=@($commercialIds);created=(Get-Date).ToString('o')
    })
    Save-State
    Write-Log "Defined programme channel '$name'."
}

function Get-ProfileSourcePaths {
    param([string[]]$CollectionIds)
    $paths = @()
    foreach ($collectionId in $CollectionIds) {
        $collection = @($State.collections | Where-Object { $_.id -eq $collectionId }) | Select-Object -First 1
        if ($null -eq $collection) { continue }
        foreach ($sourceId in $collection.sourceIds) {
            $source = @($State.sources | Where-Object { $_.id -eq $sourceId }) | Select-Object -First 1
            if ($null -ne $source -and (Test-Path -LiteralPath $source.path)) { $paths += $source.path }
        }
    }
    return @($paths | Select-Object -Unique)
}

function Read-M3UEntries {
    param([string[]]$Paths)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($path in $Paths) {
        $extinf = ''
        foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
            if ($line -like '#EXTINF*') { $extinf=$line; continue }
            if ($line -match '^https?://') {
                $title=$line
                if ($extinf -match ',(.*)$') { $title=$Matches[1] }
                $id=$line
                if ($extinf -match 'tvg-id="([^"]*)"') { $id=$Matches[1] }
                $entries.Add([pscustomobject]@{identifier=$id;title=$title;url=$line;group='Archive TV'})
                $extinf=''
            }
        }
    }
    $seen=@{}
    $unique=New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) }
    }
    return $unique.ToArray()
}

function Publish-Profile {
    param($Profile,[string]$Directory,[int]$Limit=0)
    $paths=Get-ProfileSourcePaths -CollectionIds @($Profile.collectionIds)
    if ($paths.Count -eq 0) { Write-Log "Profile '$($Profile.name)' has no accessible source files." 'WARN'; return }
    $entries=@(Read-M3UEntries -Paths $paths)
    if ($Limit -gt 0 -and $entries.Count -gt $Limit) { $entries=@($entries | Get-Random -Count $Limit) }
    $output=Get-UniqueOutputPath -Directory $Directory -BaseName (Get-SafeFileName $Profile.name) -Extension '.m3u'
    Write-M3UFile -Path $output -Records $entries -Description ("Profile: " + $Profile.name)
    Write-Log "Published $($Profile.type) profile '$($Profile.name)' ($($entries.Count) entries): $output"
}

function Publish-Channels {
    $limitText=Read-Default 'Maximum entries per operational channel (0=no sampling)' '500'
    $limit=0
    if (-not [int]::TryParse($limitText,[ref]$limit) -or $limit -lt 0) { $limit=500 }
    foreach ($channel in $State.channels) {
        $programme=@($State.profiles | Where-Object { $_.id -eq $channel.programmeProfileId }) | Select-Object -First 1
        if ($null -eq $programme) { continue }
        $entries=New-Object System.Collections.Generic.List[object]
        foreach ($path in (Get-ProfileSourcePaths -CollectionIds @($programme.collectionIds))) {
            foreach ($entry in (Read-M3UEntries -Paths @($path))) { $entries.Add($entry) }
        }
        foreach ($profileId in $channel.commercialProfileIds) {
            $commercial=@($State.profiles | Where-Object { $_.id -eq $profileId }) | Select-Object -First 1
            if ($null -ne $commercial) {
                foreach ($path in (Get-ProfileSourcePaths -CollectionIds @($commercial.collectionIds))) {
                    foreach ($entry in (Read-M3UEntries -Paths @($path))) { $entries.Add($entry) }
                }
            }
        }
        $seen=@{}
        $unique=New-Object System.Collections.Generic.List[object]
        foreach ($entry in $entries) {
            if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) }
        }
        $result=$unique.ToArray()
        if ($limit -gt 0 -and $result.Count -gt $limit) { $result=@($result | Get-Random -Count $limit) }
        $output=Get-UniqueOutputPath -Directory $PlaylistRoot -BaseName (Get-SafeFileName $channel.name) -Extension '.m3u'
        Write-M3UFile -Path $output -Records $result -Description ("Channel: " + $channel.name)
        Write-Log "Published channel '$($channel.name)' with $($result.Count) entries: $output"
    }
}

function Publish-MasterLibraries {
    foreach ($type in @('Programme','Commercial')) {
        $all=New-Object System.Collections.Generic.List[object]
        foreach ($profile in @($State.profiles | Where-Object { $_.type -eq $type })) {
            foreach ($path in (Get-ProfileSourcePaths -CollectionIds @($profile.collectionIds))) {
                foreach ($entry in (Read-M3UEntries -Paths @($path))) { $all.Add($entry) }
            }
        }
        $seen=@{}
        $unique=New-Object System.Collections.Generic.List[object]
        foreach ($entry in $all) {
            if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) }
        }
        $directory=if ($type -eq 'Commercial') { $CommercialPlaylistRoot } else { $PlaylistRoot }
        $output=Get-UniqueOutputPath -Directory $directory -BaseName ($type + '-Master-Library') -Extension '.m3u'
        Write-M3UFile -Path $output -Records $unique.ToArray() -Description ($type + ' Master Library')
        Write-Log "Published $type Master Library with $($unique.Count) entries: $output"
    }
}

function Publish-CombinedMaster {
    $all=New-Object System.Collections.Generic.List[object]
    foreach ($source in $State.sources) {
        if (Test-Path -LiteralPath $source.path) {
            foreach ($entry in (Read-M3UEntries -Paths @($source.path))) { $all.Add($entry) }
        }
    }
    $seen=@{}
    $unique=New-Object System.Collections.Generic.List[object]
    foreach ($entry in $all) {
        if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) }
    }
    $output=Get-UniqueOutputPath -Directory $PlaylistRoot -BaseName 'Combined-Master-Library' -Extension '.m3u'
    Write-M3UFile -Path $output -Records $unique.ToArray() -Description 'Combined Master Library'
    Write-Log "Published combined master with $($unique.Count) entries: $output"
}

function Show-Overview {
    Write-Host ''
    Write-Host "Sources: $(@($State.sources).Count)"
    foreach ($s in $State.sources) { Write-Host "  [$($s.type)] $($s.name) | $($s.itemCount) entries | $($s.path)" }
    Write-Host "Collections: $(@($State.collections).Count)"
    foreach ($c in $State.collections) { Write-Host "  [$($c.type)] $($c.name)" }
    Write-Host "Profiles: $(@($State.profiles).Count)"
    foreach ($p in $State.profiles) { Write-Host "  [$($p.type)] $($p.name)" }
    Write-Host "Channels: $(@($State.channels).Count)"
    foreach ($c in $State.channels) { Write-Host "  $($c.name)" }
    Write-Host ''
    Write-Host "Programme source M3Us: $ProgrammeSources"
    Write-Host "Commercial source M3Us: $CommercialSources"
    Write-Host "Programme operational playlists: $PlaylistRoot"
    Write-Host "Commercial operational playlists: $CommercialPlaylistRoot"
    Write-Host "Manager state: $StateFile"
}

Initialize-ManagerFolders
$script:State = Load-State
Write-Log 'Fresh v4.8 started. New installations begin with no sources, collections, profiles or channels.'

do {
    Write-Host ''
    Write-Host '===== Archive TV Source Library Manager - Fresh v4.8 ====='
    Write-Host '1 Register existing source M3U'
    Write-Host '2 Import from Archive.org (endpoint or search URL)'
    Write-Host '3 Create labelled Master Library collection'
    Write-Host '4 Create Programme or Commercial Profile'
    Write-Host '5 Define programme channel'
    Write-Host '6 Publish operational channel playlist(s)'
    Write-Host '7 Publish separate Programme and Commercial Master Libraries'
    Write-Host '8 Publish combined master playlist'
    Write-Host '9 Show manager overview'
    Write-Host '0 Exit'
    $choice=Read-Host 'Select option (blank=exit)'
    if ([string]::IsNullOrWhiteSpace([string]$choice)) {
        Write-Log 'No menu input received; exiting cleanly instead of repeating the menu.' 'WARN'
        break
    }
    try {
        switch ($choice) {
            '1' { Register-ExistingSource }
            '2' { Import-ArchiveSource }
            '3' { Create-Collection }
            '4' { Create-Profile }
            '5' { Define-Channel }
            '6' { Publish-Channels }
            '7' { Publish-MasterLibraries }
            '8' { Publish-CombinedMaster }
            '9' { Show-Overview }
            '0' { break }
            default { Write-Host 'Invalid selection.' }
        }
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        if ($_.ScriptStackTrace) { Write-Log ($_.ScriptStackTrace -replace '[\r\n]+',' | ') 'ERROR' }
    }
} while ($choice -ne '0')

Write-Log 'Fresh v4 exited.'
