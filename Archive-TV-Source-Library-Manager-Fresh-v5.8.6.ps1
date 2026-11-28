#requires -Version 5.1
param([switch]$ScheduledRefresh)

<#
ARCHIVE TV SOURCE LIBRARY MANAGER - FRESH V5.8
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
- v5.5 workflow: complete source M3Us -> named Master Libraries with explicit source membership -> profiles from selected Master Libraries -> channel playlists.
- No separate Collections stage; legacy collections are migrated into Master Libraries.
- Scheduled source refreshes cascade to dependent Master Libraries, profiles and channels only after successful source validation.
- v5.6: source update management supports per-source enable/disable and manually selecting one or many sources to refresh; scheduled runs refresh enabled sources only.
- v5.7: source refresh selection is surfaced in Master Library Management; refresh one library's selected sources or all refreshable registered sources, then cascade to every dependent library/profile/channel.
- v5.8: language filtering is configured independently inside each Master Library; source M3Us remain complete and profiles inherit the filtered library output.
- Language filters apply downstream; complete source imports and refreshes retain every language.
- Channel splits support genre/group, custom label, decade, and custom decade groups.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProjectRoot = 'D:\Archive-TV\Archive_TV_System'
$ArchiveRoot = Join-Path $ProjectRoot 'archived_large_M3Us'
$ProgrammeSources = Join-Path $ArchiveRoot 'programme-sources'
$CommercialSources = Join-Path $ArchiveRoot 'commercial-sources'
$MasterLibraryRoot = Join-Path $ArchiveRoot 'master-libraries'
$ProfileLibraryRoot = Join-Path $ArchiveRoot 'profile-libraries'
$CheckpointRoot = Join-Path $ArchiveRoot 'checkpoints'
$PlaylistRoot = Join-Path $ProjectRoot 'channel-playlists'
$CommercialPlaylistRoot = Join-Path $ProjectRoot 'commercial-playlists'
$StateRoot = Join-Path $ProjectRoot 'system\source-library-manager-v4' # Preserve and migrate existing v4 state
$StateFile = Join-Path $StateRoot 'manager-state.json'
$LogRoot = Join-Path $ProjectRoot 'logs'
$LogFile = Join-Path $LogRoot ("Fresh-v5.8.5-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$ScrapeEndpoint = 'https://archive.org/services/search/v1/scrape'
$AdvancedEndpoint = 'https://archive.org/advancedsearch.php'
$MetadataEndpoint = 'https://archive.org/metadata/'
$BackupRoot = Join-Path $ProjectRoot 'backups\source-refresh'
$MasterBackupRoot = Join-Path $ProjectRoot 'backups\master-libraries'
$RefreshStaging = Join-Path $ArchiveRoot 'refresh-staging'
$RandomizedRoot = Join-Path $ProjectRoot 'live\randomized'
$RuntimePath = Join-Path $ProjectRoot 'scripts\playout_D_runtime_V4_20261117.py'
$ManagerLockPath = Join-Path $StateRoot 'manager-operation.lock'
$HierarchyStatusPath = Join-Path $StateRoot 'hierarchy-status.json'
$ScheduleConfigPath = Join-Path $StateRoot 'refresh-schedule.json'
$script:ExcludeNonEnglish = $false
$script:NoVideoSkipped = 0
$script:MetadataFailures = 0


# v5.8.3 console colour layer. Explicit per-message colours remain respected.
function Get-ArchiveConsoleColor {
    param([string]$Text)
    # Operational state takes priority over the subject category.
    if ($Text -match '(?i)\b(ERROR|FAILED|FAILURE|EXCEPTION)\b') { return [ConsoleColor]::Red }
    if ($Text -match '(?i)\b(WARNING|WARN|PENDING|SCHEDULED|AWAITING|DUE|STALE|IN PROGRESS|REFRESHING|UPDATING)\b') { return [ConsoleColor]::Yellow }
    if ($Text -match '(?i)\b(DISABLED|PAUSED|INACTIVE|NOT REGISTERED)\b') { return [ConsoleColor]::DarkGray }
    if ($Text -match '(?i)\b(SUCCESS|COMPLETE|COMPLETED|PASS|ACTIVE|UPDATED)\b') { return [ConsoleColor]::Green }

    # Work categories: sources/querying turquoise; libraries green; profiles purple; channels teal.
    if ($Text -match '(?i)(SOURCE MANAGEMENT|SOURCE M3U|ARCHIVE\.ORG SOURCE|SOURCES:|REGISTER SOURCE|SOURCE REGISTRATION|SCRAP(E|ING)|QUERY(ING)?|SEARCH(ING)?|SEARCH RESULTS URL|TRANSLATED ARCHIVE\.ORG QUERY|ARCHIVE\.ORG IMPORT)') { return [ConsoleColor]::Cyan }
    if ($Text -match '(?i)(MASTER LIBRARY|MASTER LIBRARIES|MASTER \[)') { return [ConsoleColor]::Green }
    if ($Text -match '(?i)(PROFILE MANAGEMENT|PROFILES?:|PROFILES? FROM|PROFILE \[|LANGUAGE FILTER|LANGUAGE AND FILTERING|GENRE FILTER|DECADE FILTER)') { return [ConsoleColor]::Magenta }
    if ($Text -match '(?i)(CHANNEL MANAGEMENT|CHANNEL PLAYLIST|CHANNELS:|LIVE PLAYBACK)') { return [ConsoleColor]::DarkCyan }
    if ($Text -match '(?i)(SCHEDUL|AUTOMATION|REFRESH STATUS|UPDATER|HIERARCHY UPDATE)') { return [ConsoleColor]::Yellow }
    if ($Text -match '(?i)(RANDOMIZATION|RANDOMIZE|SHUFFLE)') { return [ConsoleColor]::Blue }
    if ($Text -match '(?i)(SYSTEM AND MAINTENANCE|DIAGNOSTIC|OVERVIEW)') { return [ConsoleColor]::DarkGray }
    if ($Text -match '(?i)(INITIAL CONTENT WORKFLOW|ONGOING MANAGEMENT)') { return [ConsoleColor]::White }
    if ($Text -match '^\s*[-=]{3,}') { return [ConsoleColor]::White }
    return [ConsoleColor]::Gray
}

function Write-ArchiveHost {
    [CmdletBinding()]
    param(
        [Parameter(Position=0,ValueFromRemainingArguments=$true)] [object[]]$Object,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline,
        [object]$Separator = ' '
    )
    $hasExplicitColor = $PSBoundParameters.ContainsKey('ForegroundColor')
    foreach ($entry in @($Object)) {
        $value = [string]$entry
        $lines = $value -split "`r?`n", -1
        for ($i=0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $color = if ($hasExplicitColor) { $ForegroundColor } else { Get-ArchiveConsoleColor -Text $line }
            $writeArgs = @{ Object=$line; ForegroundColor=$color }
            if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $writeArgs.BackgroundColor=$BackgroundColor }
            if ($PSBoundParameters.ContainsKey('NoNewline') -and $NoNewline -and $i -eq ($lines.Count-1)) { $writeArgs.NoNewline=$true }
            Microsoft.PowerShell.Utility\Write-Host @writeArgs
        }
    }
}

