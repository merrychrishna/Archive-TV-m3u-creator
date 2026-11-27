#requires -Version 5.1
param([switch]$ScheduledRefresh)

<#
ARCHIVE TV SOURCE LIBRARY MANAGER - FRESH V5.4
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
- v5.4 workflow: full source M3Us -> selected source M3Us in collections -> profiles from selected collections -> Master Libraries from profiles.
- Master Library publication never automatically includes every imported source or collection.
- Language filters apply downstream; complete source imports and refreshes retain every language.
- Channel splits support genre/group, custom label, decade, and custom decade groups.
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
$StateRoot = Join-Path $ProjectRoot 'system\source-library-manager-v4' # Preserve and migrate existing v4 state
$StateFile = Join-Path $StateRoot 'manager-state.json'
$LogRoot = Join-Path $ProjectRoot 'logs'
$LogFile = Join-Path $LogRoot ("Fresh-v5.4-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$ScrapeEndpoint = 'https://archive.org/services/search/v1/scrape'
$AdvancedEndpoint = 'https://archive.org/advancedsearch.php'
$MetadataEndpoint = 'https://archive.org/metadata/'
$BackupRoot = Join-Path $ProjectRoot 'backups\source-refresh'
$MasterBackupRoot = Join-Path $ProjectRoot 'backups\master-libraries'
$RefreshStaging = Join-Path $ArchiveRoot 'refresh-staging'
$RandomizedRoot = Join-Path $ProjectRoot 'live\randomized'
$RuntimePath = Join-Path $ProjectRoot 'scripts\playout_D_runtime_V4_20261117.py'
$ManagerLockPath = Join-Path $StateRoot 'manager-operation.lock'
$ScheduleConfigPath = Join-Path $StateRoot 'refresh-schedule.json'
$script:ExcludeNonEnglish = $false
$script:NoVideoSkipped = 0
$script:MetadataFailures = 0

function Initialize-ManagerFolders {
    foreach ($path in @($ProjectRoot,$ArchiveRoot,$ProgrammeSources,$CommercialSources,
        $CheckpointRoot,$PlaylistRoot,$CommercialPlaylistRoot,$StateRoot,$LogRoot,$BackupRoot,$MasterBackupRoot,$RefreshStaging,$RandomizedRoot)) {
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
            foreach ($source in @($s.sources)) {
                $defaults = @{
                    expectedCount=0; languageFilterEnabled=$false; endpointMode='Scrape'
                    refreshable=([bool](-not [string]::IsNullOrWhiteSpace([string]$source.query)))
                    pendingRefreshBase=''; lastRefresh=''; lastRefreshStatus=''
                }
                foreach ($key in $defaults.Keys) {
                    if ($null -eq $source.PSObject.Properties[$key]) {
                        $source | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
                    }
                }
            }
            if ($null -eq $s.PSObject.Properties['languageSettings']) { $s | Add-Member -NotePropertyName languageSettings -NotePropertyValue ([pscustomobject]@{ mode='All available languages'; selected=@() }) }
            if ($null -eq $s.PSObject.Properties['masterPublishSelections']) { $s | Add-Member -NotePropertyName masterPublishSelections -NotePropertyValue @() }
            return $s
        } catch {
            Write-Host "WARNING: Existing v4 state could not be read: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    return [pscustomobject]@{ sources=@(); collections=@(); profiles=@(); channels=@(); languageSettings=[pscustomobject]@{ mode='All available languages'; selected=@() }; masterPublishSelections=@() }
}

function Invoke-GetWithRetry {
    param([string]$Uri,[int]$Retries=5)
    for ($attempt=1; $attempt -le $Retries; $attempt++) {
        try {
            return Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec 120 -Headers @{
                'User-Agent'='ArchiveTV-Source-Library-Manager/5.4'
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
    param([string]$Name,[string]$Type,[string]$Path,[string]$Query,[int]$Count,
        [long]$ExpectedCount=0,[bool]$LanguageFilterEnabled=$false,[string]$EndpointMode='Scrape',[bool]$Refreshable=$true)
    $script:State.sources = @($script:State.sources) + @([pscustomobject]@{
        id=[guid]::NewGuid().ToString()
        name=$Name; type=$Type; path=$Path; query=$Query; itemCount=$Count
        expectedCount=$ExpectedCount; languageFilterEnabled=$LanguageFilterEnabled
        endpointMode=$EndpointMode; refreshable=$Refreshable
        pendingRefreshBase=''; lastRefresh=''; lastRefreshStatus=''
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

function Get-ArchiveLanguage {
    param($Item,$Metadata)
    $value = Get-OptionalPropertyValue -Object $Item -Name 'language' -Default $null
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        $metaObject = Get-OptionalPropertyValue -Object $Metadata -Name 'metadata' -Default $null
        $value = Get-OptionalPropertyValue -Object $metaObject -Name 'language' -Default $null
    }
    if ($null -eq $value) { return '' }
    if ($value -is [System.Array]) { return (@($value | ForEach-Object { [string]$_ }) -join ', ') }
    return ([string]$value).Trim()
}

function Test-ExplicitNonEnglishLanguage {
    param([string]$Language)
    if ([string]::IsNullOrWhiteSpace($Language)) { return $false }
    $tokens = @($Language -split '[,;|/]+' | ForEach-Object { ($_.Trim().ToLowerInvariant() -replace '\s*\([^)]*\)$','').Trim() } | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return $false }
    $english = @('en','eng','english','en-us','en-gb','en-ca','en-au','en-uk','english (united states)','english (united kingdom)')
    $unknown = @('unknown','und','mul','zxx','mis','n/a','na','none','unspecified','not specified','not known','null','')
    $knownNonEnglish = @('es','spa','spanish','espanol','fr','fre','fra','french','francais','de','ger','deu','german','it','ita','italian','pt','por','portuguese','br','pt-br','ru','rus','russian','ja','jpn','japanese','zh','chi','zho','chinese','ko','kor','korean','nl','dut','nld','dutch','sv','swe','swedish','no','nor','norwegian','da','dan','danish','fi','fin','finnish','pl','pol','polish','ar','ara','arabic','hi','hin','hindi','he','heb','hebrew','el','gre','ell','greek','tr','tur','turkish','uk','ukr','ukrainian','vi','vie','vietnamese','th','tha','thai')
    foreach ($token in $tokens) {
        if ($token -in $english -or $token -in $unknown) { continue }
        if ($token -in $knownNonEnglish) { return $true }
        # Unknown descriptive values are retained; recognized ISO language codes are excluded.
        if ($token -match '^[a-z]{2,3}(-[a-z]{2})?$') { return $true }
    }
    return $false
}

function Get-ArchiveRecord {
    param($Item)
    $identifier = [string](Get-OptionalPropertyValue -Object $Item -Name 'identifier' -Default '')
    if ([string]::IsNullOrWhiteSpace($identifier)) { return $null }
    $metadata = Invoke-GetWithRetry -Uri ($MetadataEndpoint + (Encode-Value $identifier))
    $language = Get-ArchiveLanguage -Item $Item -Metadata $metadata
    if ($script:ExcludeNonEnglish -and (Test-ExplicitNonEnglishLanguage -Language $language)) {
        $script:NonEnglishSkipped++
        Write-LogFileOnly "Explicit non-English language '$language' for item '$identifier'; excluded by language filter." 'INFO'
        return $null
    }
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
        identifier=$identifier; title=$title; year=$year; url=$url; group='Archive.org'; language=$language
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
        $language = ([string](Get-OptionalPropertyValue -Object $record -Name 'language' -Default '')).Replace('"','')
        $languageTag = if (-not [string]::IsNullOrWhiteSpace($language)) { ' tvg-language="' + $language + '"' } else { '' }
        $year = [string](Get-OptionalPropertyValue -Object $record -Name 'year' -Default '')
        $yearValue = if ($year -match '((?:19|20)\d{2})') { $Matches[1] } else { '' }
        $yearTag = if ($yearValue) { ' tvg-year="' + $yearValue + '"' } else { '' }
        $lines.Add(('#EXTINF:-1 tvg-id="{0}" tvg-name="{1}" group-title="{2}"{3}{4},{1}' -f $id,$title,$group,$languageTag,$yearTag))
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
                'User-Agent'='ArchiveTV-Source-Library-Manager/5.4'
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
    $script:NonEnglishSkipped = 0

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
            version=1; query=$Query; baseName=$BaseName; outputDirectory=$OutputDirectory; expectedCount=$ExpectedCount
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
    if ($script:NonEnglishSkipped -gt 0) { Write-Log "Language filter excluded $($script:NonEnglishSkipped) explicitly non-English items." 'INFO' }

    $output = Get-UniqueOutputPath -Directory $OutputDirectory -BaseName $BaseName -Extension '.m3u'
    Write-M3UFile -Path $output -Records $records.ToArray() -Description $Query
    $meta.status = 'complete'
    $meta.outputPath = $output
    $meta.examinedCount = $seen.Count
    $meta.playableCount = $records.Count
    $meta.reportedTotal = $reportedTotal
    if ($null -eq $meta.PSObject.Properties['preflightTotal']) {
        $meta | Add-Member -NotePropertyName preflightTotal -NotePropertyValue $preflightTotal
    } else {
        $meta.preflightTotal = $preflightTotal
    }
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
    $script:NonEnglishSkipped = 0
    $script:NoVideoSkipped = 0
    $script:MetadataFailures = 0
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
    if ($script:NonEnglishSkipped -gt 0) { Write-Log "Language filter excluded $($script:NonEnglishSkipped) explicitly non-English items." 'INFO' }

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
    Add-Source -Name $name -Type $type -Path $path -Query '' -Count 0 -Refreshable $false
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
    Write-Host 'Complete source imports always retain all languages. Language filters are applied later to libraries, profiles and channels.'
    $script:ExcludeNonEnglish = $false
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

    $lock = Enter-ManagerOperationLock
    try {
        if ($choice -eq '4') {
            $result = Import-CustomM3U -Endpoint $customEndpoint -OutputDirectory $directory -BaseName $baseName
        } elseif ($choice -eq '2') {
            $result = Import-AdvancedApi -Query $query -OutputDirectory $directory -BaseName $baseName
        } else {
            $result = Import-ScrapeApi -Query $query -OutputDirectory $directory -BaseName $baseName -ExpectedCount $expectedCount
        }
    } finally { Exit-ManagerOperationLock -LockStream $lock }
    $endpointMode = switch ($choice) { '1' { 'Scrape' } '2' { 'Advanced' } '3' { 'SearchUrl' } default { 'Custom' } }
    $canRefresh = ($choice -in @('1','2','3'))
    Add-Source -Name $baseName -Type $type -Path $result.path -Query $query -Count $result.count -ExpectedCount $expectedCount -LanguageFilterEnabled $false -EndpointMode $endpointMode -Refreshable $canRefresh
    Write-Host ''
    Write-Host "Saved source: $($result.path)"
    Write-Host "Playable entries recorded: $($result.count)"
}

function Create-Collection {
    $name = Read-Host 'Collection name'
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $typeChoice = Read-Default '1=Programme collection, 2=Commercial collection' '1'
    $type = if ($typeChoice -eq '2') { 'Commercial' } else { 'Programme' }
    $sources = @($State.sources | Where-Object { $_.type -eq $type })
    if ($sources.Count -eq 0) { Write-Log "No $type sources registered." 'WARN'; return }
    for ($i=0; $i -lt $sources.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$sources[$i].name) }
    $selection = Read-Host 'Source numbers separated by commas (A=all available sources)'
    $ids = @()
    if ($selection.Trim() -ieq 'A') { $ids = @($sources | ForEach-Object { $_.id }) }
    else { foreach ($part in ($selection -split ',')) {
        $n=0
        if ([int]::TryParse($part.Trim(),[ref]$n) -and $n -ge 1 -and $n -le $sources.Count) { $ids += $sources[$n-1].id }
    } }
    if ($ids.Count -eq 0) { Write-Log 'No sources selected; collection was not created.' 'WARN'; return }
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
    $selection = Read-Host 'Collection numbers separated by commas (select one or more, e.g. 1,3)'
    $ids = @()
    foreach ($part in ($selection -split ',')) {
        $n=0
        if ([int]::TryParse($part.Trim(),[ref]$n) -and $n -ge 1 -and $n -le $collections.Count) { $ids += $collections[$n-1].id }
    }
    if ($ids.Count -eq 0) { Write-Log 'No collections selected; profile was not created.' 'WARN'; return }
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

    Write-Host 'Channel content split:'
    Write-Host '1. All content from selected Programme profile'
    Write-Host '2. Genre/group-title match'
    Write-Host '3. Custom label/group-title match'
    Write-Host '4. Single decade (e.g. 1980s)'
    Write-Host '5. Custom decade group (e.g. 1980s,1990s)'
    $splitChoice = Read-Default 'Select split type' '1'
    $splitMode = switch ($splitChoice) { '2' {'Genre'} '3' {'Label'} '4' {'Decade'} '5' {'DecadeGroup'} default {'All'} }
    $filterValue = ''
    $decades = @()
    if ($splitMode -in @('Genre','Label')) {
        $filterValue = Read-Host 'Enter the group-title/label text to match'
        if ([string]::IsNullOrWhiteSpace($filterValue)) { Write-Log 'A match value is required for this channel split.' 'WARN'; return }
    } elseif ($splitMode -eq 'Decade') {
        $filterValue = Read-Host 'Enter decade (e.g. 1980s)'
        if ($filterValue -notmatch '^\d{3}0s$') { Write-Log 'Decade must look like 1980s or 2000s.' 'WARN'; return }
        $decades = @($filterValue)
    } elseif ($splitMode -eq 'DecadeGroup') {
        $rawDecades = Read-Host 'Enter decades separated by commas (e.g. 1980s,1990s)'
        foreach ($part in ($rawDecades -split ',')) { $d=$part.Trim(); if ($d -match '^\d{3}0s$') { $decades += $d } }
        if ($decades.Count -eq 0) { Write-Log 'No valid decades were supplied.' 'WARN'; return }
        $filterValue = $decades -join ','
    }

    $commercialProfiles = @($State.profiles | Where-Object { $_.type -eq 'Commercial' })
    $commercialIds = @()
    if ($commercialProfiles.Count -gt 0) {
        Write-Host 'Optional commercial profiles to merge (commercials are not restricted by the Programme channel split):'
        for ($i=0; $i -lt $commercialProfiles.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$commercialProfiles[$i].name) }
        $cs = Read-Host 'Commercial profile numbers separated by commas, or Enter for none'
        foreach ($part in ($cs -split ',')) {
            $j=0
            if ([int]::TryParse($part.Trim(),[ref]$j) -and $j -ge 1 -and $j -le $commercialProfiles.Count) { $commercialIds += $commercialProfiles[$j-1].id }
        }
    }
    $State.channels = @($State.channels) + @([pscustomobject]@{
        id=[guid]::NewGuid().ToString();name=$name;programmeProfileId=$profiles[$n-1].id
        commercialProfileIds=@($commercialIds);splitMode=$splitMode;filterValue=$filterValue;decades=@($decades);created=(Get-Date).ToString('o')
    })
    Save-State
    Write-Log "Defined programme channel '$name' with split mode '$splitMode'."
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

function Get-LanguageCategories {
    param([string]$Language)
    if ([string]::IsNullOrWhiteSpace($Language)) { return @('Other/Unknown') }
    $map = @{
        'English'=@('en','eng','english','en-us','en-gb','en-ca','en-au')
        'French'=@('fr','fre','fra','french','français','francais')
        'Spanish'=@('es','spa','spanish','español','espanol')
        'German'=@('de','ger','deu','german','deutsch')
        'Japanese'=@('ja','jpn','japanese')
        'Korean'=@('ko','kor','korean')
        'Chinese'=@('zh','chi','zho','chinese','中文','mandarin','cantonese')
        'Portuguese'=@('pt','por','portuguese','português','portugues','pt-br')
        'Russian'=@('ru','rus','russian','русский')
        'Dutch'=@('nl','dut','nld','dutch','nederlands')
    }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($Language -split '[,;|/]+' )) {
        $token = (($raw.Trim().ToLowerInvariant() -replace '\s*\([^)]*\)$','').Trim())
        if (-not $token) { continue }
        $matched = $false
        foreach ($category in $map.Keys) {
            if ($token -in $map[$category]) { $found.Add($category); $matched=$true; break }
        }
        if (-not $matched -and $token -notin @('unknown','und','mul','zxx','mis','n/a','na','none','unspecified','not specified','not known','null')) {
            $found.Add('Other/Unknown')
        }
    }
    if ($found.Count -eq 0) { return @('Other/Unknown') }
    return @($found.ToArray() | Select-Object -Unique)
}

function Test-LanguageAllowed {
    param([string]$Language)
    $settings = $State.languageSettings
    if ($null -eq $settings) { return $true }
    $mode = [string]$settings.mode
    $categories = @(Get-LanguageCategories -Language $Language)
    $selected = @($settings.selected)
    switch ($mode) {
        'English only' { return ($categories -contains 'English') }
        'English plus selected languages' { return (($categories -contains 'English') -or (@($categories | Where-Object { $_ -in $selected }).Count -gt 0)) }
        'Selected languages only' { return (@($categories | Where-Object { $_ -in $selected }).Count -gt 0) }
        'Exclude selected languages' { return (@($categories | Where-Object { $_ -in $selected }).Count -eq 0) }
        default { return $true }
    }
}

function Set-LanguageFiltering {
    $modes = @('English only','English plus selected languages','Selected languages only','All available languages','Exclude selected languages')
    Write-Host 'Language filtering modes:'
    for ($i=0; $i -lt $modes.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$modes[$i]) }
    $choice = Read-Default 'Select mode' '4'
    $n=0
    if (-not [int]::TryParse($choice,[ref]$n) -or $n -lt 1 -or $n -gt $modes.Count) { return }
    $selected = @()
    if ($modes[$n-1] -in @('English plus selected languages','Selected languages only','Exclude selected languages')) {
        $categories = @('English','French','Spanish','German','Japanese','Korean','Chinese','Portuguese','Russian','Dutch','Other/Unknown')
        Write-Host 'Select language categories (comma-separated numbers):'
        for ($i=0; $i -lt $categories.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$categories[$i]) }
        $raw = Read-Host 'Categories (Enter for none)'
        foreach ($part in ($raw -split ',')) { $x=0; if ([int]::TryParse($part.Trim(),[ref]$x) -and $x -ge 1 -and $x -le $categories.Count) { $selected += $categories[$x-1] } }
    }
    $State.languageSettings = [pscustomobject]@{ mode=$modes[$n-1]; selected=@($selected | Select-Object -Unique) }
    Save-State
    Write-Log ("Language filter saved: {0}; selected: {1}. Source M3Us remain unchanged." -f $State.languageSettings.mode,(@($State.languageSettings.selected) -join ', '))
}

function Show-LanguageSettings {
    if ($null -eq $State.languageSettings) { Write-Host 'Language mode: All available languages'; return }
    Write-Host ("Language mode: {0}" -f $State.languageSettings.mode)
    Write-Host ("Selected: {0}" -f (@($State.languageSettings.selected) -join ', '))
    Write-Host 'Filters apply to published libraries, profiles and channels only; complete source M3Us are not filtered.'
}

function Read-M3UEntries {
    param([string[]]$Paths)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $extinf = ''
        foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
            if ($line -like '#EXTINF*') { $extinf=$line; continue }
            if ($line -match '^https?://') {
                $title=$line
                if ($extinf -match ',(.*)$') { $title=$Matches[1] }
                $id=$line; $language=''; $group='Archive TV'; $year=''
                if ($extinf -match 'tvg-id="([^"]*)"') { $id=$Matches[1] }
                if ($extinf -match 'tvg-language="([^"]*)"') { $language=$Matches[1] }
                if ($extinf -match 'group-title="([^"]*)"') { $group=$Matches[1] }
                if ($extinf -match 'tvg-year="(\d{4})"') { $year=$Matches[1] }
                if (-not $year -and $title -match '(?<!\d)((?:19|20)\d{2})(?!\d)') { $year=$Matches[1] }
                if (Test-LanguageAllowed -Language $language) {
                    $entries.Add([pscustomobject]@{identifier=$id;title=$title;url=$line;group=$group;language=$language;year=$year})
                }
                $extinf=''
            }
        }
    }
    $seen=@{}; $unique=New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) { if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) } }
    return $unique.ToArray()
}

