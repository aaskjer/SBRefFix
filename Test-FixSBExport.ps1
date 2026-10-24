# Tests for Fix-SBExport.ps1 - builds small exports in TEMP and checks what comes out.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tool = Join-Path $here 'Fix-SBExport.ps1'
$work = Join-Path $env:TEMP ('sbreffix-tests-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void] (New-Item -ItemType Directory -Path $work)
$utf8 = New-Object System.Text.UTF8Encoding $false
$winRoot = $env:SystemRoot.TrimEnd('\')

$pass = 0
$fail = 0
function Assert([bool] $ok, [string] $what) {
    if ($ok) { $script:pass++; Write-Host "  ok   $what" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL $what" -ForegroundColor Red }
}

function New-ExportString([string[]] $refs) {
    $list = ($refs | ForEach-Object { '"' + $_.Replace('\', '\\') + '"' }) -join ','
    $json = '{"actions":[{"id":"a1","name":"Test Action","triggers":[],"subActions":[{"id":"s1","type":12,"references":[' + $list + ']}]}],"version":1}'
    $body = $utf8.GetBytes($json)
    $packed = [System.IO.MemoryStream]::new()
    $packed.Write([byte[]](0x53, 0x42, 0x41, 0x45), 0, 4)
    $gzip = [System.IO.Compression.GZipStream]::new($packed, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $gzip.Write($body, 0, $body.Length)
    $gzip.Dispose()
    return [Convert]::ToBase64String($packed.ToArray())
}

function New-Export([string] $file, [string[]] $refs) {
    [System.IO.File]::WriteAllText($file, (New-ExportString $refs), [System.Text.Encoding]::ASCII)
}

function Get-Refs([string] $file) { return ,(Get-RefsFromString ([System.IO.File]::ReadAllText($file))) }

# The import string in a text, found without the tool's own code: the long Base64 block starting with U0JBR.
function Get-Block([string] $text) { return [regex]::Match($text, 'U0JBR[A-Za-z0-9+/=\r\n]{27,}').Value.TrimEnd() }

function Format-Wrapped([string] $s, [int] $width, [string] $newline) {
    $lines = for ($i = 0; $i -lt $s.Length; $i += $width) { $s.Substring($i, [Math]::Min($width, $s.Length - $i)) }
    return ($lines -join $newline)
}

# Every line but the last exactly $width long, all of them split by $newline and nothing else.
function Test-Wrapped([string] $block, [int] $width, [string] $newline) {
    if (($block.Replace($newline, '')).IndexOfAny([char[]]"`r`n") -ge 0) { return $false }
    $lines = $block -split [regex]::Escape($newline)
    if ($lines.Count -lt 2) { return $false }
    for ($i = 0; $i -lt $lines.Count - 1; $i++) { if ($lines[$i].Length -ne $width) { return $false } }
    return ($lines[-1].Length -ge 1 -and $lines[-1].Length -le $width)
}

function Get-RefsFromString([string] $base64) {
    $bytes = [Convert]::FromBase64String($base64.Trim())
    $ms = [System.IO.MemoryStream]::new($bytes, 4, $bytes.Length - 4)
    $gzip = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $out = [System.IO.MemoryStream]::new()
    $gzip.CopyTo($out)
    $gzip.Dispose()
    $json = $utf8.GetString($out.ToArray())
    $found = @()
    foreach ($m in [regex]::Matches($json, '"references":\[(.*?)\]')) {
        foreach ($s in [regex]::Matches($m.Groups[1].Value, '"((?:[^"\\]|\\.)*)"')) {
            $found += $s.Groups[1].Value.Replace('\\', '\')
        }
    }
    return ,$found
}

function Invoke-Tool([string[]] $toolArgs) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool @toolArgs 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Quote([string] $s) { return "'" + $s.Replace("'", "''") + "'" }

# Runs the tool with -Clipboard from a script where Get-Clipboard and Set-Clipboard are functions on the
# file $clip. A function wins over the cmdlet of the same name, so the real clipboard is never touched.
# Every Set-Clipboard also leaves a line in $clip.log.
function Invoke-ToolOnClipboard([string] $clip, [string[]] $toolArgs) {
    $runner = "$clip.ps1"
    $lines = @(
        "function Get-Clipboard { param([switch] `$Raw) if (Test-Path -LiteralPath $(Quote $clip)) { [System.IO.File]::ReadAllText($(Quote $clip)) } }"
        "function Set-Clipboard { param([string] `$Value) [System.IO.File]::WriteAllText($(Quote $clip), `$Value); Add-Content -LiteralPath $(Quote "$clip.log") 'set' }"
        "& $(Quote $tool) -Clipboard $($toolArgs -join ' ')"
        'exit $LASTEXITCODE'
    )
    [System.IO.File]::WriteAllLines($runner, $lines)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

$sysDll = '..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll'
$sysDllFixed = "$winRoot\Microsoft.NET\Framework64\v4.0.30319\System.dll"

Write-Host "Fix-SBExport tests in $work"
Write-Host ''

# 1. a relative path climbing out into Windows is made absolute, everything else is left alone
Write-Host 'relative Windows reference'
$f = Join-Path $work '1.sb'
New-Export $f @('..\..\..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll', '.\Newtonsoft.Json.dll', 'Twitch.Common.dll')
$r = Invoke-Tool @($f, '-NoBackup')
$refs = Get-Refs $f
Assert ($r.Code -eq 0) 'exit 0'
Assert ($refs[0] -eq "$winRoot\Microsoft.NET\Framework64\v4.0.30319\System.dll") "System.dll -> $winRoot\..."
Assert ($refs[1] -eq '.\Newtonsoft.Json.dll') '.\Newtonsoft.Json.dll untouched'
Assert ($refs[2] -eq 'Twitch.Common.dll') 'bare name untouched'

# 2. Windows on another drive is relocated to this PC's Windows
Write-Host 'Windows on another drive'
$f = Join-Path $work '2.sb'
New-Export $f @('D:\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Core.dll')
$r = Invoke-Tool @($f, '-NoBackup')
$refs = Get-Refs $f
Assert ($r.Code -eq 0) 'exit 0'
Assert ($refs[0] -eq "$winRoot\Microsoft.NET\Framework64\v4.0.30319\System.Core.dll") 'D: -> this PC'

# 3. a rooted path to a DLL that lives in the Streamer.bot folder becomes relative
Write-Host 'rooted path into the exporting Streamer.bot folder'
$f = Join-Path $work '3.sb'
New-Export $f @('C:\Users\Bob\Downloads\Streamer.bot\Newtonsoft.Json.dll', 'C:\Users\Bob\Downloads\Streamer.bot\Twitch.Common.dll')
$r = Invoke-Tool @($f, '-NoBackup')
$refs = Get-Refs $f
Assert ($r.Code -eq 0) 'exit 0'
Assert ($refs[0] -eq '.\Newtonsoft.Json.dll') 'Newtonsoft.Json.dll -> .\'
Assert ($refs[1] -eq '.\Twitch.Common.dll') 'Twitch.Common.dll -> .\'

# 4. a DLL only the exporting PC has: reported, the rest still repaired, exit 1
Write-Host 'a reference nothing can repair'
$f = Join-Path $work '4.sb'
New-Export $f @('E:\Tools\Mine\Custom.dll', '..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll')
$r = Invoke-Tool @($f, '-NoBackup')
$refs = Get-Refs $f
Assert ($r.Code -eq 1) 'exit 1'
Assert ($r.Out -match 'E:\\Tools\\Mine\\Custom.dll') 'the broken reference is named'
Assert ($refs[0] -eq 'E:\Tools\Mine\Custom.dll') 'the broken reference is left as it was'
Assert ($refs[1] -eq "$winRoot\Microsoft.NET\Framework64\v4.0.30319\System.dll") 'the repairable one is repaired'

# 5. -Strict writes nothing when one reference cannot be repaired
Write-Host '-Strict'
$f = Join-Path $work '5.sb'
New-Export $f @('E:\Tools\Mine\Custom.dll', '..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll')
$before = [System.IO.File]::ReadAllText($f)
$r = Invoke-Tool @($f, '-Strict', '-NoBackup')
Assert ($r.Code -eq 1) 'exit 1'
Assert ([System.IO.File]::ReadAllText($f) -ceq $before) 'the file is untouched'

# 6. -Check never writes
Write-Host '-Check'
$f = Join-Path $work '6.sb'
New-Export $f @('..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll')
$before = [System.IO.File]::ReadAllText($f)
$r = Invoke-Tool @($f, '-Check')
Assert ($r.Code -eq 1) 'exit 1 on an export that would break'
Assert ([System.IO.File]::ReadAllText($f) -ceq $before) 'the file is untouched'

# 7. an export that is already portable is left byte for byte as it was
Write-Host 'already portable'
$f = Join-Path $work '7.sb'
New-Export $f @("$winRoot\Microsoft.NET\Framework64\v4.0.30319\System.dll", '.\Newtonsoft.Json.dll')
$before = [System.IO.File]::ReadAllText($f)
$r = Invoke-Tool @($f, '-NoBackup')
Assert ($r.Code -eq 0) 'exit 0'
Assert ([System.IO.File]::ReadAllText($f) -ceq $before) 'nothing written'
$r = Invoke-Tool @($f, '-Check')
Assert ($r.Code -eq 0) '-Check says it holds'

# 8. a backup is kept, and running twice changes nothing more
Write-Host 'backup and second run'
$f = Join-Path $work '8.sb'
New-Export $f @('..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll')
[void] (Invoke-Tool @($f))
Assert (Test-Path -LiteralPath "$f.bak") 'the original is kept as .bak'
$after = [System.IO.File]::ReadAllText($f)
$r = Invoke-Tool @($f, '-NoBackup')
Assert ($r.Code -eq 0) 'second run: exit 0'
Assert ([System.IO.File]::ReadAllText($f) -ceq $after) 'second run writes nothing'

# 9. -OutDir leaves the input alone
Write-Host '-OutDir'
$f = Join-Path $work '9.sb'
$outDir = Join-Path $work 'out'
New-Export $f @('..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll')
$before = [System.IO.File]::ReadAllText($f)
$r = Invoke-Tool @($f, '-OutDir', $outDir)
Assert ($r.Code -eq 0) 'exit 0'
Assert ([System.IO.File]::ReadAllText($f) -ceq $before) 'the input is untouched'
Assert ((Get-Refs (Join-Path $outDir '9.sb'))[0] -eq "$winRoot\Microsoft.NET\Framework64\v4.0.30319\System.dll") 'the copy is repaired'

# 10. a file that is not an export is refused without writing
Write-Host 'not an export'
$f = Join-Path $work '10.sb'
[System.IO.File]::WriteAllText($f, 'this is not an export')
$before = [System.IO.File]::ReadAllText($f)
$r = Invoke-Tool @($f)
Assert ($r.Code -eq 1) 'exit 1'
Assert ([System.IO.File]::ReadAllText($f) -ceq $before) 'the file is untouched'

# 11. a whole folder at once
Write-Host 'a folder'
$folder = Join-Path $work 'many'
[void] (New-Item -ItemType Directory -Path $folder)
New-Export (Join-Path $folder 'a.sb') @('..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll')
New-Export (Join-Path $folder 'b.sb') @('..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.Core.dll')
$r = Invoke-Tool @($folder, '-NoBackup')
Assert ($r.Code -eq 0) 'exit 0'
Assert ((Get-Refs (Join-Path $folder 'a.sb'))[0] -eq "$winRoot\Microsoft.NET\Framework64\v4.0.30319\System.dll") 'a.sb repaired'
Assert ((Get-Refs (Join-Path $folder 'b.sb'))[0] -eq "$winRoot\Microsoft.NET\Framework64\v4.0.30319\System.Core.dll") 'b.sb repaired'

# 12. an import string wrapped at 48 characters in a .txt is repaired in place and wrapped again
Write-Host 'wrapped import string in a .txt, -ImportString'
$f = Join-Path $work '12.txt'
$s = New-ExportString @($sysDll, '.\Newtonsoft.Json.dll')
[System.IO.File]::WriteAllText($f, (Format-Wrapped $s 48 "`r`n") + "`r`n", [System.Text.Encoding]::ASCII)
$r = Invoke-Tool @($f, '-ImportString')
$text = [System.IO.File]::ReadAllText($f)
$block = Get-Block $text
$refs = Get-RefsFromString $block
Assert ($r.Code -eq 0) 'exit 0'
Assert ($refs[0] -eq $sysDllFixed) 'System.dll repaired'
Assert ($refs[1] -eq '.\Newtonsoft.Json.dll') '.\Newtonsoft.Json.dll untouched'
Assert (Test-Wrapped $block 48 "`r`n") 'still wrapped at 48 with CRLF'
Assert ($text -ceq $block + "`r`n") 'nothing else in the file'
Assert (Test-Path -LiteralPath "$f.bak") 'the original is kept as .bak'
$imp = Join-Path $work '12.import.txt'
Assert (Test-Path -LiteralPath $imp) '12.import.txt written'
Assert ([System.IO.File]::ReadAllText($imp) -ceq ($block -replace '\s', '')) '12.import.txt holds the repaired string on one line'

# 13. an Import-String.md: heading, badges, a code block; only the block changes
Write-Host 'Import-String.md with heading, badges and a code block'
$head = "## Test Game import string for streamer.bot - ![GitHub Release](https://img.shields.io/github/v/release/x/Test-Game)`n" +
    "![GitHub Release Date](https://img.shields.io/github/release-date/x/Test-Game)`n`n" +
    "Gr$([char]0xFC)$([char]0xDF)e! The string starts with ``U0JBR``.`n`n" + '```bash' + "`n"
$foot = "`n" + '```' + "`n`n---`n`n[Frequently Asked Questions](https://github.com/x/Test-Game/blob/main/FAQ.md)`n"
$f = Join-Path $work '13.md'
[System.IO.File]::WriteAllText($f, $head + (New-ExportString @($sysDll, 'Twitch.Common.dll')) + $foot, $utf8)
$r = Invoke-Tool @($f)
$text = [System.IO.File]::ReadAllText($f, $utf8)
$block = Get-Block $text
$refs = Get-RefsFromString $block
Assert ($r.Code -eq 0) 'exit 0'
Assert ($refs[0] -eq $sysDllFixed) 'System.dll repaired'
Assert ($refs[1] -eq 'Twitch.Common.dll') 'bare name untouched'
Assert ($text -ceq $head + $block + $foot) 'heading, badges, prose and fence unchanged, umlauts included'
Assert ($block -notmatch '\s') 'a one-line string stays on one line'
Assert (Test-Path -LiteralPath "$f.bak") 'the original is kept as .bak'
Assert (-not (Test-Path -LiteralPath (Join-Path $work '13.import.txt'))) 'no .import.txt without -ImportString'

# 14. a wrapped string in an .md, with -OutDir and -ImportString: the input stays, both outputs land in OutDir
Write-Host 'wrapped Import-String.md, -OutDir, -ImportString'
$f = Join-Path $work '14.md'
$outDir = Join-Path $work 'out14'
$original = $head + (Format-Wrapped (New-ExportString @($sysDll)) 48 "`n") + $foot
[System.IO.File]::WriteAllText($f, $original, $utf8)
$r = Invoke-Tool @($f, '-OutDir', $outDir, '-ImportString')
$text = [System.IO.File]::ReadAllText((Join-Path $outDir '14.md'), $utf8)
$block = Get-Block $text
Assert ($r.Code -eq 0) 'exit 0'
Assert ([System.IO.File]::ReadAllText($f, $utf8) -ceq $original) 'the input is untouched'
Assert ((Get-RefsFromString $block)[0] -eq $sysDllFixed) 'the copy is repaired'
Assert (Test-Wrapped $block 48 "`n") 'the copy is still wrapped at 48'
Assert ($text -ceq $head + $block + $foot) 'the text around the block is unchanged'
Assert ((Get-Refs (Join-Path $outDir '14.import.txt'))[0] -eq $sysDllFixed) '14.import.txt in OutDir is repaired'

# 15. -Check and -Strict leave an .md alone
Write-Host '-Check and -Strict on an .md'
$f = Join-Path $work '15.md'
[System.IO.File]::WriteAllText($f, $head + (New-ExportString @('E:\Tools\Mine\Custom.dll', $sysDll)) + $foot, $utf8)
$before = [System.IO.File]::ReadAllText($f)
$r = Invoke-Tool @($f, '-Check')
Assert ($r.Code -eq 1) '-Check: exit 1'
Assert ($r.Out -match 'E:\\Tools\\Mine\\Custom.dll') '-Check names the broken reference'
$r = Invoke-Tool @($f, '-Strict', '-ImportString')
Assert ($r.Code -eq 1) '-Strict: exit 1'
Assert ([System.IO.File]::ReadAllText($f) -ceq $before) 'the file is untouched'
Assert (-not (Test-Path -LiteralPath "$f.bak")) 'no .bak'
Assert (-not (Test-Path -LiteralPath (Join-Path $work '15.import.txt'))) 'no .import.txt'

# 16. text files without a whole import string are refused without writing
Write-Host 'no import string, or a cut-short one'
$f = Join-Path $work '16.md'
[System.IO.File]::WriteAllText($f, "# Just a readme`n`nThe string starts with U0JBR.`n", $utf8)
$before = [System.IO.File]::ReadAllText($f)
$r = Invoke-Tool @($f)
Assert ($r.Code -eq 1) 'no import string: exit 1'
Assert ([System.IO.File]::ReadAllText($f) -ceq $before) 'no import string: the file is untouched'
$f = Join-Path $work '16.txt'
$s = New-ExportString @($sysDll)
[System.IO.File]::WriteAllText($f, $s.Substring(0, $s.Length - 8), [System.Text.Encoding]::ASCII)
$before = [System.IO.File]::ReadAllText($f)
$r = Invoke-Tool @($f)
Assert ($r.Code -eq 1) 'cut short: exit 1'
Assert ([System.IO.File]::ReadAllText($f) -ceq $before) 'cut short: the file is untouched'

# 17. the clipboard: repaired onto one line, -Check reads only, an empty clipboard is refused
Write-Host 'clipboard'
$clip = Join-Path $work '17.clip'
[System.IO.File]::WriteAllText($clip, (Format-Wrapped (New-ExportString @($sysDll, '.\Newtonsoft.Json.dll')) 48 "`r`n") + "`r`n")
$before = [System.IO.File]::ReadAllText($clip)
$r = Invoke-ToolOnClipboard $clip @('-Check')
Assert ($r.Code -eq 1) '-Check: exit 1'
Assert ([System.IO.File]::ReadAllText($clip) -ceq $before -and -not (Test-Path -LiteralPath "$clip.log")) '-Check: the clipboard is left alone'
$r = Invoke-ToolOnClipboard $clip @()
$after = [System.IO.File]::ReadAllText($clip)
$refs = Get-RefsFromString $after
Assert ($r.Code -eq 0) 'exit 0'
Assert ($refs[0] -eq $sysDllFixed -and $refs[1] -eq '.\Newtonsoft.Json.dll') 'the clipboard holds the repaired export'
Assert ($after -match '^U0JBR[A-Za-z0-9+/]+=*$') 'on one line, nothing else'
Assert ($r.Out -match 'on the clipboard') 'says so'
Assert (-not (Get-ChildItem -LiteralPath $work -Filter '17.clip*.bak')) 'no backup'
Remove-Item -LiteralPath $clip, "$clip.log"
$r = Invoke-ToolOnClipboard $clip @()
Assert ($r.Code -eq 1) 'an empty clipboard: exit 1'
Assert (-not (Test-Path -LiteralPath "$clip.log")) 'an empty clipboard is left alone'

# 18. an import string that needs no repair: nothing changes, in a file or on the clipboard
Write-Host 'import string that already holds'
$s = New-ExportString @($sysDllFixed, '.\Newtonsoft.Json.dll')
$f = Join-Path $work '18.md'
[System.IO.File]::WriteAllText($f, $head + (Format-Wrapped $s 48 "`n") + $foot, $utf8)
$before = [System.IO.File]::ReadAllText($f)
$r = Invoke-Tool @($f, '-ImportString')
Assert ($r.Code -eq 0) 'file: exit 0'
Assert ([System.IO.File]::ReadAllText($f) -ceq $before) 'file: nothing written'
Assert (-not (Test-Path -LiteralPath "$f.bak")) 'file: no .bak'
Assert (-not (Test-Path -LiteralPath (Join-Path $work '18.import.txt'))) 'file: no .import.txt'
$clip = Join-Path $work '18.clip'
[System.IO.File]::WriteAllText($clip, $s)
$r = Invoke-ToolOnClipboard $clip @()
Assert ($r.Code -eq 0) 'clipboard: exit 0'
Assert ([System.IO.File]::ReadAllText($clip) -ceq $s -and -not (Test-Path -LiteralPath "$clip.log")) 'clipboard: left alone'

# 19. a folder takes .md files that hold an import string and skips the others
Write-Host 'a folder with text files'
$folder = Join-Path $work 'text'
[void] (New-Item -ItemType Directory -Path $folder)
[System.IO.File]::WriteAllText((Join-Path $folder 'Import-String.md'), $head + (New-ExportString @($sysDll)) + $foot, $utf8)
[System.IO.File]::WriteAllText((Join-Path $folder 'README.md'), "# Readme`n`nNothing to see.`n", $utf8)
$r = Invoke-Tool @($folder, '-NoBackup')
Assert ($r.Code -eq 0) 'exit 0'
Assert ((Get-RefsFromString (Get-Block ([System.IO.File]::ReadAllText((Join-Path $folder 'Import-String.md')))))[0] -eq $sysDllFixed) 'Import-String.md repaired'
Assert ($r.Out -notmatch 'README') 'README.md skipped'

# 20. -ImportString on a .sb writes the same string as a .txt
Write-Host '-ImportString on a .sb'
$f = Join-Path $work '20.sb'
New-Export $f @($sysDll)
$r = Invoke-Tool @($f, '-NoBackup', '-ImportString')
Assert ($r.Code -eq 0) 'exit 0'
Assert ([System.IO.File]::ReadAllText((Join-Path $work '20.import.txt')) -ceq ([System.IO.File]::ReadAllText($f)).Trim()) '20.import.txt holds what 20.sb holds'
Assert ((Get-Refs $f)[0] -eq $sysDllFixed) '20.sb repaired'

Write-Host ''
Write-Host "$pass passed, $fail failed"
Remove-Item -LiteralPath $work -Recurse -Force
if ($fail -gt 0) { exit 1 }
exit 0