function Initialize-ManagerFolders {
    foreach ($path in @($ProjectRoot,$ArchiveRoot,$ProgrammeSources,$CommercialSources,
        $CheckpointRoot,$PlaylistRoot,$CommercialPlaylistRoot,$MasterLibraryRoot,$ProfileLibraryRoot,$StateRoot,$LogRoot,$BackupRoot,$MasterBackupRoot,$RefreshStaging,$RandomizedRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Write-Log {
    param([string]$Message,[string]$Level='INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    Write-ArchiveHost $line
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
            foreach ($property in @('sources','collections','profiles','channels','masterLibraries')) {
                if ($null -eq $s.PSObject.Properties[$property]) { $s | Add-Member -NotePropertyName $property -NotePropertyValue @() }
            }
            foreach ($source in @($s.sources)) {
                $defaults = @{ expectedCount=0; languageFilterEnabled=$false; endpointMode='Scrape'; refreshable=([bool](-not [string]::IsNullOrWhiteSpace([string]$source.query))); pendingRefreshBase=''; lastRefresh=''; lastRefreshStatus=''; updateEnabled=$true; included=$true; refreshGroupId=''; scheduleFrequency='Weekly'; scheduleEnabled=$true; lastScheduledRefresh=''; nextScheduledRefresh='' }
                foreach ($key in $defaults.Keys) { if ($null -eq $source.PSObject.Properties[$key]) { $source | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] } }
            }
            # One-time migration: each legacy collection becomes a named Master Library.
            if (@($s.masterLibraries).Count -eq 0 -and @($s.collections).Count -gt 0) {
                foreach ($legacy in @($s.collections)) {
                    $path = Join-Path $MasterLibraryRoot ((Get-SafeFileName ([string]$legacy.name)) + '.m3u')
                    if (Test-Path -LiteralPath $path) { $path = Get-UniqueOutputPath -Directory $MasterLibraryRoot -BaseName (Get-SafeFileName ([string]$legacy.name)) -Extension '.m3u' }
                    $s.masterLibraries = @($s.masterLibraries) + @([pscustomobject]@{id=[string]$legacy.id;name=[string]$legacy.name;type=[string]$legacy.type;sourceIds=@($legacy.sourceIds);path=$path;created=(Get-Date).ToString('o');updated='';status='stale';itemCount=0;languageSettings=[pscustomobject]@{mode='All available languages';selected=@()}})
                }
                foreach ($profile in @($s.profiles)) {
                    if ($null -eq $profile.PSObject.Properties['masterLibraryIds']) { $profile | Add-Member -NotePropertyName masterLibraryIds -NotePropertyValue @($profile.collectionIds) }
                }
                Write-ArchiveHost 'Migrated legacy collections into Master Libraries; original collection data remains in the state file for recovery.' -ForegroundColor Yellow
            }
            foreach ($library in @($s.masterLibraries)) {
                if ($null -eq $library.PSObject.Properties['languageSettings']) { $library | Add-Member -NotePropertyName languageSettings -NotePropertyValue ([pscustomobject]@{ mode='All available languages'; selected=@() }) }
            }
            foreach ($profile in @($s.profiles)) {
                if ($null -eq $profile.PSObject.Properties['masterLibraryIds']) { $profile | Add-Member -NotePropertyName masterLibraryIds -NotePropertyValue @() }
                if ($null -eq $profile.PSObject.Properties['lastBuildStatus']) { $profile | Add-Member -NotePropertyName lastBuildStatus -NotePropertyValue 'stale' }
            }
            if ($null -eq $s.PSObject.Properties['languageSettings']) { $s | Add-Member -NotePropertyName languageSettings -NotePropertyValue ([pscustomobject]@{ mode='All available languages'; selected=@() }) }
            if ($null -eq $s.PSObject.Properties['masterPublishSelections']) { $s | Add-Member -NotePropertyName masterPublishSelections -NotePropertyValue @() }
            return $s
        } catch { Write-ArchiveHost "WARNING: Existing manager state could not be read: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    return [pscustomobject]@{ sources=@(); collections=@(); masterLibraries=@(); profiles=@(); channels=@(); languageSettings=[pscustomobject]@{ mode='All available languages'; selected=@() }; masterPublishSelections=@() }
}

function Invoke-GetWithRetry {
    param([string]$Uri,[int]$Retries=5)
    for ($attempt=1; $attempt -le $Retries; $attempt++) {
        try {
            return Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec 120 -Headers @{
                'User-Agent'='ArchiveTV-Source-Library-Manager/5.8'
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
            Write-ArchiveHost "Archive.org movie-category context detected: $contextId"
            Write-ArchiveHost 'The URL tab is collection-oriented, so automatic discovery will compare movie items, collection records, the movies collection filter, and the unfiltered query.'
        } else {
            if ($contextId -notmatch '^[A-Za-z0-9._-]+$') {
                throw "The collection identifier '$contextId' contains unsupported characters; refusing to guess the collection filter."
            }
            $query = 'collection:{0} AND ({1})' -f $contextId,$query
            Write-ArchiveHost "Collection context detected from URL: $contextId"
            Write-ArchiveHost "Translated Archive.org query: $query"
        }
    }
    return $query
}

function Add-Source {
    param([string]$Name,[string]$Type,[string]$Path,[string]$Query,[int]$Count,
        [long]$ExpectedCount=0,[bool]$LanguageFilterEnabled=$false,[string]$EndpointMode='Scrape',[bool]$Refreshable=$true,[string]$RefreshGroupId='')
    $script:State.sources = @($script:State.sources) + @([pscustomobject]@{
        id=[guid]::NewGuid().ToString()
        name=$Name; type=$Type; path=$Path; query=$Query; itemCount=$Count
        expectedCount=$ExpectedCount; languageFilterEnabled=$LanguageFilterEnabled
        endpointMode=$EndpointMode; refreshable=$Refreshable
        pendingRefreshBase=''; lastRefresh=''; lastRefreshStatus=''; updateEnabled=$true; included=$true
        refreshGroupId=$RefreshGroupId; scheduleFrequency='Weekly'; scheduleEnabled=$true; lastScheduledRefresh=''; nextScheduledRefresh=''
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
    $description = [string](Get-OptionalPropertyValue -Object $metadataObject -Name 'description' -Default '')
    $subjects = @(Get-OptionalPropertyValue -Object $metadataObject -Name 'subject' -Default @()) -join ' '
    $collection = @(Get-OptionalPropertyValue -Object $metadataObject -Name 'collection' -Default @()) -join ' '
    $creator = [string](Get-OptionalPropertyValue -Object $metadataObject -Name 'creator' -Default '')
    $fileName = [string](Get-OptionalPropertyValue -Object $mediaFile -Name 'name' -Default '')
    $evidence = (($title + ' ' + $description + ' ' + $subjects + ' ' + $collection + ' ' + $creator + ' ' + $fileName) -replace '\s+',' ').Trim()
    $strongAd = '(?i)(\b(tv|television|radio)\s*(commercial|advert)|\bcommercial\s*(spot|break|reel)|\badvert(ising|isement)\s*(film|spot|clip)|\b(advert|commercial)\s*reel\b|\bpublic service announcement\b|\bPSA\b|\bpromo(tional)?\s*(spot|trailer|clip)\b|\badvertising\s*agency\b)'
    $weakAd = '(?i)(\bcommercial\b|\badvertis(ing|ement)\b|\bTV spot\b|\bad break\b|\bpromo\b|\bsponsored\b)'
    $classification='Programme'; $classificationReason='No strong commercial indicators found.'
    if ($evidence -match $strongAd) { $classification='Commercial'; $classificationReason='Strong commercial/advertising indicator in metadata or filename.' }
    elseif ($evidence -match $weakAd) { $classification='Review'; $classificationReason='Possible commercial indicator; retained for manual review.' }
    return [pscustomobject]@{
        identifier=$identifier; title=$title; year=$year; url=$url; group='Archive.org'; language=$language
        classification=$classification; classificationReason=$classificationReason
        description=$description; subjects=$subjects; collection=$collection; creator=$creator; sourceFileName=$fileName
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
                'User-Agent'='ArchiveTV-Source-Library-Manager/5.8'
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
    Write-ArchiveHost ''
    Write-ArchiveHost 'QUERY INTERPRETATION CHECK - count-only checks; no metadata or playlists are being downloaded.'
    $candidateNumber = 0
    foreach ($candidate in @($Candidates | Select-Object -Unique)) {
        $candidateNumber++
        $candidateCount = $null
        try {
            $candidateCount = Get-AdvancedSearchCount -Query $candidate
            Write-ArchiveHost ("  {0}. {1}  =>  {2} results" -f $candidateNumber,$candidate,$candidateCount)
        } catch {
            Write-ArchiveHost ("  {0}. {1}  =>  count unavailable ({2})" -f $candidateNumber,$candidate,$_.Exception.Message) -ForegroundColor Yellow
        }
        $candidateResults.Add([pscustomobject]@{ number=$candidateNumber; query=[string]$candidate; count=$candidateCount })
    }

    if ($ExpectedCount -gt 0) {
        $matches = @($candidateResults | Where-Object { $_.count -eq $ExpectedCount })
        if ($matches.Count -eq 1) {
            Write-ArchiveHost ''
            Write-ArchiveHost "Selected the only query matching the optional verification count: $($matches[0].query)" -ForegroundColor Green
            return [string]$matches[0].query
        }
        if ($matches.Count -gt 1) {
            Write-ArchiveHost "More than one interpretation matches $ExpectedCount; choose the intended one below." -ForegroundColor Yellow
        } else {
            Write-ArchiveHost "No candidate exactly matches the optional count $ExpectedCount. Choose the interpretation that matches the Archive.org results page, or cancel and rerun with expected count 0 if you do not want count verification." -ForegroundColor Yellow
        }
    } else {
        Write-ArchiveHost 'No expected count is being enforced. Choose the interpretation that matches the Archive.org results page.'
    }

    while ($true) {
        $selection = Read-Host 'Select query interpretation number (Q=cancel)'
        if ($selection.Trim() -ieq 'q') { throw 'Query selection cancelled. No metadata was downloaded and no source playlist was saved.' }
        $number = 0
        if ([int]::TryParse($selection,[ref]$number)) {
            $selected = @($candidateResults | Where-Object { $_.number -eq $number })
            if ($selected.Count -eq 1) {
                Write-ArchiveHost ''
                Write-ArchiveHost "SELECTED QUERY: $($selected[0].query)" -ForegroundColor Green
                return [string]$selected[0].query
            }
        }
        Write-ArchiveHost ("Enter a number from 1 to {0}, or Q to cancel." -f $candidateResults.Count) -ForegroundColor Yellow
    }
}

function Import-ScrapeApi {
    param([string]$Query,[string]$OutputDirectory,[string]$BaseName,[long]$ExpectedCount=0,[switch]$SplitCommercials)

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
            return [pscustomobject]@{path=[string]$meta.outputPath;count=[int]$meta.playableCount;programmePath=[string](Get-OptionalPropertyValue -Object $meta -Name 'programmeOutputPath' -Default '');programmeCount=[int](Get-OptionalPropertyValue -Object $meta -Name 'programmeCount' -Default 0);commercialPath=[string](Get-OptionalPropertyValue -Object $meta -Name 'commercialOutputPath' -Default '');commercialCount=[int](Get-OptionalPropertyValue -Object $meta -Name 'commercialCount' -Default 0);reviewPath=[string](Get-OptionalPropertyValue -Object $meta -Name 'reviewPath' -Default '');reviewCount=[int](Get-OptionalPropertyValue -Object $meta -Name 'reviewCount' -Default 0)}
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

    $output = ''
    $programmeOutput = ''
    $commercialOutput = ''
    $reviewPath = ''
    $programmeRecords = @($records.ToArray() | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name 'classification' -Default 'Programme') -eq 'Programme' })
    $commercialRecords = @($records.ToArray() | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name 'classification' -Default 'Programme') -eq 'Commercial' })
    $reviewRecords = @($records.ToArray() | Where-Object { (Get-OptionalPropertyValue -Object $_ -Name 'classification' -Default 'Programme') -eq 'Review' })
    if ($SplitCommercials) {
        if ($programmeRecords.Count -gt 0) { $programmeDirectory = if ($OutputDirectory -eq $RefreshStaging) { $RefreshStaging } else { $ProgrammeSources }; $programmeOutput = Get-UniqueOutputPath -Directory $programmeDirectory -BaseName ('Programme_'+$BaseName) -Extension '.m3u'; Write-M3UFile -Path $programmeOutput -Records $programmeRecords -Description ($Query+' [Programme classification]') }
        if ($commercialRecords.Count -gt 0) { $commercialDirectory = if ($OutputDirectory -eq $RefreshStaging) { $RefreshStaging } else { $CommercialSources }; $commercialOutput = Get-UniqueOutputPath -Directory $commercialDirectory -BaseName ('Commercial_'+$BaseName) -Extension '.m3u'; Write-M3UFile -Path $commercialOutput -Records $commercialRecords -Description ($Query+' [Commercial classification]') }
        if ($reviewRecords.Count -gt 0) { $reviewPath = Join-Path $CheckpointRoot ($BaseName+'.review.jsonl'); foreach ($reviewRecord in $reviewRecords) { Add-CheckpointLine -Path $reviewPath -Value ($reviewRecord | ConvertTo-Json -Compress -Depth 10) } }
        if (-not $programmeOutput -and -not $commercialOutput) { throw 'No classified programme or commercial video records were eligible; review records and checkpoint were preserved.' }
        $output = if ($programmeOutput) { $programmeOutput } else { $commercialOutput }
    } else {
        $output = Get-UniqueOutputPath -Directory $OutputDirectory -BaseName $BaseName -Extension '.m3u'
        Write-M3UFile -Path $output -Records $records.ToArray() -Description $Query
    }
    $meta.status = 'complete'
    $meta.outputPath = $output
    $meta.programmeOutputPath = $programmeOutput
    $meta.commercialOutputPath = $commercialOutput
    $meta.reviewPath = $reviewPath
    $meta.programmeCount = $programmeRecords.Count
    $meta.commercialCount = $commercialRecords.Count
    $meta.reviewCount = $reviewRecords.Count
    $meta.examinedCount = $seen.Count
    $meta.playableCount = $records.Count
    $meta.reportedTotal = $reportedTotal
    if ($null -eq $meta.PSObject.Properties['preflightTotal']) {
        $meta | Add-Member -NotePropertyName preflightTotal -NotePropertyValue $preflightTotal
    } else {
        $meta.preflightTotal = $preflightTotal
    }
    # Older checkpoints may not contain a 'completed' property. Add it
    # explicitly before assignment so resumed imports complete on Windows
    # PowerShell 5.1 as well as newly created checkpoints.
    $completedStamp = (Get-Date).ToString('o')
    if ($null -eq $meta.PSObject.Properties['completed']) {
        $meta | Add-Member -NotePropertyName completed -NotePropertyValue $completedStamp
    } else {
        $meta.completed = $completedStamp
    }
    $updatedStamp = (Get-Date).ToString('o')
    if ($null -eq $meta.PSObject.Properties['updated']) {
        $meta | Add-Member -NotePropertyName updated -NotePropertyValue $updatedStamp
    } else {
        $meta.updated = $updatedStamp
    }
    Write-CheckpointJson -Path $checkpoint -Value $meta
    if (Test-Path -LiteralPath $partialM3U) { Remove-Item -LiteralPath $partialM3U -Force }
    if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($partialM3U,'.manifest.json'))) { Remove-Item -LiteralPath ([IO.Path]::ChangeExtension($partialM3U,'.manifest.json')) -Force }
    Write-Log "FULL SOURCE M3U AUTOSAVED: $output"
    Write-Log "Scrape complete. Examined=$($seen.Count); playable=$($records.Count); API total=$reportedTotal; Advanced Search count=$preflightTotal."
    return [pscustomobject]@{path=$output;count=$records.Count;programmePath=$programmeOutput;programmeCount=$programmeRecords.Count;commercialPath=$commercialOutput;commercialCount=$commercialRecords.Count;reviewPath=$reviewPath;reviewCount=$reviewRecords.Count}
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
    Write-ArchiveHost ''
    Write-ArchiveHost '--- Archive.org Source Import ---'
    Write-ArchiveHost 'Paste an Archive.org search-results URL or enter search terms.'
    Write-ArchiveHost 'The recommended cursor-paginated Scraping API is selected automatically.'
    $queryInput = Read-Host 'Archive.org search URL or query'
    if ([string]::IsNullOrWhiteSpace($queryInput)) { return }
    $script:ArchiveAutoCandidates = @(); $script:ArchiveAutoDiscovery = $false
    if ($queryInput -match '^https://(www\.)?archive\.org/') {
        $query = ConvertFrom-ArchiveSearchUrl -SearchUrl $queryInput
        Write-ArchiveHost "Extracted query: $query"
    } else { $query = $queryInput.Trim() }
    if ($script:ArchiveAutoDiscovery) { $query = Resolve-AutoScrapeQuery -Candidates $script:ArchiveAutoCandidates -ExpectedCount 0 }
    $normalizedQuery = Get-NormalizedArchiveQuery -Query $query
    $existing = @($State.sources | Where-Object { (Get-NormalizedArchiveQuery -Query ([string]$_.query)) -eq $normalizedQuery })
    if ($existing.Count -gt 0) { Write-Log 'A paired Programme/Commercial source group already exists for this query. Use Refresh Selected Sources or resume its existing import; no duplicate import started.' 'WARN'; return }
    $groupId = [guid]::NewGuid().ToString()
    $baseName = Get-SafeFileName $query
    $lock = Enter-ManagerOperationLock
    try { $result = Import-ScrapeApi -Query $query -OutputDirectory $ProgrammeSources -BaseName $baseName -ExpectedCount 0 -SplitCommercials }
    finally { Exit-ManagerOperationLock -LockStream $lock }
    if ($result.programmePath) { Add-Source -Name ([IO.Path]::GetFileNameWithoutExtension($result.programmePath)) -Type 'Programme' -Path $result.programmePath -Query $query -Count $result.programmeCount -EndpointMode 'SearchUrlOrQuery' -RefreshGroupId $groupId }
    if ($result.commercialPath) { Add-Source -Name ([IO.Path]::GetFileNameWithoutExtension($result.commercialPath)) -Type 'Commercial' -Path $result.commercialPath -Query $query -Count $result.commercialCount -EndpointMode 'SearchUrlOrQuery' -RefreshGroupId $groupId }
    Write-Log ("Source import complete. Programme={0}; Commercial={1}; Review={2}; shared refresh group={3}." -f $result.programmeCount,$result.commercialCount,$result.reviewCount,$groupId)
    if ($result.reviewPath) { Write-ArchiveHost "Uncertain classifications saved for review: $($result.reviewPath)" -ForegroundColor Yellow }
}

function Select-SourceMembership {
    param([string]$Type,[string[]]$CurrentIds=@())
    $sources=@($State.sources | Where-Object { $_.type -eq $Type -and $_.included -ne $false })
    if ($sources.Count -eq 0) { Write-Log "No $Type sources registered." 'WARN'; return @() }
    for ($i=0; $i -lt $sources.Count; $i++) { $mark=if ($sources[$i].id -in $CurrentIds) {'[X]'} else {'[ ]'}; Write-ArchiveHost ("{0}. {1} {2}" -f ($i+1),$mark,$sources[$i].name) }
    Write-ArchiveHost 'Enter source numbers separated by commas; A=all; N=none.'
    $selection=Read-Host 'Source selection'
    if ([string]::IsNullOrWhiteSpace($selection)) { return @($CurrentIds) }
    if ($selection.Trim() -ieq 'A') { return @($sources | ForEach-Object {$_.id}) }
    if ($selection.Trim() -ieq 'N') { return @() }
    $ids=@(); foreach ($part in ($selection -split ',')) { $n=0; if ([int]::TryParse($part.Trim(),[ref]$n) -and $n -ge 1 -and $n -le $sources.Count) { $ids += $sources[$n-1].id } }
    return @($ids | Select-Object -Unique)
}

function Create-MasterLibrary {
    $name=Read-Host 'Master Library name'
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $typeChoice=Read-Default '1=Programme, 2=Commercial' '1'
    $type=if ($typeChoice -eq '2') {'Commercial'} else {'Programme'}
    $ids=@(Select-SourceMembership -Type $type)
    if ($ids.Count -eq 0) { Write-Log 'No sources selected; Master Library was not created.' 'WARN'; return }
    $directory=if ($type -eq 'Commercial') {$CommercialPlaylistRoot} else {$PlaylistRoot}
    $path=Join-Path $MasterLibraryRoot ((Get-SafeFileName $name)+'.m3u')
    if (Test-Path -LiteralPath $path) { $path=Get-UniqueOutputPath -Directory $MasterLibraryRoot -BaseName (Get-SafeFileName $name) -Extension '.m3u' }
    $item=[pscustomobject]@{id=[guid]::NewGuid().ToString();name=$name.Trim();type=$type;sourceIds=@($ids);path=$path;created=(Get-Date).ToString('o');updated='';status='stale';itemCount=0;languageSettings=[pscustomobject]@{mode='All available languages';selected=@()}}
    $State.masterLibraries=@($State.masterLibraries)+@($item); Save-State
    Build-MasterLibrary -Library $item
}

function Create-Profile {
    $name=Read-Host 'Profile name'
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $typeChoice=Read-Default '1=Programme, 2=Commercial' '1'
    $type=if ($typeChoice -eq '2') {'Commercial'} else {'Programme'}
    $libraries=@($State.masterLibraries | Where-Object {$_.type -eq $type})
    if ($libraries.Count -eq 0) { Write-Log "No $type Master Libraries available." 'WARN'; return }
    for ($i=0; $i -lt $libraries.Count; $i++) { Write-ArchiveHost ("{0}. {1}" -f ($i+1),$libraries[$i].name) }
    $selection=Read-Host 'Master Library numbers separated by commas (select one or more)'
    $ids=@(); foreach ($part in ($selection -split ',')) { $n=0; if ([int]::TryParse($part.Trim(),[ref]$n) -and $n -ge 1 -and $n -le $libraries.Count) { $ids += $libraries[$n-1].id } }
    if ($ids.Count -eq 0) { Write-Log 'No Master Libraries selected; profile was not created.' 'WARN'; return }
    $State.profiles=@($State.profiles)+@([pscustomobject]@{id=[guid]::NewGuid().ToString();name=$name.Trim();type=$type;masterLibraryIds=@($ids | Select-Object -Unique);created=(Get-Date).ToString('o');lastBuildStatus='stale';lastBuild='';path=''})
    Save-State; Write-Log "Created $type profile '$name'."; Build-Profile -Profile ($State.profiles[-1])
}

function Define-Channel {
    $name = Read-Host 'Programme channel name'
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $profiles = @($State.profiles | Where-Object { $_.type -eq 'Programme' })
    if ($profiles.Count -eq 0) { Write-Log 'Create a Programme Profile first.' 'WARN'; return }
    for ($i=0; $i -lt $profiles.Count; $i++) { Write-ArchiveHost ("{0}. {1}" -f ($i+1),$profiles[$i].name) }
    $selection = Read-Default 'Programme profile number' '1'
    $n=0
    if (-not [int]::TryParse($selection,[ref]$n) -or $n -lt 1 -or $n -gt $profiles.Count) { return }

    Write-ArchiveHost 'Channel content split:'
    Write-ArchiveHost '1. All content from selected Programme profile'
    Write-ArchiveHost '2. Genre/group-title match'
    Write-ArchiveHost '3. Custom label/group-title match'
    Write-ArchiveHost '4. Single decade (e.g. 1980s)'
    Write-ArchiveHost '5. Custom decade group (e.g. 1980s,1990s)'
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
        Write-ArchiveHost 'Optional commercial profiles to merge (commercials are not restricted by the Programme channel split):'
        for ($i=0; $i -lt $commercialProfiles.Count; $i++) { Write-ArchiveHost ("{0}. {1}" -f ($i+1),$commercialProfiles[$i].name) }
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
    param([string[]]$MasterLibraryIds)
    $paths=@()
    foreach ($libraryId in $MasterLibraryIds) {
        $library=@($State.masterLibraries | Where-Object {$_.id -eq $libraryId}) | Select-Object -First 1
        if ($null -ne $library -and (Test-Path -LiteralPath ([string]$library.path) -PathType Leaf)) { $paths += [string]$library.path }
    }
    return @($paths | Select-Object -Unique)
}

function Write-AtomicPlaylist {
    param([string]$Path,[object[]]$Records,[string]$Description,[string]$BackupDirectory)
    $directory=Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temp=$Path+'.build.tmp'
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    Write-M3UFile -Path $temp -Records $Records -Description $Description
    $header=Get-Content -LiteralPath $temp -TotalCount 1 -Encoding UTF8
    if ($header -ne '#EXTM3U') { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; throw "Temporary playlist validation failed for '$Path'." }
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $BackupDirectory)) { New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null }
        $backup=Join-Path $BackupDirectory ((Split-Path -Leaf $Path)+'.'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.bak')
        Copy-Item -LiteralPath $Path -Destination $backup -ErrorAction Stop
        $oldManifest=[IO.Path]::ChangeExtension($Path,'.manifest.json')
        if (Test-Path -LiteralPath $oldManifest) { Copy-Item -LiteralPath $oldManifest -Destination ($backup+'.manifest.json') -Force }
    }
    Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop
    $tempManifest=[IO.Path]::ChangeExtension($temp,'.manifest.json')
    $finalManifest=[IO.Path]::ChangeExtension($Path,'.manifest.json')
    if (Test-Path -LiteralPath $tempManifest) { Move-Item -LiteralPath $tempManifest -Destination $finalManifest -Force }
}