function Publish-Profile {
    param($Profile,[string]$Directory,[int]$Limit=0)
    $paths=Get-ProfileSourcePaths -CollectionIds @($Profile.collectionIds)
    if ($paths.Count -eq 0) { Write-Log "Profile '$($Profile.name)' has no accessible source files." 'WARN'; return }
    $entries=@(Read-M3UEntries -Paths $paths)
    if ($Limit -gt 0 -and $entries.Count -gt $Limit) { $entries=@($entries | Get-Random -Count $Limit) }
    $output=Get-UniqueOutputPath -Directory $Directory -BaseName ((Get-SafeFileName $Profile.name) + '-Master-Library') -Extension '.m3u'
    $collectionNames = @($State.collections | Where-Object { $_.id -in @($Profile.collectionIds) } | ForEach-Object { $_.name })
    Write-M3UFile -Path $output -Records $entries -Description ("$($Profile.type) Master Library; profile: $($Profile.name); selected collections: " + ($collectionNames -join ', '))
    Write-Log "Published $($Profile.type) Master Library from profile '$($Profile.name)' ($($entries.Count) entries; $(@($Profile.collectionIds).Count) selected collections): $output"
}

function Test-ChannelProgrammeEntry {
    param($Entry,$Channel)
    $mode = [string](Get-OptionalPropertyValue -Object $Channel -Name 'splitMode' -Default 'All')
    $value = [string](Get-OptionalPropertyValue -Object $Channel -Name 'filterValue' -Default '')
    if ($mode -eq 'All' -or [string]::IsNullOrWhiteSpace($mode)) { return $true }
    $group = [string](Get-OptionalPropertyValue -Object $Entry -Name 'group' -Default '')
    $title = [string](Get-OptionalPropertyValue -Object $Entry -Name 'title' -Default '')
    if ($mode -eq 'Genre') { return ($group -match [regex]::Escape($value) -or $title -match [regex]::Escape($value)) }
    if ($mode -eq 'Label') { return ($group -ieq $value -or $title -match [regex]::Escape($value)) }
    $year = [string](Get-OptionalPropertyValue -Object $Entry -Name 'year' -Default '')
    if ($year -notmatch '^(19|20)\d{2}$') { return $false }
    $decade = ([int]([math]::Floor(([int]$year)/10)*10)).ToString() + 's'
    if ($mode -eq 'Decade') { return ($decade -eq $value) }
    if ($mode -eq 'DecadeGroup') { $allowedDecades=@(Get-OptionalPropertyValue -Object $Channel -Name 'decades' -Default @()); return ($decade -in $allowedDecades) }
    return $true
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
            foreach ($entry in (Read-M3UEntries -Paths @($path))) { if (Test-ChannelProgrammeEntry -Entry $entry -Channel $channel) { $entries.Add($entry) } }
        }
        foreach ($profileId in $channel.commercialProfileIds) {
            $commercial=@($State.profiles | Where-Object { $_.id -eq $profileId }) | Select-Object -First 1
            if ($null -ne $commercial) {
                foreach ($path in (Get-ProfileSourcePaths -CollectionIds @($commercial.collectionIds))) {
                    foreach ($entry in (Read-M3UEntries -Paths @($path))) { $entries.Add($entry) }
                }
            }
        }
        $seen=@{}; $unique=New-Object System.Collections.Generic.List[object]
        foreach ($entry in $entries) { if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) } }
        $result=$unique.ToArray()
        if ($limit -gt 0 -and $result.Count -gt $limit) { $result=@($result | Get-Random -Count $limit) }
        $output=Get-UniqueOutputPath -Directory $PlaylistRoot -BaseName (Get-SafeFileName $channel.name) -Extension '.m3u'
        $channelMode=[string](Get-OptionalPropertyValue -Object $channel -Name 'splitMode' -Default 'All')
        $channelFilter=[string](Get-OptionalPropertyValue -Object $channel -Name 'filterValue' -Default '')
        Write-M3UFile -Path $output -Records $result -Description ("Channel: {0}; split={1}; filter={2}" -f $channel.name,$channelMode,$channelFilter)
        Write-Log "Published channel '$($channel.name)' with $($result.Count) entries (split=$channelMode): $output"
    }
}
function Publish-MasterLibraries {
    if (@($State.profiles).Count -eq 0) { Write-Log 'No profiles exist. Create a profile from one or more selected collections first.' 'WARN'; return }
    foreach ($profile in @($State.profiles)) {
        $directory=if ($profile.type -eq 'Commercial') { $CommercialPlaylistRoot } else { $PlaylistRoot }
        Publish-Profile -Profile $profile -Directory $directory
    }
}

