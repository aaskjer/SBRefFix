# SBRefFix - see README.md

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [string[]] $Path,
    [string] $OutDir,
    [string] $SbFolder,
    [switch] $Check,
    [switch] $NoBackup,
    [switch] $Strict,
    [switch] $Watch,
    [switch] $Recurse,
    [switch] $Clipboard,
    [switch] $ImportString
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions

$utf8 = New-Object System.Text.UTF8Encoding $false
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$winRoot = $env:SystemRoot
if (-not $winRoot) { $winRoot = 'C:\Windows' }
$winRoot = $winRoot.TrimEnd('\', '/')
$winDrive = $winRoot.Substring(0, 1)

$builtIn = @('Streamer.bot.Plugin.Interface.dll', 'Streamer.bot.Common.dll', 'Newtonsoft.Json.dll', 'Twitch.Common.dll')

# ---------------------------------------------------------------- export file format

function ConvertFrom-Export([string] $text, [string] $name) {
    try { $bytes = [Convert]::FromBase64String($text.Trim()) } catch { throw "$name is not a Streamer.bot export: it is not Base64." }
    if ($bytes.Length -lt 5 -or [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'SBAE') {
        throw "$name is not a Streamer.bot export: it does not start with SBAE."
    }
    $packed = [System.IO.MemoryStream]::new($bytes, 4, $bytes.Length - 4)
    $gzip = [System.IO.Compression.GZipStream]::new($packed, [System.IO.Compression.CompressionMode]::Decompress)
    $plain = [System.IO.MemoryStream]::new()
    try { $gzip.CopyTo($plain) } catch { throw "$name is not a Streamer.bot export: its content is not gzip." } finally { $gzip.Dispose() }
    $json = $plain.ToArray()
    # gzip ends on the unpacked length, so a string cut short or with other text stuck to its end shows here.
    if ([BitConverter]::ToUInt32($bytes, $bytes.Length - 4) -ne $json.Length) {
        throw "$name is not a whole Streamer.bot export: it is cut short, or other text is stuck to its end."
    }
    $bom = $json.Length -ge 3 -and $json[0] -eq 0xEF -and $json[1] -eq 0xBB -and $json[2] -eq 0xBF
    $start = 0
    if ($bom) { $start = 3 }
    return @{ Json = $utf8.GetString($json, $start, $json.Length - $start); Bom = $bom }
}

function ConvertTo-Export([string] $json, [bool] $bom) {
    $body = $utf8.GetBytes($json)
    $packed = [System.IO.MemoryStream]::new()
    $packed.Write([byte[]](0x53, 0x42, 0x41, 0x45), 0, 4)
    $gzip = [System.IO.Compression.GZipStream]::new($packed, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    if ($bom) { $gzip.Write([byte[]](0xEF, 0xBB, 0xBF), 0, 3) }
    $gzip.Write($body, 0, $body.Length)
    $gzip.Dispose()
    return [Convert]::ToBase64String($packed.ToArray())
}

# ---------------------------------------------------------------- import strings in text

$importStart = [regex] '(?<![A-Za-z0-9+/=])U0JBR'   # SBAE in Base64
$importFirst = [regex] '\G[A-Za-z0-9+/]*=*'
$importNext = [regex] '\G[ \t]*(\r?\n)([ \t]*)([A-Za-z0-9+/]+=*)[ \t]*(?=\r?\n|$)'

function Test-TextFile([string] $file) { return ([System.IO.Path]::GetExtension($file) -in @('.txt', '.md')) }

# A text file as characters that write back to the very same bytes: UTF-16 by its byte order mark, anything
# else byte for byte, which leaves UTF-8 and ANSI text around the import string untouched.
function Read-TextFile([string] $file) {
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $encoding = [System.Text.Encoding]::GetEncoding(28591)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $encoding = New-Object System.Text.UnicodeEncoding $false, $false }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $encoding = New-Object System.Text.UnicodeEncoding $true, $false }
    return @{ Text = $encoding.GetString($bytes); Encoding = $encoding }
}

# Every Base64 block starting with U0JBR that is long enough to be an export. A block may be wrapped over
# many lines; it ends at a line that is not Base64, after padding, or after a line shorter than the ones above.
function Get-ImportBlocks([string] $text) {
    $blocks = @()
    $at = 0
    while (($start = $importStart.Match($text, $at)).Success) {
        $line = $importFirst.Match($text, $start.Index).Value
        $end = $start.Index + $line.Length
        $base64 = [System.Text.StringBuilder]::new($line)
        $lines = 1
        $width = $line.Length
        $newline = "`n"
        $indent = ''
        while (-not $line.EndsWith('=')) {
            $next = $importNext.Match($text, $end)
            if (-not $next.Success) { break }
            $line = $next.Groups[3].Value
            if ($lines -eq 1) { $newline = $next.Groups[1].Value; $indent = $next.Groups[2].Value }
            [void] $base64.Append($line)
            $lines++
            $end = $next.Groups[3].Index + $line.Length
            if ($line.Length -lt $width) { break }
            $width = $line.Length
        }
        $at = $end
        # Shorter than the smallest gzip stream: the start of a string quoted in prose, not an export.
        if ($base64.Length -lt 32) { continue }
        if ($lines -eq 1) { $width = 0 }
        $blocks += @{ Start = $start.Index; End = $end; Base64 = $base64.ToString(); Width = $width; Newline = $newline; Indent = $indent }
    }
    return ,$blocks
}

function Find-ImportString([string] $text, [string] $name) {
    $blocks = Get-ImportBlocks $text
    if ($blocks.Count -eq 0) { throw "$name holds no Streamer.bot import string: nothing in it starts with U0JBR." }
    if ($blocks.Count -gt 1) { throw "$name holds $($blocks.Count) import strings; give SBRefFix one at a time." }
    return $blocks[0]
}

# The repaired string laid out like the one it replaces: on one line, or wrapped at the same width.
function Format-ImportString([string] $base64, $block) {
    if ($block.Width -eq 0) { return $base64 }
    $lines = for ($i = 0; $i -lt $base64.Length; $i += $block.Width) { $base64.Substring($i, [Math]::Min($block.Width, $base64.Length - $i)) }
    return ($lines -join ($block.Newline + $block.Indent))
}

# Wrapped, so the tests can put a file in place of the clipboard.
function Get-ClipboardText { return (Get-Clipboard -Raw) }
function Set-ClipboardText([string] $text) { Set-Clipboard -Value $text }

# Every string in a references list, with the action it belongs to, in document order.
function Get-References([string] $json) {
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 4096
    try { $doc = $serializer.DeserializeObject($json) } catch { throw "the export's JSON cannot be read: $($_.Exception.Message)" }
    $found = New-Object 'System.Collections.Generic.List[object]'
    Add-References $doc '(no action)' $found
    return ,$found
}

function Add-References($node, [string] $action, $found) {
    if ($node -is [System.Collections.Generic.IDictionary[string, object]]) {
        if ($node.ContainsKey('subActions') -and $node.ContainsKey('triggers') -and $node['name'] -is [string]) { $action = $node['name'] }
        if ($node.ContainsKey('references') -and $node['references'] -is [object[]]) {
            foreach ($ref in $node['references']) {
                if ($ref -is [string]) { $found.Add([pscustomobject]@{ Action = $action; Ref = $ref }) }
            }
        }
        foreach ($value in $node.Values) { Add-References $value $action $found }
    } elseif ($node -is [object[]]) {
        foreach ($value in $node) { Add-References $value $action $found }
    }
}

function ConvertTo-JsonText([string] $s) { return '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }

function Measure-Text([string] $text, [string] $part) {
    $count = 0
    $at = $text.IndexOf($part, [StringComparison]::Ordinal)
    while ($at -ge 0) {
        $count++
        $at = $text.IndexOf($part, $at + $part.Length, [StringComparison]::Ordinal)
    }
    return $count
}

# ---------------------------------------------------------------- the verdict on one reference

function Get-LocalNames($refs) {
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $builtIn) { [void] $names.Add($n) }
    foreach ($ref in $refs) {
        $r = $ref.Ref.Trim()
        if ($r -match '^[A-Za-z]:[\\/]' -or $r -match '^[\\/]') { continue }
        if ($r -match '^\.\.[\\/]') { continue }
        $leaf = Split-Path -Leaf ($r -replace '/', '\')
        if ($leaf -and $leaf -eq ($r -replace '^\.[\\/]', '')) { [void] $names.Add($leaf) }
    }
    if ($SbFolder -and (Test-Path -LiteralPath $SbFolder -PathType Container)) {
        foreach ($f in (Get-ChildItem -LiteralPath $SbFolder -Filter '*.dll' -File)) { [void] $names.Add($f.Name) }
    }
    return ,$names   # a set returned bare would be unrolled into an array
}

# 'ok', 'fix' (New is the repaired path) or 'bad'.
function Get-Verdict([string] $ref, $localNames) {
    $r = $ref.Trim()
    if ($r -eq '') { return @{ Kind = 'bad'; Why = 'an empty reference' } }
    if ($r -match '^[\\/]{2}') { return @{ Kind = 'bad'; Why = 'a network path' } }

    if ($r -match '^([A-Za-z]):[\\/](.*)$') {
        $drive = $Matches[1]
        $rest = $Matches[2]
        if ($rest -match '^(?i)Windows[\\/](.*)$') {
            if ($drive -ieq $winDrive) { return @{ Kind = 'ok' } }
            return @{ Kind = 'fix'; New = $winRoot + '\' + ($Matches[1] -replace '/', '\'); Why = "Windows on drive ${drive}, this PC has it on drive ${winDrive}" }
        }
        $leaf = Split-Path -Leaf ($r -replace '/', '\')
        if ($localNames.Contains($leaf)) {
            return @{ Kind = 'fix'; New = '.\' + $leaf; Why = 'a rooted path to a DLL that sits in the Streamer.bot folder' }
        }
        return @{ Kind = 'bad'; Why = 'a rooted path outside Windows, found on the exporting PC only' }
    }

    $rest = $r
    $climbs = $false
    # A path rooted without a drive resolves on the drive Streamer.bot runs from.
    if ($rest -match '^[\\/]') { $climbs = $true; $rest = $rest.TrimStart([char[]]'\/') }
    while ($true) {
        if ($rest -match '^\.\.[\\/]') { $climbs = $true; $rest = $rest.Substring(3) }
        elseif ($rest -match '^\.[\\/]') { $rest = $rest.Substring(2) }
        else { break }
    }
    if ($rest -match '(^|[\\/])\.\.([\\/]|$)') { return @{ Kind = 'bad'; Why = 'a path that climbs out midway' } }
    if (-not $climbs) { return @{ Kind = 'ok' } }
    if ($rest -match '^(?i)Windows[\\/](.*)$') {
        return @{ Kind = 'fix'; New = $winRoot + '\' + ($Matches[1] -replace '/', '\'); Why = "relative to the exporting Streamer.bot's folder" }
    }
    $leaf = Split-Path -Leaf ($rest -replace '/', '\')
    if ($localNames.Contains($leaf)) {
        return @{ Kind = 'fix'; New = '.\' + $leaf; Why = 'a climbing path to a DLL that sits in the Streamer.bot folder' }
    }
    return @{ Kind = 'bad'; Why = "a path that climbs out of Streamer.bot's folder" }
}

function Get-AuthorPaths([string] $json) {
    $hits = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in [regex]::Matches($json, '"([A-Za-z]:\\\\(?:[^"\\]|\\\\.){0,200}?)"')) {
        $p = $m.Groups[1].Value.Replace('\\', '\')
        if ($p -match '^(?i)[A-Za-z]:\\Windows\\') { continue }
        if ($p -match '(?i)\.dll$') { continue }
        [void] $hits.Add($p)
    }
    return ,$hits
}

# ---------------------------------------------------------------- one export

# Checks one export and repairs what it can. Encoded is the repaired export, or missing when there is nothing to write.
function Repair-Export([string] $base64, [string] $name) {
    $export = ConvertFrom-Export $base64 $name
    $refs = Get-References $export.Json
    $actions = @($refs | ForEach-Object { $_.Action } | Select-Object -Unique).Count
    Write-Host "$name - $($refs.Count) references in $actions actions"
    if ($refs.Count -eq 0) {
        Write-Host '  ok   no C# references in this export; nothing to do' -ForegroundColor Green
        return @{ Ok = $true }
    }

    $localNames = Get-LocalNames $refs
    $fixes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $uses = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
    $why = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $perAction = [ordered]@{}
    $bad = @()
    foreach ($ref in $refs) {
        $verdict = Get-Verdict $ref.Ref $localNames
        if ($verdict.Kind -eq 'fix') {
            $fixes[$ref.Ref] = $verdict.New
            $why[$ref.Ref] = $verdict.Why
            if ($uses.ContainsKey($ref.Ref)) { $uses[$ref.Ref]++ } else { $uses[$ref.Ref] = 1 }
            if ($perAction.Contains($ref.Action)) { $perAction[$ref.Action]++ } else { $perAction[$ref.Action] = 1 }
        } elseif ($verdict.Kind -eq 'bad') {
            $bad += "$($ref.Action): $($ref.Ref) ($($verdict.Why))"
        }
    }

    foreach ($line in $bad) { Write-Host "  FAIL $line" -ForegroundColor Red }
    foreach ($old in $fixes.Keys) {
        Write-Host "  fix  $old" -ForegroundColor Yellow
        Write-Host "    -> $($fixes[$old])   [$($why[$old])]"
    }

    $authorPaths = Get-AuthorPaths $export.Json
    foreach ($p in $authorPaths) { Write-Host "  note: path from the exporting PC, not a reference: $p" -ForegroundColor DarkYellow }

    if ($Check) {
        if ($bad.Count -gt 0 -or $fixes.Count -gt 0) {
            $hit = ($perAction.Values | Measure-Object -Sum).Sum
            if (-not $hit) { $hit = 0 }
            $hit = $hit + $bad.Count
            Write-Host "  FAIL $hit of $($refs.Count) references would not hold on another PC" -ForegroundColor Red
            return @{ Ok = $false }
        }
        Write-Host '  ok   every reference holds wherever Streamer.bot is installed' -ForegroundColor Green
        return @{ Ok = $true }
    }

    if ($bad.Count -gt 0 -and $Strict) { throw 'nothing written (-Strict): the references above cannot be repaired here.' }
    if ($fixes.Count -eq 0) {
        if ($bad.Count -gt 0) {
            Write-Host '  FAIL nothing written: no reference can be repaired here' -ForegroundColor Red
            return @{ Ok = $false }
        }
        Write-Host '  ok   every reference already holds wherever Streamer.bot is installed; nothing written' -ForegroundColor Green
        return @{ Ok = $true }
    }

    $json = $export.Json
    foreach ($old in $fixes.Keys) {
        $inText = Measure-Text $json (ConvertTo-JsonText $old)
        if ($inText -ne $uses[$old]) {
            throw "nothing written: $old stands $inText times in the export, but $($uses[$old]) times in a references list."
        }
    }
    foreach ($old in $fixes.Keys) { $json = $json.Replace((ConvertTo-JsonText $old), (ConvertTo-JsonText $fixes[$old])) }

    $after = Get-References $json
    if ($after.Count -ne $refs.Count) { throw "nothing written: the rewrite changed the number of references ($($refs.Count) -> $($after.Count))." }
    for ($i = 0; $i -lt $refs.Count; $i++) {
        $expected = $refs[$i].Ref
        if ($fixes.ContainsKey($expected)) { $expected = $fixes[$expected] }
        if ($after[$i].Ref -cne $expected) { throw "nothing written: reference $i reads back as $($after[$i].Ref), not $expected." }
        if ($fixes.ContainsKey($refs[$i].Ref) -and (Get-Verdict $after[$i].Ref $localNames).Kind -ne 'ok') {
            throw "nothing written: $($after[$i].Ref) still would not hold."
        }
    }
    $encoded = ConvertTo-Export $json $export.Bom
    $back = ConvertFrom-Export $encoded $name
    if ($back.Json -cne $json -or $back.Bom -ne $export.Bom) { throw 'nothing written: the packed export does not unpack to the rewritten JSON.' }

    return @{
        Ok = ($bad.Count -eq 0)
        Encoded = $encoded
        Total = ($perAction.Values | Measure-Object -Sum).Sum
        Actions = $perAction.Count
        Bad = $bad.Count
        Missing = @($fixes.Values | Select-Object -Unique | Where-Object { $_ -notlike '.\*' -and -not (Test-Path -LiteralPath $_) })
    }
}

function Show-Repaired($result, [string] $where) {
    foreach ($m in $result.Missing) { Write-Host "  note: not on this PC: $m" -ForegroundColor DarkYellow }
    Write-Host "  ok   $($result.Total) references repaired in $($result.Actions) actions; $where" -ForegroundColor Green
    if ($result.Bad -gt 0) { Write-Host "  FAIL $($result.Bad) references above are still broken; they point outside Windows and this PC cannot say where" -ForegroundColor Red }
}

# ---------------------------------------------------------------- one file, or the clipboard

# A .sb file is the export and nothing else; a .txt or .md file holds it somewhere in its text.
function Repair-File([string] $file, [string] $target) {
    $name = Split-Path -Leaf $file
    if (Test-TextFile $file) {
        $source = Read-TextFile $file
        $block = Find-ImportString $source.Text $name
        $result = Repair-Export $block.Base64 $name
        if (-not $result.Encoded) { return $result.Ok }
        $before = $source.Text.Substring(0, $block.Start)
        $after = $source.Text.Substring($block.End)
        $text = $before + (Format-ImportString $result.Encoded $block) + $after
        $again = Find-ImportString $text $name
        if ($again.Base64 -cne $result.Encoded -or $again.Start -ne $block.Start -or $text.Substring($again.End) -cne $after) {
            throw 'nothing written: the rewritten text does not read back as the repaired import string with the text around it unchanged.'
        }
        $bytes = $source.Encoding.GetBytes($text)
    } else {
        $raw = [System.IO.File]::ReadAllText($file)
        $result = Repair-Export $raw $name
        if (-not $result.Encoded) { return $result.Ok }
        $tail = ''
        if ($raw -match '(\r?\n)+$') { $tail = $Matches[0] }
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($result.Encoded + $tail)
    }

    if (-not $NoBackup -and $target -ieq $file) {
        $bak = "$file.bak"
        $n = 2
        while (Test-Path -LiteralPath $bak) { $bak = "$file.$n.bak"; $n++ }
        Copy-Item -LiteralPath $file -Destination $bak
        Write-Host "  kept the original as $(Split-Path -Leaf $bak)"
    }
    [System.IO.File]::WriteAllBytes($target, $bytes)
    if ($ImportString) {
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($target) -replace '(?i)\.import$', ''
        $importFile = Join-Path (Split-Path -Parent $target) "$leaf.import.txt"
        # Repairing x.import.txt already wrote the import string.
        if ($importFile -ine $target) {
            [System.IO.File]::WriteAllText($importFile, $result.Encoded, [System.Text.Encoding]::ASCII)
            Write-Host "  import string on one line in $(Split-Path -Leaf $importFile)"
        }
    }
    Show-Repaired $result "written to $target"
    return $result.Ok
}

function Repair-Clipboard {
    $name = 'Clipboard'
    $text = Get-ClipboardText
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'the clipboard holds no text: copy a Streamer.bot import string first.' }
    $block = Find-ImportString $text $name
    $result = Repair-Export $block.Base64 $name
    if (-not $result.Encoded) { return $result.Ok }
    Set-ClipboardText $result.Encoded
    if ("$(Get-ClipboardText)".Trim() -cne $result.Encoded) { throw 'the clipboard does not read back as the repaired import string; do not paste it.' }
    Show-Repaired $result 'the repaired import string is on the clipboard'
    return $result.Ok
}

function Invoke-One([string] $file) {
    try {
        $full = (Resolve-Path -LiteralPath $file).Path
        $target = $full
        if ($OutDir) {
            if (-not (Test-Path -LiteralPath $OutDir)) { [void] (New-Item -ItemType Directory -Path $OutDir) }
            $target = Join-Path ((Resolve-Path -LiteralPath $OutDir).Path) (Split-Path -Leaf $full)
        }
        return (Repair-File $full $target)
    } catch {
        Write-Host "  FAIL $(Split-Path -Leaf $file): $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ---------------------------------------------------------------- what to work on

# A file still being copied cannot be read yet; it counts once it can.
function Test-HoldsImportString([string] $file) {
    try { return ((Get-ImportBlocks (Read-TextFile $file).Text).Count -gt 0) } catch { return $false }
}

# .sb files, and the .txt and .md files that hold an import string; other text files are none of our business.
function Get-Exports([string] $folder) {
    $gci = @{ LiteralPath = $folder; File = $true }
    if ($Recurse) { $gci['Recurse'] = $true }
    $files = Get-ChildItem @gci | Where-Object { $_.Extension -ieq '.sb' -or ((Test-TextFile $_.Name) -and (Test-HoldsImportString $_.FullName)) }
    return @($files | Sort-Object FullName)
}

$inbox = Join-Path $here 'Inbox'
$ok = $true

if ($Clipboard) {
    if ($Path -or $OutDir -or $Watch) {
        Write-Host '  FAIL -Clipboard works on the clipboard alone; leave out files, -OutDir and -Watch.' -ForegroundColor Red
        exit 1
    }
    try { $ok = Repair-Clipboard } catch { Write-Host "  FAIL $($_.Exception.Message)" -ForegroundColor Red; $ok = $false }
    if ($ok) { exit 0 } else { exit 1 }
}

if ($Watch) {
    if (-not (Test-Path -LiteralPath $inbox)) { [void] (New-Item -ItemType Directory -Path $inbox) }
    $fixed = Join-Path $here 'Fixed'
    $originals = Join-Path $here 'Originals'
    Write-Host "Watching $inbox" -ForegroundColor Cyan
    Write-Host 'Drop Streamer.bot exports (.sb) or import strings (.txt, .md) in there. Repaired files land in Fixed\, the originals in Originals\.'
    Write-Host 'Press Ctrl+C to stop.'
    $sizes = @{}
    while ($true) {
        foreach ($file in (Get-Exports $inbox)) {
            $key = $file.FullName
            # Wait one round for the file to stop growing: a copy in progress is not an export yet.
            if (-not $sizes.ContainsKey($key) -or $sizes[$key] -ne $file.Length) { $sizes[$key] = $file.Length; continue }
            foreach ($dir in @($fixed, $originals)) { if (-not (Test-Path -LiteralPath $dir)) { [void] (New-Item -ItemType Directory -Path $dir) } }
            Write-Host ''
            Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $file.Name) -ForegroundColor Cyan
            $out = Join-Path $fixed $file.Name
            $n = 2
            while (Test-Path -LiteralPath $out) { $out = Join-Path $fixed ("{0}.{1}{2}" -f [System.IO.Path]::GetFileNameWithoutExtension($file.Name), $n, $file.Extension); $n++ }
            $done = $false
            try { $done = (Repair-File $file.FullName $out) } catch { Write-Host "  FAIL $($_.Exception.Message)" -ForegroundColor Red }
            if (Test-Path -LiteralPath $out) {
                $keep = Join-Path $originals $file.Name
                $n = 2
                while (Test-Path -LiteralPath $keep) { $keep = Join-Path $originals ("{0}.{1}{2}" -f [System.IO.Path]::GetFileNameWithoutExtension($file.Name), $n, $file.Extension); $n++ }
                Move-Item -LiteralPath $file.FullName -Destination $keep
                Write-Host "  moved the original to Originals\$(Split-Path -Leaf $keep)"
            } else {
                Write-Host '  the file stays in Inbox' -ForegroundColor DarkYellow
            }
            $sizes.Remove($key)
        }
        Start-Sleep -Seconds 2
    }
}

$targets = @()
if (-not $Path -or $Path.Count -eq 0) {
    if (-not (Test-Path -LiteralPath $inbox)) { [void] (New-Item -ItemType Directory -Path $inbox) }
    $targets = @(Get-Exports $inbox | ForEach-Object { $_.FullName })
    if ($targets.Count -eq 0) {
        Write-Host "Nothing to do: drop Streamer.bot exports (.sb) or import strings (.txt, .md) into $inbox, or drag them onto Fix-Export.cmd." -ForegroundColor Cyan
        exit 0
    }
} else {
    foreach ($p in $Path) {
        if (Test-Path -LiteralPath $p -PathType Container) { $targets += @(Get-Exports $p | ForEach-Object { $_.FullName }) }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) { $targets += (Resolve-Path -LiteralPath $p).Path }
        else { Write-Host "  FAIL $p does not exist." -ForegroundColor Red; $ok = $false }
    }
}

foreach ($file in $targets) {
    if (-not (Invoke-One $file)) { $ok = $false }
}

if ($targets.Count -gt 1) {
    Write-Host ''
    if ($ok) { Write-Host "$($targets.Count) exports done." -ForegroundColor Green }
    else { Write-Host "$($targets.Count) exports done, with problems above." -ForegroundColor Red }
}
if ($ok) { exit 0 } else { exit 1 }