function Build-MasterLibrary {
    param($Library)
    $sourcePaths=@()
    foreach ($sourceId in @($Library.sourceIds)) {
        $source=@($State.sources | Where-Object {$_.id -eq $sourceId}) | Select-Object -First 1
        if ($null -eq $source -or -not (Test-Path -LiteralPath ([string]$source.path) -PathType Leaf)) { throw "Master Library '$($Library.name)' has a missing selected source ($sourceId); last good output retained." }
        $sourcePaths += [string]$source.path
    }
    if ($sourcePaths.Count -eq 0) { throw "Master Library '$($Library.name)' has no selected source M3Us." }
    $entries=@(Read-M3UEntries -Paths $sourcePaths -LanguageSettings $Library.languageSettings)
    $seen=@{}; $unique=New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) { if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) } }
    Write-AtomicPlaylist -Path ([string]$Library.path) -Records $unique.ToArray() -Description ("{0} Master Library; selected source IDs: {1}" -f $Library.type,(@($Library.sourceIds) -join ',')) -BackupDirectory $MasterBackupRoot
    $Library.itemCount=$unique.Count; $Library.updated=(Get-Date).ToString('o'); $Library.status='complete'; Save-State
    Write-Log "Built Master Library '$($Library.name)' from $(@($Library.sourceIds).Count) selected source M3Us; entries=$($unique.Count)."
}

function Build-Profile {
    param($Profile)
    $paths=@(Get-ProfileSourcePaths -MasterLibraryIds @($Profile.masterLibraryIds))
    if ($paths.Count -eq 0) { throw "Profile '$($Profile.name)' has no accessible selected Master Libraries; previous output retained." }
    $entries=@(Read-M3UEntries -Paths $paths)
    $seen=@{}; $unique=New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) { if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) } }
    $directory=if ($Profile.type -eq 'Commercial') {$CommercialPlaylistRoot} else {$PlaylistRoot}
    $path=[string](Get-OptionalPropertyValue -Object $Profile -Name 'path' -Default '')
    if ([string]::IsNullOrWhiteSpace($path)) { $path=Join-Path $ProfileLibraryRoot ((Get-SafeFileName $Profile.name)+'.m3u'); if (Test-Path -LiteralPath $path) { $path=Get-UniqueOutputPath -Directory $ProfileLibraryRoot -BaseName (Get-SafeFileName $Profile.name) -Extension '.m3u' }; $Profile.path=$path }
    Write-AtomicPlaylist -Path $path -Records $unique.ToArray() -Description ("{0} Profile: {1}; Master Library IDs: {2}" -f $Profile.type,$Profile.name,(@($Profile.masterLibraryIds) -join ',')) -BackupDirectory $MasterBackupRoot
    $Profile.lastBuild=(Get-Date).ToString('o'); $Profile.lastBuildStatus='complete'; Save-State
    Write-Log "Built profile '$($Profile.name)' from $(@($Profile.masterLibraryIds).Count) Master Libraries; entries=$($unique.Count)."
}