function Publish-CombinedMaster {
    $profiles=@($State.profiles)
    if ($profiles.Count -eq 0) { Write-Log 'No profiles exist. Create Programme or Commercial profiles first.' 'WARN'; return }
    Write-Host 'Select the profiles to combine into one Master Library.'
    for ($i=0; $i -lt $profiles.Count; $i++) { Write-Host ("{0}. [{1}] {2}" -f ($i+1),$profiles[$i].type,$profiles[$i].name) }
    $raw=Read-Host 'Profile numbers separated by commas (A=all, Enter=cancel)'
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $selected=@()
    if ($raw.Trim() -ieq 'A') { $selected=$profiles }
    else {
        foreach ($part in ($raw -split ',')) {
            $n=0
            if ([int]::TryParse($part.Trim(),[ref]$n) -and $n -ge 1 -and $n -le $profiles.Count) { $selected += $profiles[$n-1] }
        }
    }
    $selected=@($selected | Sort-Object -Property id -Unique)
    if ($selected.Count -eq 0) { Write-Log 'No profiles selected; combined Master Library was not published.' 'WARN'; return }
    $all=New-Object System.Collections.Generic.List[object]
    foreach ($profile in $selected) {
        $paths=Get-ProfileSourcePaths -CollectionIds @($profile.collectionIds)
        foreach ($entry in (Read-M3UEntries -Paths $paths)) { $all.Add($entry) }
    }
    $seen=@{}; $unique=New-Object System.Collections.Generic.List[object]
    foreach ($entry in $all) { if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) } }
    $entries=$unique.ToArray()
    if ($entries.Count -gt 1) { $entries=@($entries | Get-Random -Count $entries.Count) }
    $names=@($selected | ForEach-Object { '{0}: {1}' -f $_.type,$_.name })
    $output=Get-UniqueOutputPath -Directory $PlaylistRoot -BaseName 'Combined-Master-Library' -Extension '.m3u'
    Write-M3UFile -Path $output -Records $entries -Description ('Combined Master Library from selected profiles: ' + ($names -join '; '))
    Write-Log "Published combined Master Library from $($selected.Count) selected profiles with $($entries.Count) unique entries: $output"
}

