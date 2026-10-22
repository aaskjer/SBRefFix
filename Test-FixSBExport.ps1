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

function New-Export([string] $file, [string[]] $refs) {
    $list = ($refs | ForEach-Object { '"' + $_.Replace('\', '\\') + '"' }) -join ','
    $json = '{"actions":[{"id":"a1","name":"Test Action","triggers":[],"subActions":[{"id":"s1","type":12,"references":[' + $list + ']}]}],"version":1}'
    $body = $utf8.GetBytes($json)
    $packed = [System.IO.MemoryStream]::new()
    $packed.Write([byte[]](0x53, 0x42, 0x41, 0x45), 0, 4)
    $gzip = [System.IO.Compression.GZipStream]::new($packed, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $gzip.Write($body, 0, $body.Length)
    $gzip.Dispose()
    [System.IO.File]::WriteAllText($file, [Convert]::ToBase64String($packed.ToArray()), [System.Text.Encoding]::ASCII)
}

function Get-Refs([string] $file) {
    $bytes = [Convert]::FromBase64String(([System.IO.File]::ReadAllText($file)).Trim())
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

Write-Host ''
Write-Host "$pass passed, $fail failed"
Remove-Item -LiteralPath $work -Recurse -Force
if ($fail -gt 0) { exit 1 }
exit 0