function Invoke-UpdateHierarchy {
    param([string[]]$SourceIds=@(),[string[]]$MasterLibraryIds=@(),[switch]$All)
    $failed=@(); $updatedMasters=@(); $updatedProfiles=@()
    $targetMasters=@($State.masterLibraries | Where-Object {$All -or ($MasterLibraryIds.Count -gt 0 -and $_.id -in $MasterLibraryIds) -or ($MasterLibraryIds.Count -eq 0 -and (@($_.sourceIds) | Where-Object {$_ -in $SourceIds}).Count -gt 0)})
    foreach ($library in $targetMasters) {
        try { Build-MasterLibrary -Library $library; $updatedMasters += $library.id }
        catch { $library.status='failed: '+$_.Exception.Message; Save-State; $failed += "Master Library '$($library.name)': $($_.Exception.Message)"; Write-Log $failed[-1] 'ERROR' }
    }
    foreach ($profile in @($State.profiles)) {
        if (-not $All -and -not (@($profile.masterLibraryIds | Where-Object {$_ -in $updatedMasters}).Count)) { continue }
        $deps=@($State.masterLibraries | Where-Object {$_.id -in @($profile.masterLibraryIds)})
        if ($deps.Count -eq 0 -or @($deps | Where-Object {$_.status -ne 'complete'}).Count -gt 0) { $profile.lastBuildStatus='blocked: dependency failed'; Save-State; $failed += "Profile '$($profile.name)' blocked by an incomplete Master Library."; continue }
        try { Build-Profile -Profile $profile; $updatedProfiles += $profile.id }
        catch { $profile.lastBuildStatus='failed: '+$_.Exception.Message; Save-State; $failed += "Profile '$($profile.name)': $($_.Exception.Message)"; Write-Log $failed[-1] 'ERROR' }
    }
    if ($updatedProfiles.Count -gt 0) {
        $channels=@()
        foreach ($channel in @($State.channels)) {
            $profileIds=@([string]$channel.programmeProfileId)+@($channel.commercialProfileIds)
            $dependencies=@($State.profiles | Where-Object {$_.id -in $profileIds})
            $hasUpdatedDependency=@($profileIds | Where-Object {$_ -in $updatedProfiles}).Count -gt 0
            $allDependenciesReady=($dependencies.Count -eq $profileIds.Count -and @($dependencies | Where-Object {$_.lastBuildStatus -ne 'complete' -or [string]::IsNullOrWhiteSpace([string]$_.path) -or -not (Test-Path -LiteralPath ([string]$_.path) -PathType Leaf)}).Count -eq 0)
            if ($hasUpdatedDependency -and $allDependenciesReady) { $channels += $channel }
            elseif ($hasUpdatedDependency) { Write-Log "Channel '$($channel.name)' was not republished because one or more dependent profiles are not complete." 'WARN' }
        }
        if ($channels.Count -gt 0) { try { Publish-Channels -Quiet -ChannelIds @($channels | ForEach-Object {[string]$_.id}) } catch { $failed += "Channel playlist cascade: $($_.Exception.Message)"; Write-Log $failed[-1] 'ERROR' } }
    }
    $status=[pscustomobject]@{updated=(Get-Date).ToString('o');sourceIds=@($SourceIds);masterLibrariesUpdated=@($updatedMasters);profilesUpdated=@($updatedProfiles);failures=@($failed);result=if($failed.Count){'partial'}else{'complete'}}
    Write-CheckpointJson -Path $HierarchyStatusPath -Value $status
    Write-Log "Hierarchy update finished: Master Libraries=$($updatedMasters.Count); Profiles=$($updatedProfiles.Count); failures=$($failed.Count)."
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
    param([string]$Language,$Settings)
    $settings = $Settings
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
    Write-ArchiveHost 'Language filtering modes:'
    for ($i=0; $i -lt $modes.Count; $i++) { Write-ArchiveHost ("{0}. {1}" -f ($i+1),$modes[$i]) }
    $choice = Read-Default 'Select mode' '4'
    $n=0
    if (-not [int]::TryParse($choice,[ref]$n) -or $n -lt 1 -or $n -gt $modes.Count) { return }
    $selected = @()
    if ($modes[$n-1] -in @('English plus selected languages','Selected languages only','Exclude selected languages')) {
        $categories = @('English','French','Spanish','German','Japanese','Korean','Chinese','Portuguese','Russian','Dutch','Other/Unknown')
        Write-ArchiveHost 'Select language categories (comma-separated numbers):'
        for ($i=0; $i -lt $categories.Count; $i++) { Write-ArchiveHost ("{0}. {1}" -f ($i+1),$categories[$i]) }
        $raw = Read-Host 'Categories (Enter for none)'
        foreach ($part in ($raw -split ',')) { $x=0; if ([int]::TryParse($part.Trim(),[ref]$x) -and $x -ge 1 -and $x -le $categories.Count) { $selected += $categories[$x-1] } }
    }
    $State.languageSettings = [pscustomobject]@{ mode=$modes[$n-1]; selected=@($selected | Select-Object -Unique) }
    Save-State
    Write-Log ("Language filter saved: {0}; selected: {1}. Source M3Us remain unchanged. Rebuilding downstream Master Libraries, profiles and channels." -f $State.languageSettings.mode,(@($State.languageSettings.selected) -join ', '))
    Invoke-UpdateHierarchy -All
}

function Show-LanguageSettings {
    if (@($State.masterLibraries).Count -eq 0) { Write-ArchiveHost 'No Master Libraries configured.'; return }
    foreach($library in $State.masterLibraries){
        $settings=$library.languageSettings
        if($null -eq $settings){$settings=[pscustomobject]@{mode='All available languages';selected=@()}}
        Write-ArchiveHost ("{0} | mode={1} | selected={2}" -f $library.name,$settings.mode,(@($settings.selected)-join ', '))
    }
    Write-ArchiveHost 'Language filters are applied while building each Master Library. Complete source M3Us are never filtered.'
}

function Read-M3UEntries {
    param([string[]]$Paths,$LanguageSettings)
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
                if (($null -eq $LanguageSettings) -or (Test-LanguageAllowed -Language $language -Settings $LanguageSettings)) {
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
    Build-Profile -Profile $Profile
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
    param([switch]$Quiet,[string[]]$ChannelIds=@())
    $limitText=if ($Quiet) { '0' } else { Read-Default 'Maximum entries per operational channel (0=no sampling)' '500' }
    $limit=0
    if (-not [int]::TryParse($limitText,[ref]$limit) -or $limit -lt 0) { $limit=500 }
    foreach ($channel in $State.channels) {
        if ($ChannelIds.Count -gt 0 -and $channel.id -notin $ChannelIds) { continue }
        $programme=@($State.profiles | Where-Object { $_.id -eq $channel.programmeProfileId }) | Select-Object -First 1
        if ($null -eq $programme) { continue }
        $entries=New-Object System.Collections.Generic.List[object]
        $programmePath=[string](Get-OptionalPropertyValue -Object $programme -Name 'path' -Default '')
        if ([string]::IsNullOrWhiteSpace($programmePath) -or -not (Test-Path -LiteralPath $programmePath -PathType Leaf)) { throw "Programme profile '$($programme.name)' has not been built; refusing to publish a stale channel." }
        foreach ($entry in (Read-M3UEntries -Paths @($programmePath))) { if (Test-ChannelProgrammeEntry -Entry $entry -Channel $channel) { $entries.Add($entry) } }
        foreach ($profileId in $channel.commercialProfileIds) {
            $commercial=@($State.profiles | Where-Object { $_.id -eq $profileId }) | Select-Object -First 1
            if ($null -ne $commercial) {
                $commercialPath=[string](Get-OptionalPropertyValue -Object $commercial -Name 'path' -Default '')
                if ([string]::IsNullOrWhiteSpace($commercialPath) -or -not (Test-Path -LiteralPath $commercialPath -PathType Leaf)) { throw "Commercial profile '$($commercial.name)' has not been built; refusing to publish a stale channel." }
                foreach ($entry in (Read-M3UEntries -Paths @($commercialPath))) { $entries.Add($entry) }
            }
        }
        $seen=@{}; $unique=New-Object System.Collections.Generic.List[object]
        foreach ($entry in $entries) { if (-not $seen.ContainsKey($entry.url)) { $seen[$entry.url]=$true; $unique.Add($entry) } }
        $result=$unique.ToArray()
        if ($limit -gt 0 -and $result.Count -gt $limit) { $result=@($result | Get-Random -Count $limit) }
        $output=[string](Get-OptionalPropertyValue -Object $channel -Name 'path' -Default '')
        if ([string]::IsNullOrWhiteSpace($output)) { $output=Get-UniqueOutputPath -Directory $PlaylistRoot -BaseName (Get-SafeFileName $channel.name) -Extension '.m3u'; $channel.path=$output; Save-State }
        $channelMode=[string](Get-OptionalPropertyValue -Object $channel -Name 'splitMode' -Default 'All')
        $channelFilter=[string](Get-OptionalPropertyValue -Object $channel -Name 'filterValue' -Default '')
        Write-AtomicPlaylist -Path $output -Records $result -Description ("Channel: {0}; split={1}; filter={2}" -f $channel.name,$channelMode,$channelFilter) -BackupDirectory $MasterBackupRoot
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
    Write-ArchiveHost 'Select the profiles to combine into one Master Library.'
    for ($i=0; $i -lt $profiles.Count; $i++) { Write-ArchiveHost ("{0}. [{1}] {2}" -f ($i+1),$profiles[$i].type,$profiles[$i].name) }
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
        $paths=Get-ProfileSourcePaths -MasterLibraryIds @($profile.masterLibraryIds)
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
    for ($i=0; $i -lt $files.Count; $i++) { Write-ArchiveHost ("{0}. {1}" -f ($i+1),$files[$i].FullName) }
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
    Write-ArchiveHost 'Saved import checkpoints:'
    for ($i=0; $i -lt $available.Count; $i++) {
        $m=$available[$i].meta
        Write-ArchiveHost ("{0}. [{1}] {2} | examined={3} playable={4}" -f ($i+1),$m.status,$m.query,$m.examinedCount,$m.playableCount)
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

function Set-MasterLibraryLanguageFiltering {
    param($Library)
    if (@($State.masterLibraries).Count -eq 0) { Write-Log 'Create a Master Library before configuring its language filtering.' 'WARN'; return }
    for ($i=0; $i -lt $State.masterLibraries.Count; $i++) {
        $m=$State.masterLibraries[$i]
        $settings=$m.languageSettings
        if ($null -eq $settings) { $settings=[pscustomobject]@{mode='All available languages';selected=@()} }
        Write-ArchiveHost ("{0}. {1} | language mode={2} | selected={3}" -f ($i+1),$m.name,$settings.mode,(@($settings.selected) -join ', '))
    }
    if ($null -eq $Library) {
        $raw=Read-Host 'Select Master Library number to configure languages (Enter=cancel)'; $n=0
        if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $State.masterLibraries.Count) { return }
        $Library=$State.masterLibraries[$n-1]
    }
    $library=$Library
    $modes=@('English only','English plus selected languages','Selected languages only','All available languages','Exclude selected languages')
    Write-ArchiveHost 'Language filtering modes:'
    for($i=0;$i -lt $modes.Count;$i++){Write-ArchiveHost ("{0}. {1}" -f ($i+1),$modes[$i])}
    $currentMode=[string](Get-OptionalPropertyValue -Object $library.languageSettings -Name 'mode' -Default 'All available languages')
    $defaultIndex=[array]::IndexOf($modes,$currentMode)+1
    if($defaultIndex -lt 1){$defaultIndex=4}
    $choice=Read-Default 'Select language mode' ([string]$defaultIndex); $choiceNumber=0
    if(-not [int]::TryParse($choice,[ref]$choiceNumber) -or $choiceNumber -lt 1 -or $choiceNumber -gt $modes.Count){return}
    $selected=@()
    if($modes[$choiceNumber-1] -in @('English plus selected languages','Selected languages only','Exclude selected languages')){
        $categories=@('English','French','Spanish','German','Japanese','Korean','Chinese','Portuguese','Russian','Dutch','Other/Unknown')
        $currentSelected=@(Get-OptionalPropertyValue -Object $library.languageSettings -Name 'selected' -Default @())
        Write-ArchiveHost 'Language categories:'
        for($i=0;$i -lt $categories.Count;$i++){$mark=if($categories[$i] -in $currentSelected){'[X]'}else{'[ ]'};Write-ArchiveHost ("{0}. {1} {2}" -f ($i+1),$mark,$categories[$i])}
        $rawSelection=Read-Host 'Enter category numbers separated by commas (Enter=none)'
        foreach($part in ($rawSelection -split ',')){$x=0;if([int]::TryParse($part.Trim(),[ref]$x) -and $x -ge 1 -and $x -le $categories.Count){$selected+=$categories[$x-1]}}
    }
    $library.languageSettings=[pscustomobject]@{mode=$modes[$choiceNumber-1];selected=@($selected|Select-Object -Unique)}
    $library.status='stale'; Save-State
    Write-Log ("Saved language filter for Master Library '{0}': {1}; selected={2}. Source M3Us remain complete." -f $library.name,$library.languageSettings.mode,(@($library.languageSettings.selected)-join ', '))
    Invoke-UpdateHierarchy -MasterLibraryIds @($library.id)
}

function Manage-MasterLibraries {
    if (@($State.masterLibraries).Count -eq 0) { Write-Log 'No Master Libraries registered.' 'WARN'; return }
    for ($i=0; $i -lt $State.masterLibraries.Count; $i++) { $m=$State.masterLibraries[$i]; Write-ArchiveHost ("{0}. [{1}] {2} | sources={3} | status={4}" -f ($i+1),$m.type,$m.name,@($m.sourceIds).Count,$m.status) }
    $raw=Read-Host 'Select Master Library number to edit/rename/delete (Enter=cancel)'; $n=0
    if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $State.masterLibraries.Count) { return }
    $item=$State.masterLibraries[$n-1]; $action=Read-Default 'E=edit source membership, L=language filtering, R=rename, D=delete, B=rebuild' 'E'
    if ($action -match '^(?i:r)$') { $new=Read-Host 'New Master Library name'; if (-not [string]::IsNullOrWhiteSpace($new)) { $item.name=$new.Trim(); Save-State; Write-Log 'Master Library renamed; output path remains stable.' } }
    elseif ($action -match '^(?i:e)$') { $ids=@(Select-SourceMembership -Type $item.type -CurrentIds @($item.sourceIds)); if ($ids.Count -eq 0) { Write-Log 'No sources selected; membership was not changed.' 'WARN'; return }; $item.sourceIds=$ids; $item.status='stale'; Save-State; Invoke-UpdateHierarchy -SourceIds @($item.sourceIds) }
    elseif ($action -match '^(?i:l)$') { Set-MasterLibraryLanguageFiltering -Library $item }
    elseif ($action -match '^(?i:b)$') { Invoke-UpdateHierarchy -SourceIds @($item.sourceIds) }
    elseif ($action -match '^(?i:d)$') { $confirm=Read-Host "Type DELETE to remove Master Library '$($item.name)'"; if ($confirm -ceq 'DELETE') { $dependent=@($State.profiles | Where-Object {$item.id -in @($_.masterLibraryIds)}); if ($dependent.Count) { Write-Log 'Cannot delete: profiles still depend on this Master Library.' 'WARN'; return }; $State.masterLibraries=@($State.masterLibraries | Where-Object {$_.id -ne $item.id}); Save-State; Write-Log 'Master Library definition deleted; source M3Us were not changed.' } }
}

function Manage-Profiles {
    if (@($State.profiles).Count -eq 0) { Write-Log 'No profiles registered.' 'WARN'; return }
    for ($i=0; $i -lt $State.profiles.Count; $i++) { Write-ArchiveHost ("{0}. [{1}] {2}" -f ($i+1),$State.profiles[$i].type,$State.profiles[$i].name) }
    $raw=Read-Host 'Select profile number to edit/rename/delete (Enter=cancel)'; $n=0
    if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $State.profiles.Count) { return }
    $item=$State.profiles[$n-1]; $action=Read-Default 'E=edit Master Library membership, R=rename, D=delete, B=rebuild' 'E'
    if ($action -match '^(?i:r)$') { $new=Read-Host 'New profile name'; if (-not [string]::IsNullOrWhiteSpace($new)) { $item.name=$new.Trim(); Save-State; Write-Log 'Profile renamed.' } }
    elseif ($action -match '^(?i:e)$') { $libs=@($State.masterLibraries | Where-Object {$_.type -eq $item.type}); for($i=0;$i -lt $libs.Count;$i++){ $mark=if($libs[$i].id -in @($item.masterLibraryIds)){'[X]'}else{'[ ]'}; Write-ArchiveHost ("{0}. {1} {2}" -f ($i+1),$mark,$libs[$i].name) }; $rawSelection=Read-Host 'Enter complete Master Library selection (comma-separated; A=all; Enter=cancel)'; if([string]::IsNullOrWhiteSpace($rawSelection)){return}; $ids=@(); if($rawSelection.Trim() -ieq 'A'){$ids=@($libs|%{$_.id})}else{foreach($part in ($rawSelection -split ',')){$x=0;if([int]::TryParse($part.Trim(),[ref]$x)-and $x -ge 1 -and $x -le $libs.Count){$ids+=$libs[$x-1].id}}}; if($ids.Count){$item.masterLibraryIds=@($ids|Select-Object -Unique);$item.lastBuildStatus='stale';Save-State;Build-Profile -Profile $item} }
    elseif ($action -match '^(?i:b)$') { Build-Profile -Profile $item }
    elseif ($action -match '^(?i:d)$') { $confirm=Read-Host "Type DELETE to remove profile '$($item.name)'"; if($confirm -ceq 'DELETE'){$State.profiles=@($State.profiles|Where-Object{$_.id -ne $item.id});Save-State;Write-Log 'Profile deleted.'} }
}

function Publish-SelectedProfile {
    param([ValidateSet('Any','Programme','Commercial')][string]$Type='Any')
    $profiles=if ($Type -eq 'Any') { @($State.profiles) } else { @($State.profiles | Where-Object { $_.type -eq $Type }) }
    if ($profiles.Count -eq 0) { Write-Log "No $Type profiles are available to publish. Create a profile from one or more collections first." 'WARN'; return }
    for ($i=0; $i -lt $profiles.Count; $i++) { Write-ArchiveHost ("{0}. {1}" -f ($i+1),$profiles[$i].name) }
    $raw=Read-Host "Select $Type profile number to publish as a Master Library (Enter=cancel)"
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $profiles.Count) { return }
    $profile=$profiles[$n-1]
    $directory=if ($profile.type -eq 'Commercial') {$CommercialPlaylistRoot} else {$PlaylistRoot}
    Publish-Profile -Profile $profile -Directory $directory
}