function Manage-PublishedMasterLibraries {
    $files=@()
    $files += @(Get-ChildItem -LiteralPath $PlaylistRoot -Filter '*Master-Library*.m3u' -File -ErrorAction SilentlyContinue | ForEach-Object { $_ })
    $files += @(Get-ChildItem -LiteralPath $CommercialPlaylistRoot -Filter '*Master-Library*.m3u' -File -ErrorAction SilentlyContinue | ForEach-Object { $_ })
    if ($files.Count -eq 0) { Write-Log 'No published Master Library playlists were found.' 'WARN'; return }
    for ($i=0; $i -lt $files.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$files[$i].FullName) }
    $raw=Read-Host 'Select Master Library number to rename/delete (Enter=cancel)'
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $files.Count) { return }
    $file=$files[$n-1]; $action=Read-Default 'R=rename, D=delete' 'R'
    if ($action -match '^(?i:r)$') {
        $newName=Read-Host 'New filename without extension'
        if ([string]::IsNullOrWhiteSpace($newName)) { return }
        $safe=Get-SafeFileName $newName
        $destination=Join-Path $file.DirectoryName ($safe+'.m3u')
        if (Test-Path -LiteralPath $destination) { Write-Log 'That filename already exists; nothing was changed.' 'WARN'; return }
        Move-Item -LiteralPath $file.FullName -Destination $destination -ErrorAction Stop
        $oldManifest=[IO.Path]::ChangeExtension($file.FullName,'.manifest.json')
        if (Test-Path -LiteralPath $oldManifest) { Move-Item -LiteralPath $oldManifest -Destination ([IO.Path]::ChangeExtension($destination,'.manifest.json')) -Force }
        Write-Log "Renamed published Master Library to $destination"
    } elseif ($action -match '^(?i:d)$') {
        $confirm=Read-Host "Type DELETE to remove published playlist '$($file.Name)' (source M3Us and collections are not affected)"
        if ($confirm -ceq 'DELETE') {
            Remove-Item -LiteralPath $file.FullName -Force
            $manifest=[IO.Path]::ChangeExtension($file.FullName,'.manifest.json')
            if (Test-Path -LiteralPath $manifest) { Remove-Item -LiteralPath $manifest -Force }
            Write-Log "Deleted published Master Library output '$($file.FullName)'."
        }
    }
}

function Randomize-MasterLibrariesNow {
    $targets = @()
    $targets += @(Get-ChildItem -LiteralPath $PlaylistRoot -Filter '*Master-Library*.m3u' -File -ErrorAction SilentlyContinue)
    $targets += @(Get-ChildItem -LiteralPath $CommercialPlaylistRoot -Filter '*Master-Library*.m3u' -File -ErrorAction SilentlyContinue)
    if ($targets.Count -eq 0) { Write-Log 'No published Master Library playlists found to randomize.' 'WARN'; return }
    foreach ($file in $targets) {
        $entries = @(Read-M3UEntries -Paths @($file.FullName))
        if ($entries.Count -gt 1) { $entries = @($entries | Get-Random -Count $entries.Count) }
        $backup = Join-Path $MasterBackupRoot ($file.Name+'.'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.bak')
        Copy-Item -LiteralPath $file.FullName -Destination $backup -ErrorAction Stop
        Write-M3UFile -Path $file.FullName -Records $entries -Description ('Randomized Master Library; backup: '+$backup)
        Write-Log "Randomized published Master Library '$($file.Name)' ($($entries.Count) entries). Backup: $backup"
    }
}

function Resume-InterruptedImports {
    $checkpoints=@(Get-ChildItem -LiteralPath $CheckpointRoot -Filter '*.checkpoint.json' -File -ErrorAction SilentlyContinue)
    $available=New-Object System.Collections.Generic.List[object]
    foreach ($file in $checkpoints) {
        try {
            $meta=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace([string]$meta.query) -or [string]::IsNullOrWhiteSpace([string]$meta.outputDirectory)) { continue }
            if ([string]$meta.outputDirectory -notin @($ProgrammeSources,$CommercialSources)) { continue } # Refresh-staging checkpoints resume through the scheduled source refresh path.
            $available.Add([pscustomobject]@{file=$file.FullName;meta=$meta})
        } catch { Write-LogFileOnly "Unreadable checkpoint retained for manual inspection: $($file.FullName)" 'WARN' }
    }
    if ($available.Count -eq 0) { Write-Log 'No resumable Archive.org import checkpoints were found.' 'INFO'; return }
    Write-Host 'Saved import checkpoints:'
    for ($i=0; $i -lt $available.Count; $i++) {
        $m=$available[$i].meta
        Write-Host ("{0}. [{1}] {2} | examined={3} playable={4}" -f ($i+1),$m.status,$m.query,$m.examinedCount,$m.playableCount)
    }
    $raw=Read-Host 'Select checkpoint number to resume (Enter=cancel)'
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $available.Count) { return }
    $selected=$available[$n-1].meta
    $base=[string]$selected.baseName
    $outputDirectory=[string]$selected.outputDirectory
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
    $type=if ($outputDirectory -eq $CommercialSources) {'Commercial'} else {'Programme'}
    $expectedCount=[long](Get-OptionalPropertyValue -Object $selected -Name 'expectedCount' -Default 0)
    $result=Import-ScrapeApi -Query ([string]$selected.query) -OutputDirectory $outputDirectory -BaseName $base -ExpectedCount $expectedCount
    $existing=@($State.sources | Where-Object { $_.path -eq $result.path })
    if ($existing.Count -eq 0) {
        Add-Source -Name $base -Type $type -Path $result.path -Query ([string]$selected.query) -Count ([int]$result.count) -ExpectedCount $expectedCount -LanguageFilterEnabled $false -EndpointMode 'Scrape' -Refreshable $true
    }
    Write-Log "Resumed source import saved: $($result.path) ($($result.count) playable entries)."
}