function Manage-SourceUpdates {
    if (@($State.sources).Count -eq 0) { Write-Log 'No registered sources are available to manage.' 'WARN'; return }
    do {
        Write-ArchiveHost "`n--- Source Update Management ---"
        for ($i=0; $i -lt $State.sources.Count; $i++) {
            $src=$State.sources[$i]
            if ($null -eq $src.PSObject.Properties['updateEnabled']) { $src | Add-Member -NotePropertyName updateEnabled -NotePropertyValue $true }
            $enabled=if ($src.updateEnabled) {'ENABLED'} else {'PAUSED'}
            Write-ArchiveHost ("{0}. [{1}] {2} | {3} | {4}" -f ($i+1),$src.type,$src.name,$enabled,$src.lastRefreshStatus)
        }
        Write-ArchiveHost '1 Enable/disable selected sources for scheduled updates'
        Write-ArchiveHost '2 Refresh selected sources now'
        Write-ArchiveHost '3 Enable all sources for scheduled updates'
        Write-ArchiveHost '4 Pause all sources for scheduled updates'
        Write-ArchiveHost '0 Back'
        $choice=Read-Host 'Select'
        if ($choice -in @('1','2')) {
            $raw=Read-Host 'Enter source numbers separated by commas (example: 1,3,4; Enter=cancel)'
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $indexes=@(); $valid=$true
            foreach ($part in ($raw -split ',')) {
                $n=0
                if (-not [int]::TryParse($part.Trim(),[ref]$n) -or $n -lt 1 -or $n -gt $State.sources.Count) { $valid=$false; break }
                $indexes += ($n-1)
            }
            if (-not $valid) { Write-Log 'Invalid source selection; no changes made.' 'WARN'; continue }
            $selected=@($indexes | Select-Object -Unique | ForEach-Object { $State.sources[$_] })
            if ($choice -eq '1') {
                $mode=Read-Default 'E=enable scheduled updates, P=pause scheduled updates' 'E'
                if ($mode -match '^(?i:e)$') { foreach ($src in $selected) { $src.updateEnabled=$true } }
                elseif ($mode -match '^(?i:p)$') { foreach ($src in $selected) { $src.updateEnabled=$false } }
                else { Write-Log 'Invalid choice; no changes made.' 'WARN'; continue }
                Save-State; Write-Log ("Updated scheduled-refresh selection for {0} source(s)." -f $selected.Count)
            } else {
                $ids=@($selected | ForEach-Object { [string]$_.id })
                Invoke-RefreshAllSources -SourceIds $ids
            }
        } elseif ($choice -eq '3') {
            foreach ($src in $State.sources) { $src.updateEnabled=$true }; Save-State; Write-Log 'All registered refreshable sources enabled for scheduled updates.'
        } elseif ($choice -eq '4') {
            foreach ($src in $State.sources) { $src.updateEnabled=$false }; Save-State; Write-Log 'All registered sources paused for scheduled updates.'
        } elseif ($choice -ne '0') { Write-ArchiveHost 'Invalid selection.' }
    } while ($choice -ne '0')
}

function Get-SourceDependencies {
    param($Source)
    $libraries = @($State.masterLibraries | Where-Object { [string]$Source.id -in @($_.sourceIds | ForEach-Object { [string]$_ }) })
    $libraryIds = @($libraries | ForEach-Object { [string]$_.id })
    $profiles = @($State.profiles | Where-Object { @($_.masterLibraryIds | ForEach-Object { [string]$_ }) | Where-Object { $_ -in $libraryIds } })
    $profileIds = @($profiles | ForEach-Object { [string]$_.id })
    $channels = @($State.channels | Where-Object { ([string]$_.programmeProfileId -in $profileIds) -or (@($_.commercialProfileIds | ForEach-Object { [string]$_ } | Where-Object { $_ -in $profileIds }).Count -gt 0) })
    return [pscustomobject]@{libraries=$libraries;profiles=$profiles;channels=$channels}
}
function Select-SourceNumbers {
    param([string]$Prompt='Enter source numbers separated by commas (Enter=cancel)')
    for ($i=0; $i -lt @($State.sources).Count; $i++) { $src=$State.sources[$i]; $paused=if($src.updateEnabled){'ACTIVE'}else{'PAUSED'}; $included=if($src.included -ne $false){'INCLUDED'}else{'EXCLUDED'}; Write-ArchiveHost ("{0}. [{1}] {2} | {3} entries | {4} | {5}" -f ($i+1),$src.type,$src.name,$src.itemCount,$paused,$included) }
    $raw=Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $selected=@(); foreach($part in ($raw -split ',')){ $n=0; if(-not [int]::TryParse($part.Trim(),[ref]$n) -or $n -lt 1 -or $n -gt @($State.sources).Count){Write-Log 'Invalid selection; no changes made.' 'WARN';return @()}; $selected += $State.sources[$n-1] }
    return @($selected | Sort-Object id -Unique)
}
function Set-IndividualSourceSchedules {
    $sel=Select-SourceNumbers -Prompt 'Select sources to configure (comma-separated; Enter=cancel)'
    foreach($src in $sel){
        $freq=Read-Default "Schedule for $($src.name): D=Daily, W=Weekly, M=Monthly, P=Manual" 'W'
        switch($freq.ToUpperInvariant()){
            'D' {$src.scheduleFrequency='Daily';$src.scheduleEnabled=$true}
            'W' {$src.scheduleFrequency='Weekly';$src.scheduleEnabled=$true}
            'M' {$src.scheduleFrequency='Monthly';$src.scheduleEnabled=$true}
            'P' {$src.scheduleFrequency='Manual';$src.scheduleEnabled=$false}
            default {Write-Log 'Invalid schedule choice; source left unchanged.' 'WARN'}
        }
    }
    Save-State
    Write-Log 'Individual source schedules saved. The Windows scheduled task dispatches daily and refreshes only sources due under their saved frequency.'
}

function Review-ClassificationFiles {
    $files=@(Get-ChildItem -LiteralPath $CheckpointRoot -Filter '*.review.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if(-not $files.Count){Write-ArchiveHost 'No uncertain classification records are waiting for review.';return}
    for($i=0;$i -lt $files.Count;$i++){Write-ArchiveHost ("{0}. {1} | {2} bytes | {3}" -f ($i+1),$files[$i].Name,$files[$i].Length,$files[$i].LastWriteTime)}
    $raw=Read-Host 'Select review file number (Enter=cancel)';$n=0
    if(-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $files.Count){return}
    $file=$files[$n-1];$reviewBackup=Join-Path $BackupRoot ($file.Name+'.'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak');Copy-Item -LiteralPath $file.FullName -Destination $reviewBackup -ErrorAction Stop;$programme=New-Object System.Collections.Generic.List[object];$commercial=New-Object System.Collections.Generic.List[object];$remaining=New-Object System.Collections.Generic.List[string]
    foreach($line in (Get-Content -LiteralPath $file.FullName -Encoding UTF8)){
        if([string]::IsNullOrWhiteSpace($line)){continue}
        try{$record=$line|ConvertFrom-Json}catch{$remaining.Add($line);continue}
        Write-ArchiveHost "`nTitle: $($record.title)`nIdentifier: $($record.identifier)`nReason: $($record.classificationReason)`nDescription: $($record.description)"
        $decision=Read-Default 'P=Programme, C=Commercial, S=leave for later, Q=finish review' 'S'
        if($decision -match '^(?i:P)$'){$record.classification='Programme';$programme.Add($record)}
        elseif($decision -match '^(?i:C)$'){$record.classification='Commercial';$commercial.Add($record)}
        elseif($decision -match '^(?i:Q)$'){$remaining.Add($line);break}
        else{$remaining.Add($line)}
    }
    $queryBase=[IO.Path]::GetFileNameWithoutExtension($file.Name)
    if($programme.Count){$out=Get-UniqueOutputPath -Directory $ProgrammeSources -BaseName ('Reviewed_Programme_'+$queryBase) -Extension '.m3u';Write-M3UFile -Path $out -Records $programme.ToArray() -Description 'Manually reviewed Archive.org programme records';Add-Source -Name ([IO.Path]::GetFileNameWithoutExtension($out)) -Type Programme -Path $out -Query ('Manual review: '+$queryBase) -Count $programme.Count -EndpointMode 'ManualReview' -Refreshable $false;Write-Log "Saved $($programme.Count) manually reviewed Programme records: $out"}
    if($commercial.Count){$out=Get-UniqueOutputPath -Directory $CommercialSources -BaseName ('Reviewed_Commercial_'+$queryBase) -Extension '.m3u';Write-M3UFile -Path $out -Records $commercial.ToArray() -Description 'Manually reviewed Archive.org commercial records';Add-Source -Name ([IO.Path]::GetFileNameWithoutExtension($out)) -Type Commercial -Path $out -Query ('Manual review: '+$queryBase) -Count $commercial.Count -EndpointMode 'ManualReview' -Refreshable $false;Write-Log "Saved $($commercial.Count) manually reviewed Commercial records: $out"}
    if($remaining.Count){Set-Content -LiteralPath $file.FullName -Value $remaining.ToArray() -Encoding UTF8}else{Remove-Item -LiteralPath $file.FullName -Force}
    Write-Log ("Classification review complete. Programme={0}; Commercial={1}; still pending={2}." -f $programme.Count,$commercial.Count,$remaining.Count)
}

function Manage-Sources {
    do {
        Write-ArchiveHost "`n--- Source Management ---`n1 View all registered sources`n2 Pause / resume scheduled updates`n3 Include / exclude sources from future Master Libraries`n4 Refresh selected sources now`n5 Permanently remove / unregister sources`n6 Review uncertain classifications`n7 Configure individual source schedules`n0 Back"
        $choice=Read-Host 'Select'
        switch($choice){
            '1' { if(@($State.sources).Count -eq 0){Write-ArchiveHost 'No sources registered.'} else { for($i=0;$i -lt $State.sources.Count;$i++){ $x=$State.sources[$i]; Write-ArchiveHost ("{0}. [{1}] {2} | Query={3} | Items={4} | Scheduled={5} | Included={6}`n   {7}" -f ($i+1),$x.type,$x.name,$x.query,$x.itemCount,$x.updateEnabled,$x.included,$x.path) } } }
            '2' { $sel=Select-SourceNumbers; if($sel.Count){$mode=Read-Default 'E=enable scheduled updates, P=pause scheduled updates' 'P'; if($mode -match '^(?i:E)$'){foreach($x in $sel){$x.updateEnabled=$true}} elseif($mode -match '^(?i:P)$'){foreach($x in $sel){$x.updateEnabled=$false}} else {Write-Log 'Invalid choice; no changes made.' 'WARN';continue};Save-State;Write-Log ("Updated pause state for {0} source(s)." -f $sel.Count)} }
            '3' { $sel=Select-SourceNumbers; if($sel.Count){$mode=Read-Default 'I=include for future Master Libraries, X=exclude from future Master Libraries' 'X'; if($mode -match '^(?i:I)$'){foreach($x in $sel){$x.included=$true}} elseif($mode -match '^(?i:X)$'){foreach($x in $sel){$x.included=$false}} else {Write-Log 'Invalid choice; no changes made.' 'WARN';continue};Save-State;Write-Log ("Updated future library inclusion for {0} source(s). Existing Master Libraries are not changed." -f $sel.Count)} }
            '4' { $sel=Select-SourceNumbers; if($sel.Count){Invoke-RefreshAllSources -SourceIds @($sel|ForEach-Object{[string]$_.id})} }
            '5' {
                $sel=Select-SourceNumbers; foreach($x in $sel){
                    $deps=Get-SourceDependencies -Source $x
                    Write-ArchiveHost "`nSOURCE: $($x.name)`nType: $($x.type)`nQuery: $($x.query)`nItems: $($x.itemCount)`nFile: $($x.path)"
                    Write-ArchiveHost ("Dependencies: {0} Master Libraries, {1} Profiles, {2} Channels" -f $deps.libraries.Count,$deps.profiles.Count,$deps.channels.Count) -ForegroundColor Yellow
                    foreach($d in $deps.libraries){Write-ArchiveHost "  Master Library: $($d.name)"}; foreach($d in $deps.profiles){Write-ArchiveHost "  Profile: $($d.name)"}; foreach($d in $deps.channels){Write-ArchiveHost "  Channel: $($d.name)"}
                    Write-ArchiveHost 'P=permanently unregister only; D=unregister and delete source M3U/checkpoint after backup; anything else cancels.'
                    $action=Read-Host 'Removal action'
                    if($action -notin @('P','D')){Write-ArchiveHost 'Cancelled; source unchanged.';continue}
                    $confirm=Read-Host "Type REMOVE $($x.id) to confirm this exact source"
                    if($confirm -cne ('REMOVE '+[string]$x.id)){Write-ArchiveHost 'Confirmation did not match; no changes made.';continue}
                    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'; $backupDir=Join-Path $ProjectRoot ('backups\source-removal\'+$stamp); New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                    Copy-Item -LiteralPath $StateFile -Destination (Join-Path $backupDir 'manager-state.json') -ErrorAction Stop
                    if(Test-Path -LiteralPath $x.path){Copy-Item -LiteralPath $x.path -Destination (Join-Path $backupDir ([IO.Path]::GetFileName($x.path))) -ErrorAction Stop}
                    $checkpointBase=Get-SafeFileName ([string]$x.query); $checkpointFiles=@(Get-ChildItem -LiteralPath $CheckpointRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($checkpointBase+'.*') }); foreach($cf in $checkpointFiles){Copy-Item -LiteralPath $cf.FullName -Destination $backupDir -ErrorAction Stop}
                    if($action -eq 'D') {
                        $sharedPath=@($State.sources|Where-Object{[string]$_.id -ne [string]$x.id -and [IO.Path]::GetFullPath([string]$_.path) -eq [IO.Path]::GetFullPath([string]$x.path)})
                        if($sharedPath.Count -gt 0){Write-Log 'The source M3U is also registered by another source record. File deletion was refused; choose unregister-only instead.' 'WARN';continue}
                        if(Test-Path -LiteralPath $x.path){Remove-Item -LiteralPath $x.path -Force}
                        $manifest=[IO.Path]::ChangeExtension([string]$x.path,'.manifest.json');if(Test-Path -LiteralPath $manifest){Remove-Item -LiteralPath $manifest -Force}
                        foreach($cf in $checkpointFiles){Remove-Item -LiteralPath $cf.FullName -Force}
                    }
                    $State.sources=@($State.sources|Where-Object{[string]$_.id -ne [string]$x.id}); Save-State
                    Write-Log ("Source {0} removed from manager. Backup: {1}. Dependent libraries were retained and may now require rebuilding." -f $x.name,$backupDir)
                }
            }
            '6' { Review-ClassificationFiles }
            '7' { Set-IndividualSourceSchedules }
            '0' {}
            default {Write-ArchiveHost 'Invalid selection.'}
        }
    } while($choice -ne '0')
}

function Manage-Channels {
    if (@($State.channels).Count -eq 0) { Write-Log 'No channels defined.' 'WARN'; return }
    for ($i=0; $i -lt $State.channels.Count; $i++) { Write-ArchiveHost ("{0}. {1}" -f ($i+1),$State.channels[$i].name) }
    $raw=Read-Host 'Select channel number to rename/delete (Enter=cancel)'
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $State.channels.Count) { return }
    $item=$State.channels[$n-1]; $action=Read-Default 'R=rename, D=delete' 'R'
    if ($action -match '^(?i:r)$') { $new=Read-Host 'New channel name'; if (-not [string]::IsNullOrWhiteSpace($new)) { $item.name=$new.Trim(); Save-State; Write-Log 'Channel renamed.' } }
    elseif ($action -match '^(?i:d)$') { $confirm=Read-Host "Type DELETE to remove channel '$($item.name)'"; if ($confirm -ceq 'DELETE') { $State.channels=@($State.channels | Where-Object {$_.id -ne $item.id}); Save-State; Write-Log 'Channel definition deleted; existing playlist files were not changed.' } }
}

function Restore-SourceBackup {
    if (@($State.sources).Count -eq 0) { Write-Log 'No registered sources are available for backup restoration.' 'WARN'; return }
    for ($i=0; $i -lt $State.sources.Count; $i++) { Write-ArchiveHost ("{0}. [{1}] {2}" -f ($i+1),$State.sources[$i].type,$State.sources[$i].name) }
    $raw=Read-Host 'Select source to restore (Enter=cancel)'
    $n=0; if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $State.sources.Count) { return }
    $source=$State.sources[$n-1]
    $base=[IO.Path]::GetFileName([string]$source.path)
    $backups=@(Get-ChildItem -LiteralPath $BackupRoot -Filter ($base+'.*.bak') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($backups.Count -eq 0) { Write-Log "No source-refresh backups found for '$base'." 'WARN'; return }
    for ($i=0; $i -lt $backups.Count; $i++) { Write-ArchiveHost ("{0}. {1} | {2}" -f ($i+1),$backups[$i].Name,$backups[$i].LastWriteTime) }
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
    if ($files.Count -eq 0) { Write-ArchiveHost 'No import checkpoints found.'; return }
    foreach ($file in $files) {
        try { $m=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; Write-ArchiveHost ("[{0}] {1} | examined={2} playable={3} | {4}" -f $m.status,$m.query,$m.examinedCount,$m.playableCount,$file.Name) }
        catch { Write-ArchiveHost ("[UNREADABLE] {0}" -f $file.Name) }
    }
}

function Show-RecentLogs {
    $latest=Get-ChildItem -LiteralPath $LogRoot -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $latest) { Write-ArchiveHost 'No manager logs found.'; return }
    Write-ArchiveHost "Latest log: $($latest.FullName)"
    Get-Content -LiteralPath $latest.FullName -Tail 30 -Encoding UTF8
}