function Manage-Collections {
    if (@($State.collections).Count -eq 0) { Write-Log 'No collections registered.' 'WARN'; return }
    for ($i=0; $i -lt $State.collections.Count; $i++) { Write-Host ("{0}. [{1}] {2}" -f ($i+1),$State.collections[$i].type,$State.collections[$i].name) }
    $raw=Read-Host 'Select collection number to edit/rename/delete (Enter=cancel)'
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $State.collections.Count) { return }
    $item=$State.collections[$n-1]
    $action=Read-Default 'E=edit source membership, R=rename, D=delete' 'E'
    if ($action -match '^(?i:r)$') {
        $new=Read-Host 'New collection name'
        if (-not [string]::IsNullOrWhiteSpace($new)) { $item.name=$new.Trim(); Save-State; Write-Log 'Collection renamed.' }
    } elseif ($action -match '^(?i:e)$') {
        $sources=@($State.sources | Where-Object {$_.type -eq $item.type})
        if ($sources.Count -eq 0) { Write-Log "No $($item.type) sources are registered." 'WARN'; return }
        Write-Host 'Current source membership:'
        for ($i=0; $i -lt $sources.Count; $i++) { $mark=if ($sources[$i].id -in @($item.sourceIds)) {'[X]'} else {'[ ]'}; Write-Host ("{0}. {1} {2}" -f ($i+1),$mark,$sources[$i].name) }
        $rawSelection=Read-Host 'Enter complete source-number selection separated by commas (A=all, Enter=cancel)'
        if ([string]::IsNullOrWhiteSpace($rawSelection)) { return }
        $ids=@()
        if ($rawSelection.Trim() -ieq 'a') { $ids=@($sources | ForEach-Object {$_.id}) }
        else { foreach ($part in ($rawSelection -split ',')) { $x=0; if ([int]::TryParse($part.Trim(),[ref]$x) -and $x -ge 1 -and $x -le $sources.Count) { $ids += $sources[$x-1].id } } }
        $item.sourceIds=@($ids | Select-Object -Unique); Save-State; Write-Log "Updated source membership for collection '$($item.name)'."
    } elseif ($action -match '^(?i:d)$') {
        $confirm=Read-Host "Type DELETE to remove collection '$($item.name)'"
        if ($confirm -ceq 'DELETE') { $State.collections=@($State.collections | Where-Object {$_.id -ne $item.id}); Save-State; Write-Log 'Collection deleted; source M3Us were not changed.' }
    }
}
function Manage-Profiles {
    if (@($State.profiles).Count -eq 0) { Write-Log 'No profiles registered.' 'WARN'; return }
    for ($i=0; $i -lt $State.profiles.Count; $i++) { Write-Host ("{0}. [{1}] {2}" -f ($i+1),$State.profiles[$i].type,$State.profiles[$i].name) }
    $raw=Read-Host 'Select profile number to edit/rename/delete (Enter=cancel)'
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $State.profiles.Count) { return }
    $item=$State.profiles[$n-1]; $action=Read-Default 'E=edit collections, R=rename, D=delete' 'E'
    if ($action -match '^(?i:r)$') {
        $new=Read-Host 'New profile name'
        if (-not [string]::IsNullOrWhiteSpace($new)) { $item.name=$new.Trim(); Save-State; Write-Log 'Profile renamed.' }
    } elseif ($action -match '^(?i:e)$') {
        $collections=@($State.collections | Where-Object {$_.type -eq $item.type})
        if ($collections.Count -eq 0) { Write-Log "No $($item.type) collections are available." 'WARN'; return }
        for ($i=0; $i -lt $collections.Count; $i++) { $mark=if ($collections[$i].id -in @($item.collectionIds)) {'[X]'} else {'[ ]'}; Write-Host ("{0}. {1} {2}" -f ($i+1),$mark,$collections[$i].name) }
        $rawSelection=Read-Host 'Enter complete collection selection separated by commas (A=all, Enter=cancel)'
        if ([string]::IsNullOrWhiteSpace($rawSelection)) { return }
        $ids=@()
        if ($rawSelection.Trim() -ieq 'a') { $ids=@($collections | ForEach-Object {$_.id}) }
        else { foreach ($part in ($rawSelection -split ',')) { $x=0; if ([int]::TryParse($part.Trim(),[ref]$x) -and $x -ge 1 -and $x -le $collections.Count) { $ids += $collections[$x-1].id } } }
        $item.collectionIds=@($ids | Select-Object -Unique); Save-State; Write-Log "Updated collection membership for profile '$($item.name)'."
    } elseif ($action -match '^(?i:d)$') {
        $confirm=Read-Host "Type DELETE to remove profile '$($item.name)'"
        if ($confirm -ceq 'DELETE') { $State.profiles=@($State.profiles | Where-Object {$_.id -ne $item.id}); Save-State; Write-Log 'Profile deleted; source M3Us and collections were not changed.' }
    }
}
function Publish-SelectedProfile {
    param([ValidateSet('Any','Programme','Commercial')][string]$Type='Any')
    $profiles=if ($Type -eq 'Any') { @($State.profiles) } else { @($State.profiles | Where-Object { $_.type -eq $Type }) }
    if ($profiles.Count -eq 0) { Write-Log "No $Type profiles are available to publish. Create a profile from one or more collections first." 'WARN'; return }
    for ($i=0; $i -lt $profiles.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$profiles[$i].name) }
    $raw=Read-Host "Select $Type profile number to publish as a Master Library (Enter=cancel)"
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $profiles.Count) { return }
    $profile=$profiles[$n-1]
    $directory=if ($profile.type -eq 'Commercial') {$CommercialPlaylistRoot} else {$PlaylistRoot}
    Publish-Profile -Profile $profile -Directory $directory
}

function Manage-Sources {
    if (@($State.sources).Count -eq 0) { Write-Log 'No sources registered.' 'WARN'; return }
    for ($i=0; $i -lt $State.sources.Count; $i++) { Write-Host ("{0}. [{1}] {2} | {3}" -f ($i+1),$State.sources[$i].type,$State.sources[$i].name,$State.sources[$i].path) }
    $raw=Read-Host 'Select source number to unregister (Enter=cancel)'
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $State.sources.Count) { return }
    $item=$State.sources[$n-1]; $confirm=Read-Host "Type UNREGISTER to remove '$($item.name)' from manager only (M3U file remains)"
    if ($confirm -ceq 'UNREGISTER') { $State.sources=@($State.sources | Where-Object {$_.id -ne $item.id}); Save-State; Write-Log 'Source unregistered; source M3U file was preserved.' }
}

function Manage-Channels {
    if (@($State.channels).Count -eq 0) { Write-Log 'No channels defined.' 'WARN'; return }
    for ($i=0; $i -lt $State.channels.Count; $i++) { Write-Host ("{0}. {1}" -f ($i+1),$State.channels[$i].name) }
    $raw=Read-Host 'Select channel number to rename/delete (Enter=cancel)'
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $State.channels.Count) { return }
    $item=$State.channels[$n-1]; $action=Read-Default 'R=rename, D=delete' 'R'
    if ($action -match '^(?i:r)$') { $new=Read-Host 'New channel name'; if (-not [string]::IsNullOrWhiteSpace($new)) { $item.name=$new.Trim(); Save-State; Write-Log 'Channel renamed.' } }
    elseif ($action -match '^(?i:d)$') { $confirm=Read-Host "Type DELETE to remove channel '$($item.name)'"; if ($confirm -ceq 'DELETE') { $State.channels=@($State.channels | Where-Object {$_.id -ne $item.id}); Save-State; Write-Log 'Channel definition deleted; existing playlist files were not changed.' } }
}

function Restore-SourceBackup {
    if (@($State.sources).Count -eq 0) { Write-Log 'No registered sources are available for backup restoration.' 'WARN'; return }
    for ($i=0; $i -lt $State.sources.Count; $i++) { Write-Host ("{0}. [{1}] {2}" -f ($i+1),$State.sources[$i].type,$State.sources[$i].name) }
    $raw=Read-Host 'Select source to restore (Enter=cancel)'
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $State.sources.Count) { return }
    $source=$State.sources[$n-1]
    $base=[IO.Path]::GetFileName([string]$source.path)
    $backups=@(Get-ChildItem -LiteralPath $BackupRoot -Filter ($base+'.*.bak') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($backups.Count -eq 0) { Write-Log "No source-refresh backups found for '$base'." 'WARN'; return }
    for ($i=0; $i -lt $backups.Count; $i++) { Write-Host ("{0}. {1} | {2}" -f ($i+1),$backups[$i].Name,$backups[$i].LastWriteTime) }
    $backupRaw=Read-Host 'Select backup number (Enter=cancel)'
    $b=0; if (-not [int]::TryParse($backupRaw,[ref]$b) -or $b -lt 1 -or $b -gt $backups.Count) { return }
    $selected=$backups[$b-1]
    $header=Get-Content -LiteralPath $selected.FullName -TotalCount 1 -Encoding UTF8
    if ($header -ne '#EXTM3U') { throw 'Selected backup failed M3U header validation; current source was not changed.' }
    $confirm=Read-Host "Type RESTORE to replace '$($source.path)' with '$($selected.Name)'"
    if ($confirm -cne 'RESTORE') { Write-Log 'Source backup restore cancelled.' 'WARN'; return }
    $safety=Join-Path $BackupRoot ($base+'.pre-restore.'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.bak')
    Copy-Item -LiteralPath ([string]$source.path) -Destination $safety -ErrorAction Stop
    Copy-Item -LiteralPath $selected.FullName -Destination ([string]$source.path) -Force -ErrorAction Stop
    $backupManifest=$selected.FullName+'.manifest.json'
    $sourceManifest=[IO.Path]::ChangeExtension([string]$source.path,'.manifest.json')
    if (Test-Path -LiteralPath $backupManifest) { Copy-Item -LiteralPath $backupManifest -Destination $sourceManifest -Force }
    Write-Log "Restored source '$($source.name)' from '$($selected.Name)'. Pre-restore safety copy: $safety"
}

function Show-CheckpointStatus {
    $files=@(Get-ChildItem -LiteralPath $CheckpointRoot -Filter '*.checkpoint.json' -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Write-Host 'No import checkpoints found.'; return }
    foreach ($file in $files) {
        try { $m=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; Write-Host ("[{0}] {1} | examined={2} playable={3} | {4}" -f $m.status,$m.query,$m.examinedCount,$m.playableCount,$file.Name) }
        catch { Write-Host ("[UNREADABLE] {0}" -f $file.Name) }
    }
}

function Show-RecentLogs {
    $latest=Get-ChildItem -LiteralPath $LogRoot -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $latest) { Write-Host 'No manager logs found.'; return }
    Write-Host "Latest log: $($latest.FullName)"
    Get-Content -LiteralPath $latest.FullName -Tail 30 -Encoding UTF8
}

function Show-SystemDiagnostics {
    Write-Host ("PowerShell: {0}" -f $PSVersionTable.PSVersion)
    Write-Host ("Project root: {0}" -f $ProjectRoot)
    Write-Host ("Project root exists: {0}" -f (Test-Path -LiteralPath $ProjectRoot))
    $drive=Get-PSDrive -Name D -ErrorAction SilentlyContinue
    if ($null -ne $drive) { Write-Host ("D: free space (GB): {0:N1}" -f ($drive.Free/1GB)) } else { Write-Host 'D: drive is not available.' }
    Write-Host ("Runtime source exists: {0}" -f (Test-Path -LiteralPath $RuntimePath))
    Write-Host ("Manager state exists: {0}" -f (Test-Path -LiteralPath $StateFile))
    Write-Host ("Checkpoint files: {0}" -f @(Get-ChildItem -LiteralPath $CheckpointRoot -Filter '*.checkpoint.json' -File -ErrorAction SilentlyContinue).Count)
    Write-Host ("Source refresh backups: {0}" -f @(Get-ChildItem -LiteralPath $BackupRoot -Filter '*.bak' -File -ErrorAction SilentlyContinue).Count)
}