function Show-SystemDiagnostics {
    Write-ArchiveHost ("PowerShell: {0}" -f $PSVersionTable.PSVersion)
    Write-ArchiveHost ("Project root: {0}" -f $ProjectRoot)
    Write-ArchiveHost ("Project root exists: {0}" -f (Test-Path -LiteralPath $ProjectRoot))
    $drive=Get-PSDrive -Name D -ErrorAction SilentlyContinue
    if ($null -ne $drive) { Write-ArchiveHost ("D: free space (GB): {0:N1}" -f ($drive.Free/1GB)) } else { Write-ArchiveHost 'D: drive is not available.' }
    Write-ArchiveHost ("Runtime source exists: {0}" -f (Test-Path -LiteralPath $RuntimePath))
    Write-ArchiveHost ("Manager state exists: {0}" -f (Test-Path -LiteralPath $StateFile))
    Write-ArchiveHost ("Checkpoint files: {0}" -f @(Get-ChildItem -LiteralPath $CheckpointRoot -Filter '*.checkpoint.json' -File -ErrorAction SilentlyContinue).Count)
    Write-ArchiveHost ("Source refresh backups: {0}" -f @(Get-ChildItem -LiteralPath $BackupRoot -Filter '*.bak' -File -ErrorAction SilentlyContinue).Count)
}

function Refresh-MasterLibrarySources {
    $libraries=@($State.masterLibraries)
    if ($libraries.Count -eq 0) { Write-Log 'No Master Libraries exist yet. Create a Master Library first.' 'WARN'; return }
    for ($i=0; $i -lt $libraries.Count; $i++) {
        Write-ArchiveHost ("{0}. [{1}] {2} | selected sources: {3}" -f ($i+1),$libraries[$i].type,$libraries[$i].name,@($libraries[$i].sourceIds).Count)
    }
    $raw=Read-Host 'Select Master Library number (Enter=cancel)'
    $n=0
    if (-not [int]::TryParse($raw,[ref]$n) -or $n -lt 1 -or $n -gt $libraries.Count) { return }
    $library=$libraries[$n-1]
    $sources=@($State.sources | Where-Object { $_.id -in @($library.sourceIds) })
    if ($sources.Count -eq 0) { Write-Log "Master Library '$($library.name)' has no registered source members." 'WARN'; return }
    Write-ArchiveHost "Sources belonging to '$($library.name)':"
    for ($i=0; $i -lt $sources.Count; $i++) {
        $enabled=if ($sources[$i].updateEnabled) {'scheduled'} else {'paused'}
        Write-ArchiveHost ("{0}. [{1}] {2} | {3}" -f ($i+1),$sources[$i].type,$sources[$i].name,$enabled)
    }
    Write-ArchiveHost 'Enter source numbers separated by commas, A=all sources in this Master Library, Enter=cancel.'
    $selection=Read-Host 'Sources to refresh now'
    if ([string]::IsNullOrWhiteSpace($selection)) { return }
    if ($selection.Trim() -ieq 'A') { $selected=$sources }
    else {
        $indexes=@(); $valid=$true
        foreach ($part in ($selection -split ',')) {
            $index=0
            if (-not [int]::TryParse($part.Trim(),[ref]$index) -or $index -lt 1 -or $index -gt $sources.Count) { $valid=$false; break }
            $indexes += ($index-1)
        }
        if (-not $valid) { Write-Log 'Invalid source selection; no sources were refreshed.' 'WARN'; return }
        $selected=@($indexes | Select-Object -Unique | ForEach-Object { $sources[$_] })
    }
    $ids=@($selected | ForEach-Object { [string]$_.id })
    Write-Log ("Refreshing {0} selected source(s) from Master Library '{1}'. Any other Master Libraries using those sources will also be rebuilt." -f $ids.Count,$library.name)
    Invoke-RefreshAllSources -SourceIds $ids
}

function Show-SourceMenu {
    do {
        Write-ArchiveHost "`n--- STEP 1: Source Management ---`n1 Import Archive.org search URL/query (automatic Programme/Commercial split)`n2 Register existing source M3U`n3 Resume interrupted import`n4 Source Management (view, pause, include/exclude, remove, refresh, review)`n5 Show source/updater status`n0 Back"
        $c=Read-Host 'Select'
        switch ($c) {
            '1' {Import-ArchiveSource}
            '2' {Register-ExistingSource}
            '3' {Resume-InterruptedImports}
            '4' {Manage-Sources}
            '5' {Show-Overview;Show-RefreshStatus}
            '0' {}
            default {Write-ArchiveHost 'Invalid selection.'}
        }
    } while ($c -ne '0')
}
function Show-MasterMenu {
    do {
        Write-ArchiveHost "`n--- STEP 2: Master Library Management ---`nEach Master Library contains only its explicitly selected source M3Us. Refreshing a source also updates every dependent Master Library, Profile and Channel Playlist.`n1 Create Master Library and select source M3Us`n2 Manage/edit source membership/rename/delete/rebuild Master Libraries`n3 Rebuild all Master Libraries from their current source M3Us`n4 Refresh all refreshable registered sources now`n5 Choose a Master Library and select which of its sources to refresh now`n6 Manage which sources are enabled or paused for scheduled updates`n7 Configure language filtering for a Master Library`n0 Back"
        $c=Read-Host 'Select'
        switch ($c) {
            '1' {Create-MasterLibrary}
            '2' {Manage-MasterLibraries}
            '3' {Invoke-UpdateHierarchy -All}
            '4' {Invoke-RefreshAllSources}
            '5' {Refresh-MasterLibrarySources}
            '6' {Manage-SourceUpdates}
            '7' {Set-MasterLibraryLanguageFiltering}
            '0' {}
            default {Write-ArchiveHost 'Invalid selection.'}
        }
    } while ($c -ne '0')
}
function Show-ProfileMenu {
    do { Write-ArchiveHost "`n--- STEP 3: Profile Management ---`nProfiles combine one or more language-filtered Master Libraries and apply downstream genre/decade/label filters.`n1 Create Programme or Commercial profile from selected Master Libraries`n2 Manage/edit/rename/delete/rebuild profiles`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Create-Profile} '2' {Manage-Profiles} '0' {} default {Write-ArchiveHost 'Invalid selection.'} }
    } while ($c -ne '0')
}

function Show-ChannelMenu {
    do { Write-ArchiveHost "`n--- STEP 4: Channel Management ---`n1 Define programme channel`n2 Manage/rename/delete channels`n3 Publish operational channel playlists`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Define-Channel} '2' {Manage-Channels} '3' {Publish-Channels} '0' {} default {Write-ArchiveHost 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-PublishMenu {
    do { Write-ArchiveHost "`n--- STEP 5: Publish Channel Playlists ---`nMaster Libraries are managed in Step 2.`n1 Publish/update operational channel playlists`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Publish-Channels} '0' {} default {Write-ArchiveHost 'Invalid selection.'} }
    } while ($c -ne '0')
}

function Show-RandomizationMenu {
    do { Write-ArchiveHost "`n--- Randomization ---`n1 Randomize Programme Now`n2 Randomize Commercials Now`n3 Randomize Both Now`n4 Randomize published Master Libraries`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Randomize-PlaybackNow -Group Programme} '2' {Randomize-PlaybackNow -Group Commercial} '3' {Randomize-PlaybackNow -Group Both} '4' {Randomize-MasterLibrariesNow} '0' {} default {Write-ArchiveHost 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-SchedulingMenu {
    do { Write-ArchiveHost "`n--- Scheduling and Automation ---`n1 Schedule automatic source + hierarchy updates`n2 Refresh sources and update dependent hierarchy now`n3 Update entire hierarchy now (without source refresh)`n4 Show updater/dependency status`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Register-SourceRefreshSchedule} '2' {Invoke-RefreshAllSources} '3' {Invoke-UpdateHierarchy -All} '4' {Show-RefreshStatus} '0' {} default {Write-ArchiveHost 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-LiveMenu {
    do { Write-ArchiveHost "`n--- Live Playback ---`n1 Install/update runtime playback controls (backup + Python syntax check)`n2 Randomize Programme Now`n3 Randomize Commercials Now`n4 Randomize Both Now`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {$confirm=Read-Host 'This backs up and updates the Python runtime on D: only. No Docker restart/rebuild. Type YES to continue'; if($confirm -ceq 'YES'){Install-LiveRuntimeIntegration}} '2' {Randomize-PlaybackNow -Group Programme} '3' {Randomize-PlaybackNow -Group Commercial} '4' {Randomize-PlaybackNow -Group Both} '0' {} default {Write-ArchiveHost 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-LanguageMenu {
    do { Write-ArchiveHost "`n--- Language and Filtering Settings ---`nLanguage filtering is now configured separately for each Master Library.`n1 Configure a Master Library language filter`n2 Show Master Library language settings`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Set-MasterLibraryLanguageFiltering} '2' {Show-LanguageSettings} '0' {} default {Write-ArchiveHost 'Invalid selection.'} }
    } while ($c -ne '0')
}
function Show-SystemMenu {
    do { Write-ArchiveHost "`n--- System and Maintenance ---`n1 Manager overview`n2 Restore source from backup`n3 Checkpoint and recovery status`n4 Recent log entries`n5 System diagnostics`n6 Show refresh status`n7 Show language settings`n0 Back"; $c=Read-Host 'Select'
        switch ($c) { '1' {Show-Overview} '2' {Restore-SourceBackup} '3' {Show-CheckpointStatus} '4' {Show-RecentLogs} '5' {Show-SystemDiagnostics} '6' {Show-RefreshStatus} '7' {Show-LanguageSettings} '0' {} default {Write-ArchiveHost 'Invalid selection.'} }
    } while ($c -ne '0')
}

function Show-Overview {
    Write-ArchiveHost ''
    Write-ArchiveHost "Sources: $(@($State.sources).Count)"
    foreach ($s in $State.sources) { Write-ArchiveHost "  [$($s.type)] $($s.name) | $($s.itemCount) entries | $($s.path)" }
    Write-ArchiveHost "Master Libraries: $(@($State.masterLibraries).Count)"
    foreach ($m in $State.masterLibraries) { Write-ArchiveHost "  [$($m.type)] $($m.name) | sources=$(@($m.sourceIds).Count) | language=$($m.languageSettings.mode) | status=$($m.status)" }
    Write-ArchiveHost "Profiles: $(@($State.profiles).Count)"
    foreach ($p in $State.profiles) { Write-ArchiveHost "  [$($p.type)] $($p.name)" }
    Write-ArchiveHost "Channels: $(@($State.channels).Count)"
    foreach ($c in $State.channels) { Write-ArchiveHost "  $($c.name)" }
    Write-ArchiveHost ''
    Write-ArchiveHost "Programme source M3Us: $ProgrammeSources"
    Write-ArchiveHost "Commercial source M3Us: $CommercialSources"
    Write-ArchiveHost "Programme operational playlists: $PlaylistRoot"
    Write-ArchiveHost "Commercial operational playlists: $CommercialPlaylistRoot"
    Write-ArchiveHost "Manager state: $StateFile"
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
    $profilePath=[string](Get-OptionalPropertyValue -Object $Profile -Name 'path' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($profilePath) -and (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        foreach ($entry in (Read-M3UEntries -Paths @($profilePath))) { $all.Add($entry) }
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

function Test-SourceScheduleDue {
    param($Source)
    if (-not $Source.updateEnabled -or $Source.scheduleEnabled -eq $false) { return $false }
    $frequency=[string](Get-OptionalPropertyValue -Object $Source -Name 'scheduleFrequency' -Default 'Weekly')
    if($frequency -eq 'Manual'){return $false}
    $last=[datetime]::MinValue
    $lastText=[string](Get-OptionalPropertyValue -Object $Source -Name 'lastScheduledRefresh' -Default '')
    if(-not $lastText){$lastText=[string](Get-OptionalPropertyValue -Object $Source -Name 'lastRefresh' -Default '')}
    if($lastText -and [datetime]::TryParse($lastText,[ref]$last)){
        $next=switch($frequency){'Daily'{$last.AddDays(1)} 'Monthly'{$last.AddMonths(1)} default{$last.AddDays(7)}}
        return ((Get-Date) -ge $next)
    }
    return $true
}
function Invoke-RefreshAllSources {
    param([switch]$Scheduled,[string[]]$SourceIds)
    $lock=Enter-ManagerOperationLock
    try {
        $successfulSourceIds=@();$processed=@{}
        $refreshable=@($State.sources|Where-Object{
            $ok=$_.refreshable -and -not [string]::IsNullOrWhiteSpace([string]$_.query) -and (Test-Path -LiteralPath ([string]$_.path))
            if($Scheduled -and -not (Test-SourceScheduleDue -Source $_)){$ok=$false}
            if($SourceIds -and ([string]$_.id -notin $SourceIds)){$ok=$false}
            $ok
        })
        if(-not $refreshable.Count){Write-Log 'No sources are due or eligible for the selected refresh.' 'WARN';return}
        foreach($source in $refreshable){
            $groupId=[string](Get-OptionalPropertyValue -Object $source -Name 'refreshGroupId' -Default '')
            $key=if($groupId){$groupId}else{[string]$source.id}
            if($processed.ContainsKey($key)){continue};$processed[$key]=$true
            $members=if($groupId){@($State.sources|Where-Object{[string]$_.refreshGroupId -eq $groupId})}else{@($source)}
            if($Scheduled){$members=@($members|Where-Object{Test-SourceScheduleDue -Source $_})}
            if(-not $members.Count){continue}
            $script:ExcludeNonEnglish=$false
            $base=Get-SafeFileName ('Refresh_'+$key+'_'+(Get-Date -Format 'yyyyMMddHHmmss'))
            try{
                if($groupId){
                    Write-Log "Refreshing paired Programme and Commercial outputs from one saved query: '$($source.query)'."
                    $result=Import-ScrapeApi -Query ([string]$source.query) -OutputDirectory $RefreshStaging -BaseName $base -ExpectedCount 0 -SplitCommercials
                    foreach($member in $members){
                        $newPath=if($member.type -eq 'Programme'){$result.programmePath}else{$result.commercialPath}
                        $newCount=if($member.type -eq 'Programme'){$result.programmeCount}else{$result.commercialCount}
                        if(-not $newPath -or -not(Test-Path -LiteralPath $newPath)){Write-Log "No new $($member.type) entries were classified for '$($member.name)'; previous complete file retained." 'WARN';continue}
                        $backupName=[IO.Path]::GetFileName([string]$member.path)+'.'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak'
                        $backupPath=Join-Path $BackupRoot $backupName
                        Copy-Item -LiteralPath $member.path -Destination $backupPath -ErrorAction Stop
                        $temp=[string]$member.path+'.refresh.tmp'
                        Copy-Item -LiteralPath $newPath -Destination $temp -Force -ErrorAction Stop
                        Move-Item -LiteralPath $temp -Destination ([string]$member.path) -Force -ErrorAction Stop
                        $newManifest=[IO.Path]::ChangeExtension($newPath,'.manifest.json')
                        $oldManifest=[IO.Path]::ChangeExtension([string]$member.path,'.manifest.json')
                        if(Test-Path -LiteralPath $newManifest){Copy-Item -LiteralPath $newManifest -Destination $oldManifest -Force}
                        $member.itemCount=[int]$newCount;$member.lastRefresh=(Get-Date).ToString('o');$member.lastScheduledRefresh=(Get-Date).ToString('o');$member.lastRefreshStatus='complete';$member.pendingRefreshBase=''
                        $member.nextScheduledRefresh=if($member.scheduleFrequency -eq 'Daily'){(Get-Date).AddDays(1).ToString('o')}elseif($member.scheduleFrequency -eq 'Monthly'){(Get-Date).AddMonths(1).ToString('o')}else{(Get-Date).AddDays(7).ToString('o')}
                        $successfulSourceIds += [string]$member.id
                        Write-Log "Updated $($member.type) source '$($member.name)' ($newCount entries). Backup: $backupPath"
                        Remove-Item -LiteralPath $newPath -Force -ErrorAction SilentlyContinue
                        if(Test-Path -LiteralPath $newManifest){Remove-Item -LiteralPath $newManifest -Force -ErrorAction SilentlyContinue}
                    }
                    foreach($candidate in @($result.programmePath,$result.commercialPath)){if($candidate -and (Test-Path -LiteralPath $candidate)){Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue;$mf=[IO.Path]::ChangeExtension($candidate,'.manifest.json');if(Test-Path -LiteralPath $mf){Remove-Item -LiteralPath $mf -Force -ErrorAction SilentlyContinue}}}
                }else{
                    $result=Import-ScrapeApi -Query ([string]$source.query) -OutputDirectory $RefreshStaging -BaseName $base -ExpectedCount ([long]$source.expectedCount)
                    if(-not(Test-Path -LiteralPath $result.path -PathType Leaf)){throw 'Refresh import did not produce a complete M3U file.'}
                    if((Get-Content -LiteralPath $result.path -TotalCount 1 -Encoding UTF8) -ne '#EXTM3U'){throw 'Refresh output failed M3U validation.'}
                    $backupName=[IO.Path]::GetFileName([string]$source.path)+'.'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak';$backupPath=Join-Path $BackupRoot $backupName
                    Copy-Item -LiteralPath $source.path -Destination $backupPath -ErrorAction Stop
                    $temp=[string]$source.path+'.refresh.tmp';Copy-Item -LiteralPath $result.path -Destination $temp -Force;Move-Item -LiteralPath $temp -Destination ([string]$source.path) -Force
                    $source.itemCount=[int]$result.count;$source.lastRefresh=(Get-Date).ToString('o');$source.lastScheduledRefresh=(Get-Date).ToString('o');$source.lastRefreshStatus='complete';$successfulSourceIds += [string]$source.id
                    Write-Log "Updated source '$($source.name)' with $($result.count) entries. Backup: $backupPath"
                }
                Save-State
            }catch{
                foreach($member in $members){$member.lastRefresh=(Get-Date).ToString('o');$member.lastRefreshStatus='failed: '+$_.Exception.Message};Save-State
                Write-Log "Refresh failed for source group '$key'; previous completed files were retained wherever replacement had not occurred. $($_.Exception.Message)" 'ERROR'
            }
        }
        if($successfulSourceIds.Count){Invoke-UpdateHierarchy -SourceIds $successfulSourceIds}
    }finally{Exit-ManagerOperationLock -LockStream $lock}
}

function Register-SourceRefreshSchedule {
    $frequency = 'DailyDispatcher'
    Write-ArchiveHost 'The Windows task runs a daily dispatcher. Each source controls its own Daily, Weekly, Monthly or Manual schedule in Source Management.'
    $timeText = Read-Default 'Local run time (HH:mm)' '03:00'
    $runTime = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($timeText,'HH:mm',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$runTime)) { throw 'Enter schedule time as HH:mm, for example 03:00.' }
    Import-Module ScheduledTasks -ErrorAction Stop
    $at = Get-Date -Hour $runTime.Hour -Minute $runTime.Minute -Second 0
    # Daily dispatcher checks each source's own saved schedule and due date.
    $trigger = New-ScheduledTaskTrigger -Daily -At $at
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ScheduledRefresh' -f $PSCommandPath
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $arguments
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 12)
    Register-ScheduledTask -TaskName 'ArchiveTV-Source-Hierarchy-Refresh' -Action $action -Trigger $trigger -Settings $settings -Description 'Refresh Archive TV source M3Us and cascade updates to dependent Master Libraries, profiles and channels; backups remain on D:.' -Force | Out-Null
    [pscustomobject]@{frequency='DailyDispatcher';time=$timeText;taskName='ArchiveTV-Source-Hierarchy-Refresh';updated=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $ScheduleConfigPath -Encoding UTF8
    Write-Log "Scheduled source + hierarchy refresh registered: $frequency at $timeText (local time). Computer must be on and able to run the task. The task is a daily dispatcher; source-level schedule settings control eligibility."
}

function Show-RefreshStatus {
    $task = Get-ScheduledTask -TaskName 'ArchiveTV-Source-Hierarchy-Refresh' -ErrorAction SilentlyContinue
    if ($null -eq $task) { Write-ArchiveHost 'Scheduled updater: not registered.' } else { Write-ArchiveHost ("Scheduled updater: {0} ({1})" -f $task.State,$task.TaskName) }
    foreach ($source in @($State.sources)) {
        Write-ArchiveHost ("SOURCE [{0}] {1} | Refreshable={2} | Enabled={3} | Schedule={4} | Next={5} | Last={6} | Status={7}" -f $source.type,$source.name,$source.refreshable,$source.updateEnabled,$source.scheduleFrequency,$source.nextScheduledRefresh,$source.lastRefresh,$source.lastRefreshStatus)
    }
    foreach ($library in @($State.masterLibraries)) { Write-ArchiveHost ("MASTER [{0}] {1} | sources={2} | entries={3} | Updated={4} | Status={5}" -f $library.type,$library.name,@($library.sourceIds).Count,$library.itemCount,$library.updated,$library.status) }
    foreach ($profile in @($State.profiles)) { Write-ArchiveHost ("PROFILE [{0}] {1} | MasterLibraries={2} | Updated={3} | Status={4}" -f $profile.type,$profile.name,@($profile.masterLibraryIds).Count,$profile.lastBuild,$profile.lastBuildStatus) }
    if (Test-Path -LiteralPath $HierarchyStatusPath) { try { $h=Get-Content -LiteralPath $HierarchyStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json; Write-ArchiveHost ("LAST HIERARCHY RUN: {0} | Result={1} | MasterLibraries={2} | Profiles={3} | Failures={4}" -f $h.updated,$h.result,@($h.masterLibrariesUpdated).Count,@($h.profilesUpdated).Count,@($h.failures).Count) } catch {} }
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
Write-Log 'Fresh v5.8.5 started. Existing manager state is preserved and legacy collections are migrated into Master Libraries; new installations begin empty.'

if ($ScheduledRefresh) {
    try { Invoke-RefreshAllSources -Scheduled }
    catch { Write-Log $_.Exception.Message 'ERROR'; exit 2 }
    Write-Log 'Scheduled source refresh run finished.'
    exit 0
}

do {
    Write-ArchiveHost ''
    Write-ArchiveHost '===== Archive TV Source Library Manager - Fresh v5.8.5 =====' -ForegroundColor Cyan
    Write-ArchiveHost ''
    Write-ArchiveHost 'INITIAL CONTENT WORKFLOW (follow in order)'
    Write-ArchiveHost '  1 Import full Archive.org source M3Us' -ForegroundColor Cyan
    Write-ArchiveHost '  2 Create Master Libraries and select their source M3Us' -ForegroundColor Cyan
    Write-ArchiveHost '  3 Create Profiles from one or more Master Libraries' -ForegroundColor Cyan
    Write-ArchiveHost '  4 Channel Management' -ForegroundColor Cyan
    Write-ArchiveHost '  5 Publish operational channel playlists' -ForegroundColor Cyan
    Write-ArchiveHost ''
    Write-ArchiveHost 'ONGOING MANAGEMENT'
    Write-ArchiveHost '  6 Randomization' -ForegroundColor Blue
    Write-ArchiveHost '  7 Scheduling and automatic hierarchy updates' -ForegroundColor Yellow
    Write-ArchiveHost '  8 Live Playback' -ForegroundColor DarkCyan
    Write-ArchiveHost '  9 System and Maintenance' -ForegroundColor DarkGray
    Write-ArchiveHost '  0 Exit' -ForegroundColor DarkGray
    $choice=Read-Host 'Select section (blank=exit)'
    if ([string]::IsNullOrWhiteSpace([string]$choice)) { break }
    try {
        switch ($choice) {
            '1' { Show-SourceMenu }
            '2' { Show-MasterMenu }
            '3' { Show-ProfileMenu }
            '4' { Show-ChannelMenu }
            '5' { Show-PublishMenu }
            '6' { Show-RandomizationMenu }
            '7' { Show-SchedulingMenu }
            '8' { Show-LiveMenu }
            '9' { Show-SystemMenu }
            '0' { break }
            default { Write-ArchiveHost 'Invalid selection.' }
        }
    } catch { Write-Log $_.Exception.Message 'ERROR'; if ($_.ScriptStackTrace) { Write-Log ($_.ScriptStackTrace -replace '[\r\n]+',' | ') 'ERROR' } }
} while ($choice -ne '0')

Write-Log 'Fresh v5.8.5 exited.'