function Show-SourceMenu {
    do { Write-Host "`n--- STEP 1: Import Full Source M3Us ---`n1 Import full Archive.org source M3U`n2 Register existing source M3U`n3 Resume interrupted import`n4 Manage/unregister sources`n5 Refresh imported sources now`n6 Show source/updater status`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Import-ArchiveSource} '2' {Register-ExistingSource} '3' {Resume-InterruptedImports} '4' {Manage-Sources} '5' {Invoke-RefreshAllSources} '6' {Show-Overview;Show-RefreshStatus} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-MasterMenu {
    do { Write-Host "`n--- STEP 4: Publish Master Libraries ---`nMaster Libraries are built from profiles. Each profile contains only the collections you selected.`n1 Publish a Programme Master Library from a selected profile`n2 Publish a Commercial Master Library from a selected profile`n3 Publish all profiles as separate Master Libraries`n4 Publish one Combined Master Library from selected profiles`n5 Manage/rename/delete published Master Libraries`n6 Randomize published Master Libraries now`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Publish-SelectedProfile -Type Programme} '2' {Publish-SelectedProfile -Type Commercial} '3' {Publish-MasterLibraries} '4' {Publish-CombinedMaster} '5' {Manage-PublishedMasterLibraries} '6' {Randomize-MasterLibrariesNow} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-CollectionMenu {
    do { Write-Host "`n--- STEP 2: Create and Manage Collections ---`nCreate a Programme or Commercial collection, then select only the imported source M3Us that belong in it.`n1 Create collection and select source M3Us`n2 Manage/edit source membership/rename/delete collections`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Create-Collection} '2' {Manage-Collections} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-ProfileMenu {
    do { Write-Host "`n--- STEP 3: Create Profiles from Collections ---`nProfiles combine one or more selected Programme or Commercial collections.`n1 Configure language filtering (applies downstream; source M3Us remain complete)`n2 Create Programme or Commercial profile from selected collections`n3 Manage/edit/rename/delete profiles`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Set-LanguageFiltering} '2' {Create-Profile} '3' {Manage-Profiles} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-ChannelMenu {
    do { Write-Host "`n--- STEP 5: Channel Management ---`n1 Define programme channel`n2 Manage/rename/delete channels`n3 Publish operational channel playlists`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Define-Channel} '2' {Manage-Channels} '3' {Publish-Channels} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-PublishMenu {
    do { Write-Host "`n--- STEP 6: Publish Channel Playlists ---`nMaster Libraries are published in Step 4.`n1 Publish/update operational channel playlists`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Publish-Channels} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
}

function Show-RandomizationMenu {
    do { Write-Host "`n--- Randomization ---`n1 Randomize Programme Now`n2 Randomize Commercials Now`n3 Randomize Both Now`n4 Randomize published Master Libraries`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Randomize-PlaybackNow -Group Programme} '2' {Randomize-PlaybackNow -Group Commercial} '3' {Randomize-PlaybackNow -Group Both} '4' {Randomize-MasterLibrariesNow} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-SchedulingMenu {
    do { Write-Host "`n--- Scheduling and Automation ---`n1 Schedule imported-source updates`n2 Refresh imported sources now`n3 Show updater status`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Register-SourceRefreshSchedule} '2' {Invoke-RefreshAllSources} '3' {Show-RefreshStatus} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-LiveMenu {
    do { Write-Host "`n--- Live Playback ---`n1 Install/update runtime playback controls (backup + Python syntax check)`n2 Randomize Programme Now`n3 Randomize Commercials Now`n4 Randomize Both Now`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {$confirm=Read-Host 'This backs up and updates the Python runtime on D: only. No Docker restart/rebuild. Type YES to continue'; if($confirm -ceq 'YES'){Install-LiveRuntimeIntegration}} '2' {Randomize-PlaybackNow -Group Programme} '3' {Randomize-PlaybackNow -Group Commercial} '4' {Randomize-PlaybackNow -Group Both} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-LanguageMenu {
    do { Write-Host "`n--- Language and Filtering Settings ---`n1 Configure language filtering`n2 Show current language settings`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Set-LanguageFiltering} '2' {Show-LanguageSettings} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-SystemMenu {
    do { Write-Host "`n--- System and Maintenance ---`n1 Manager overview`n2 Restore source from backup`n3 Checkpoint and recovery status`n4 Recent log entries`n5 System diagnostics`n6 Show refresh status`n7 Show language settings`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Show-Overview} '2' {Restore-SourceBackup} '3' {Show-CheckpointStatus} '4' {Show-RecentLogs} '5' {Show-SystemDiagnostics} '6' {Show-RefreshStatus} '7' {Show-LanguageSettings} '0' {} default {Write-Host 'Invalid selection.'} }
    } while ($c -ne '0')
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

function Enter-ManagerOperationLock {
    try {
        $stream = [System.IO.File]::Open($ManagerLockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(("PID={0}; Started={1}" -f $PID,(Get-Date).ToString('o')))
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
        return $stream
    } catch {
        if (Test-Path -LiteralPath $ManagerLockPath) {
            $lockText = Get-Content -LiteralPath $ManagerLockPath -Raw -ErrorAction SilentlyContinue
            $pidMatch = [regex]::Match([string]$lockText,'PID=(\d+)')
            $ownerPid = 0
            if ($pidMatch.Success) { [void][int]::TryParse($pidMatch.Groups[1].Value,[ref]$ownerPid) }
            $owner = if ($ownerPid -gt 0) { Get-Process -Id $ownerPid -ErrorAction SilentlyContinue } else { $null }
            if ($ownerPid -gt 0 -and $null -eq $owner) {
                Remove-Item -LiteralPath $ManagerLockPath -Force -ErrorAction SilentlyContinue
                try {
                    $stream = [System.IO.File]::Open($ManagerLockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes(("PID={0}; Started={1}" -f $PID,(Get-Date).ToString('o')))
                    $stream.Write($bytes,0,$bytes.Length); $stream.Flush()
                    return $stream
                } catch { }
            }
        }
        throw "Another Archive TV import, refresh, or randomization operation appears to be running (lock: $ManagerLockPath). Wait for it to finish; do not start a second import window."
    }
}

function Exit-ManagerOperationLock {
    param($LockStream)
    if ($null -ne $LockStream) { try { $LockStream.Dispose() } catch {} }
    if (Test-Path -LiteralPath $ManagerLockPath) { Remove-Item -LiteralPath $ManagerLockPath -Force -ErrorAction SilentlyContinue }
}

function Get-EntriesForProfile {
    param($Profile)
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($path in (Get-ProfileSourcePaths -CollectionIds @($Profile.collectionIds))) {
        foreach ($entry in (Read-M3UEntries -Paths @($path))) { $all.Add($entry) }
    }
    $seen=@{}; $unique=New-Object System.Collections.Generic.List[object]
    foreach ($entry in $all) { if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) } }
    return $unique.ToArray()
}

function Get-ChannelSlug {
    param([string]$Name)
    $slug = [regex]::Replace(([string]$Name).ToLowerInvariant(),'[^a-z0-9]+','-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'channel' }
    return $slug
}

function Write-PlaybackControl {
    param([string]$ChannelSlug,[string]$Action,[string]$ProgrammePlaylist='',[string]$CommercialPlaylist='')
    $channelSystem = Join-Path (Join-Path $ProjectRoot 'system\channels') $ChannelSlug
    if (-not (Test-Path -LiteralPath $channelSystem)) { New-Item -ItemType Directory -Path $channelSystem -Force | Out-Null }
    $path = Join-Path $channelSystem 'playout_control.json'
    $temp = $path + '.tmp'
    $control = [pscustomobject]@{action=$Action;nonce=[guid]::NewGuid().ToString();requested=(Get-Date).ToString('o');programme_playlist=$ProgrammePlaylist;commercial_playlist=$CommercialPlaylist}
    $control | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Randomize-PlaybackNow {
    param([ValidateSet('Programme','Commercial','Both')][string]$Group='Both')
    $lock = Enter-ManagerOperationLock
    try {
        $programmeTotal=0; $commercialTotal=0; $channelCount=0
        $globalProgramme = New-Object System.Collections.Generic.List[object]
        $globalCommercial = New-Object System.Collections.Generic.List[object]
        foreach ($source in @($State.sources)) {
            if (-not (Test-Path -LiteralPath ([string]$source.path))) { continue }
            $entries = Read-M3UEntries -Paths @([string]$source.path)
            if ($source.type -eq 'Commercial') { foreach ($e in $entries) { $globalCommercial.Add($e) } }
            else { foreach ($e in $entries) { $globalProgramme.Add($e) } }
        }
        $buckets = @()
        if ($Group -in @('Programme','Both')) { $buckets += @{type='Programme';list=$globalProgramme} }
        if ($Group -in @('Commercial','Both')) { $buckets += @{type='Commercial';list=$globalCommercial} }
        foreach ($bucket in $buckets) {
            $seen=@{}; $unique=New-Object System.Collections.Generic.List[object]
            foreach ($entry in $bucket.list) { if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) } }
            $arr=$unique.ToArray()
            if ($arr.Count -gt 1) { $arr=@($arr | Get-Random -Count $arr.Count) }
            $target=Join-Path $RandomizedRoot ([string]$bucket.type)
            if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
            $out=Join-Path $target (([string]$bucket.type)+'-Randomized-Now.m3u')
            Write-M3UFile -Path $out -Records $arr -Description (([string]$bucket.type)+' randomized playback snapshot; source libraries unchanged')
            if ($bucket.type -eq 'Programme') { $programmeTotal=$arr.Count } else { $commercialTotal=$arr.Count }
        }
        foreach ($channel in @($State.channels)) {
            $programme=@($State.profiles | Where-Object { $_.id -eq $channel.programmeProfileId }) | Select-Object -First 1
            if ($null -eq $programme) { continue }
            $pEntries=@(Get-EntriesForProfile -Profile $programme)
            $cEntries=New-Object System.Collections.Generic.List[object]
            foreach ($profileId in @($channel.commercialProfileIds)) {
                $profile=@($State.profiles | Where-Object { $_.id -eq $profileId }) | Select-Object -First 1
                if ($null -ne $profile) { foreach ($e in (Get-EntriesForProfile -Profile $profile)) { $cEntries.Add($e) } }
            }
            if ($Group -in @('Programme','Both') -and $pEntries.Count -gt 1) { $pEntries=@($pEntries | Get-Random -Count $pEntries.Count) }
            $cArr=$cEntries.ToArray(); if ($Group -in @('Commercial','Both') -and $cArr.Count -gt 1) { $cArr=@($cArr | Get-Random -Count $cArr.Count) }
            $slug=Get-ChannelSlug -Name ([string]$channel.name)
            $channelOut=Join-Path $RandomizedRoot $slug
            if (-not (Test-Path -LiteralPath $channelOut)) { New-Item -ItemType Directory -Path $channelOut -Force | Out-Null }
            $programmeHostPath = ''
            $commercialHostPath = ''
            if ($Group -in @('Programme','Both')) {
                $programmeHostPath = Join-Path $channelOut 'programmes-randomized.m3u'
                Write-M3UFile -Path $programmeHostPath -Records $pEntries -Description ('Programme playback order for '+$channel.name)
            }
            if ($Group -in @('Commercial','Both')) {
                $commercialHostPath = Join-Path $channelOut 'commercials-randomized.m3u'
                Write-M3UFile -Path $commercialHostPath -Records $cArr -Description ('Commercial playback order for '+$channel.name)
            }
            $action = if ($Group -eq 'Programme') { 'shuffle_programmes' } elseif ($Group -eq 'Commercial') { 'shuffle_commercials' } else { 'shuffle_both' }
            $programmeContainerPath = if ($programmeHostPath) { '/data/m3u/Archive_TV_System/live/randomized/'+$slug+'/programmes-randomized.m3u' } else { '' }
            $commercialContainerPath = if ($commercialHostPath) { '/data/m3u/Archive_TV_System/live/randomized/'+$slug+'/commercials-randomized.m3u' } else { '' }
            Write-PlaybackControl -ChannelSlug $slug -Action $action -ProgrammePlaylist $programmeContainerPath -CommercialPlaylist $commercialContainerPath
            $channelCount++
        }
        Write-Log "Randomize $Group Now complete. Programme entries=$programmeTotal; commercial entries=$commercialTotal; channel control requests=$channelCount. Source and master libraries were not changed."
        if (-not (Test-Path -LiteralPath $RuntimePath)) { Write-Log "Live runtime source not found at $RuntimePath. Randomized M3U snapshots were created; live control requests require the runtime integration to be installed." 'WARN' }
        elseif (-not (Select-String -LiteralPath $RuntimePath -Pattern 'ARCHIVE_TV_PLAYOUT_CONTROL_V5' -Quiet)) { Write-Log 'Live runtime integration is not installed yet. Snapshots and control requests were written, but live playback will not react until option 13 is applied.' 'WARN' }
    } finally { Exit-ManagerOperationLock -LockStream $lock }
}

function Invoke-RefreshAllSources {
    param([switch]$Scheduled)
    $lock = Enter-ManagerOperationLock
    try {
        $refreshable = @($State.sources | Where-Object { $_.refreshable -and -not [string]::IsNullOrWhiteSpace([string]$_.query) -and (Test-Path -LiteralPath ([string]$_.path)) })
        if ($refreshable.Count -eq 0) { Write-Log 'No registered Archive.org query sources are eligible for automatic refresh.' 'WARN'; return }
        foreach ($source in $refreshable) {
            $script:ExcludeNonEnglish = $false # Never filter full source refreshes
            if ([string]::IsNullOrWhiteSpace([string]$source.pendingRefreshBase)) {
                $source.pendingRefreshBase = Get-SafeFileName ('Refresh_'+[string]$source.id+'_'+(Get-Date -Format 'yyyyMMddHHmmss'))
                Save-State
            }
            $base = [string]$source.pendingRefreshBase
            try {
                Write-Log "Refreshing complete $($source.type) source '$($source.name)' using its saved query; all languages are retained."
                $result = Import-ScrapeApi -Query ([string]$source.query) -OutputDirectory $RefreshStaging -BaseName $base -ExpectedCount ([long]$source.expectedCount)
                if (-not (Test-Path -LiteralPath $result.path -PathType Leaf)) { throw 'Refresh import did not produce a complete M3U file.' }
                $header = Get-Content -LiteralPath $result.path -TotalCount 1 -Encoding UTF8
                if ($header -ne '#EXTM3U') { throw 'Refresh output failed M3U header validation; existing source was not replaced.' }
                $backupName = [IO.Path]::GetFileName([string]$source.path) + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak'
                $backupPath = Join-Path $BackupRoot $backupName
                Copy-Item -LiteralPath ([string]$source.path) -Destination $backupPath -ErrorAction Stop
                $oldManifest = [IO.Path]::ChangeExtension([string]$source.path,'.manifest.json')
                if (Test-Path -LiteralPath $oldManifest) { Copy-Item -LiteralPath $oldManifest -Destination ($backupPath+'.manifest.json') -Force }
                $replacement = [string]$source.path + '.refresh.tmp'
                Copy-Item -LiteralPath $result.path -Destination $replacement -Force -ErrorAction Stop
                Move-Item -LiteralPath $replacement -Destination ([string]$source.path) -Force -ErrorAction Stop
                $newManifest = [IO.Path]::ChangeExtension([string]$result.path,'.manifest.json')
                if (Test-Path -LiteralPath $newManifest) { Copy-Item -LiteralPath $newManifest -Destination $oldManifest -Force }
                $source.itemCount = [int]$result.count
                $source.lastRefresh = (Get-Date).ToString('o')
                $source.lastRefreshStatus = 'complete'
                $source.pendingRefreshBase = ''
                Save-State
                Write-Log "Updated source '$($source.name)' in place. Backup: $backupPath; new playable entries: $($result.count)."
            } catch {
                $source.lastRefresh = (Get-Date).ToString('o')
                $source.lastRefreshStatus = 'failed: '+$_.Exception.Message
                Save-State
                Write-Log "Refresh failed for '$($source.name)'. Existing source M3U was preserved; checkpoint retained for resume. $($_.Exception.Message)" 'ERROR'
            }
        }
    } finally { Exit-ManagerOperationLock -LockStream $lock }
}

function Register-SourceRefreshSchedule {
    $frequency = Read-Default 'Refresh frequency (Daily, Weekly, Monthly)' 'Weekly'
    if ($frequency -notin @('Daily','Weekly','Monthly')) { Write-Log 'Invalid refresh frequency.' 'WARN'; return }
    $timeText = Read-Default 'Local run time (HH:mm)' '03:00'
    $runTime = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($timeText,'HH:mm',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$runTime)) { throw 'Enter schedule time as HH:mm, for example 03:00.' }
    Import-Module ScheduledTasks -ErrorAction Stop
    $at = Get-Date -Hour $runTime.Hour -Minute $runTime.Minute -Second 0
    if ($frequency -eq 'Daily') { $trigger = New-ScheduledTaskTrigger -Daily -At $at }
    elseif ($frequency -eq 'Monthly') { $trigger = New-ScheduledTaskTrigger -Monthly -DaysOfMonth 1 -At $at }
    else { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $at }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ScheduledRefresh' -f $PSCommandPath
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $arguments
    Register-ScheduledTask -TaskName 'ArchiveTV-Imported-Source-Refresh' -Action $action -Trigger $trigger -Description 'Refresh Archive TV registered Archive.org source M3Us; backups and checkpoints remain on D:.' -Force | Out-Null
    [pscustomobject]@{frequency=$frequency;time=$timeText;taskName='ArchiveTV-Imported-Source-Refresh';updated=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $ScheduleConfigPath -Encoding UTF8
    Write-Log "Scheduled imported-source refresh registered: $frequency at $timeText (local time). Computer must be on and able to run the task."
}

function Show-RefreshStatus {
    $task = Get-ScheduledTask -TaskName 'ArchiveTV-Imported-Source-Refresh' -ErrorAction SilentlyContinue
    if ($null -eq $task) { Write-Host 'Scheduled updater: not registered.' } else { Write-Host ("Scheduled updater: {0} ({1})" -f $task.State,$task.TaskName) }
    foreach ($source in @($State.sources)) {
        Write-Host ("[{0}] {1} | Refreshable={2} | Last={3} | Status={4}" -f $source.type,$source.name,$source.refreshable,$source.lastRefresh,$source.lastRefreshStatus)
    }
}

function Install-LiveRuntimeIntegration {
    if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { throw "Runtime source not found: $RuntimePath" }
    $original = (Get-Content -LiteralPath $RuntimePath -Raw -Encoding UTF8).Replace("`r`n","`n")
    if ($original -match 'ARCHIVE_TV_PLAYOUT_CONTROL_V5') { Write-Log 'Live runtime integration is already installed.'; return }
    $oldLoop = "    last_ad=None`n`n    while True:`n        if pi>=len(programs):"
    $newLoop = @'
    last_ad=None
    ad_index=0
    manager_ads_override=False
    # ARCHIVE_TV_PLAYOUT_CONTROL_V5: manager-issued shuffle requests are read between items.
    control_file=SYSTEM/"playout_control.json"
    last_control_nonce=""

    while True:
        try:
            if control_file.is_file():
                control=json.loads(control_file.read_text(encoding="utf-8"))
                nonce=str(control.get("nonce", ""))
                if nonce and nonce != last_control_nonce:
                    action=str(control.get("action", ""))
                    if action in ("shuffle_programmes", "shuffle_both"):
                        programme_path=str(control.get("programme_playlist", ""))
                        loaded_programmes=[]
                        if programme_path and Path(programme_path).is_file():
                            loaded_programmes=[line.strip() for line in Path(programme_path).read_text(encoding="utf-8-sig",errors="ignore").splitlines() if line.strip().startswith(("http://","https://"))]
                        if loaded_programmes:
                            programs=list(dict.fromkeys(loaded_programmes))
                            total=len(programs)
                        else:
                            random.shuffle(programs)
                        pi=0
                        log("Manager command: programme playback order randomized; %d URLs loaded."%len(programs))
                    if action in ("shuffle_commercials", "shuffle_both"):
                        commercial_path=str(control.get("commercial_playlist", ""))
                        loaded_commercials=[]
                        if commercial_path and Path(commercial_path).is_file():
                            loaded_commercials=[line.strip() for line in Path(commercial_path).read_text(encoding="utf-8-sig",errors="ignore").splitlines() if line.strip().startswith(("http://","https://"))]
                        if loaded_commercials:
                            ad_pool=list(dict.fromkeys(loaded_commercials))
                            manager_ads_override=True
                        else:
                            manager_ads_override=False
                            with ad_lock:
                                ad_pool=list(ad_state["urls"])
                                generation=ad_state["generation"]
                        random.shuffle(ad_pool)
                        ad_index=0
                        last_ad=None
                        log("Manager command: commercial playback order randomized; %d URLs loaded."%len(ad_pool))
                    last_control_nonce=nonce
        except Exception as e:
            log("Playback control read failed: "+str(e)[:160])

        if pi>=len(programs):
'@
    if (-not $original.Contains($oldLoop)) { throw 'Runtime loop signature did not match the inspected source. No runtime file was changed.' }
    $patched = $original.Replace($oldLoop,$newLoop)
    $oldAdPool = @'
            ad_pool=current
            random.shuffle(ad_pool)
            generation=current_generation
            last_ad=None
'@
    $newAdPool = @'
            if not manager_ads_override:
                ad_pool=current
                random.shuffle(ad_pool)
                ad_index=0
                last_ad=None
            generation=current_generation
'@
    if (-not $patched.Contains($oldAdPool)) { throw 'Commercial pool generation signature did not match. No runtime file was changed.' }
    $patched = $patched.Replace($oldAdPool,$newAdPool)
    $oldAd = @'
            choices=[item for item in ad_pool if item!=last_ad]
            if not choices:
                choices=list(ad_pool)
            if not choices:
                break
            chosen=random.choice(choices)
            if play_one(chosen,True):
                last_ad=chosen
'@
    $newAd = @'
            if not ad_pool:
                break
            if ad_index>=len(ad_pool):
                random.shuffle(ad_pool)
                ad_index=0
                log("Commercial list reshuffled at end of its independent playback cycle.")
            if len(ad_pool)>1 and ad_pool[ad_index]==last_ad:
                swap=(ad_index+1)%len(ad_pool)
                ad_pool[ad_index],ad_pool[swap]=ad_pool[swap],ad_pool[ad_index]
            chosen=ad_pool[ad_index]
            ad_index+=1
            if play_one(chosen,True):
                last_ad=chosen
'@
    if (-not $patched.Contains($oldAd)) { throw 'Commercial selection signature did not match the inspected source. No runtime file was changed.' }
    $patched = $patched.Replace($oldAd,$newAd)
    $temp = $RuntimePath + '.v5.tmp'
    Set-Content -LiteralPath $temp -Value $patched -Encoding UTF8
    $python = Get-Command py -ErrorAction SilentlyContinue
    $pythonArgs = @('-3','-m','py_compile',$temp)
    if ($null -eq $python) { $python = Get-Command python -ErrorAction SilentlyContinue; $pythonArgs = @('-m','py_compile',$temp) }
    if ($null -eq $python) { Remove-Item -LiteralPath $temp -Force; throw 'Python was not found; runtime patch was not applied. Install/locate Python, then retry.' }
    & $python.Source @pythonArgs
    if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $temp -Force; throw 'Python syntax validation failed; runtime source was not changed.' }
    $backup = Join-Path $BackupRoot ('playout_D_runtime_V4_20261117.py.'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak')
    Copy-Item -LiteralPath $RuntimePath -Destination $backup -ErrorAction Stop
    Move-Item -LiteralPath $temp -Destination $RuntimePath -Force -ErrorAction Stop
    Write-Log "Live runtime integration installed with backup: $backup. Docker was not restarted or modified."
}

Initialize-ManagerFolders
$script:State = Load-State
Write-Log 'Fresh v5.4 started. Existing manager state is preserved and migrated; new installations begin empty.'

if ($ScheduledRefresh) {
    try { Invoke-RefreshAllSources -Scheduled }
    catch { Write-Log $_.Exception.Message 'ERROR'; exit 2 }
    Write-Log 'Scheduled source refresh run finished.'
    exit 0
}

do {
    Write-Host ''
    Write-Host '===== Archive TV Source Library Manager - Fresh v5.4 =====' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'INITIAL CONTENT WORKFLOW (follow in order)'
    Write-Host '  1 Import full Archive.org source M3Us'
    Write-Host '  2 Create Programme or Commercial collections and select source M3Us'
    Write-Host '  3 Create profiles from one or more selected collections'
    Write-Host '  4 Publish Master Libraries from selected profiles'
    Write-Host '  5 Channel Management'
    Write-Host '  6 Publish operational channel playlists'
    Write-Host ''
    Write-Host 'ONGOING MANAGEMENT (run whenever needed)'
    Write-Host '  7 Randomization'
    Write-Host '  8 Scheduling and Automation'
    Write-Host '  9 Live Playback'
    Write-Host ' 10 System and Maintenance'
    Write-Host ''
    Write-Host '  0 Exit'
    $choice=Read-Host 'Select section (blank=exit)'
    if ([string]::IsNullOrWhiteSpace([string]$choice)) { break }
    try {
        switch ($choice) {
            '1' { Show-SourceMenu }
            '2' { Show-CollectionMenu }
            '3' { Show-ProfileMenu }
            '4' { Show-MasterMenu }
            '5' { Show-ChannelMenu }
            '6' { Show-PublishMenu }
            '7' { Show-RandomizationMenu }
            '8' { Show-SchedulingMenu }
            '9' { Show-LiveMenu }
            '10' { Show-SystemMenu }
            '0' { break }
            default { Write-Host 'Invalid selection.' }
        }
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        if ($_.ScriptStackTrace) { Write-Log ($_.ScriptStackTrace -replace '[\r\n]+',' | ') 'ERROR' }
    }
} while ($choice -ne '0')

Write-Log 'Fresh v5.4 exited.' 
