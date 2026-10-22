# SBRefFix

Makes the .NET references in a Streamer.bot export work on everyone else's PC.

Drop a `.sb` file on `Fix-Export.cmd` and the reference paths inside it are rewritten so the import
compiles wherever Streamer.bot happens to be installed. Nothing to install: a folder, Windows PowerShell
5.1, done.

## Why it's needed

The trouble is that an export stores framework references **relative to the exporting Streamer.bot
folder**:

```
..\..\..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll
```

Those `..\` are counted from the importer's folder, so the path only means the same thing when their
Streamer.bot sits exactly as deep on the same drive as yours. A `..` past the drive root is ignored, so a
shallower folder still works by accident; deeper or on another drive it turns into nonsense. A Streamer.bot
in `E:\Streaming\Streamer.bot` reads the line above as `E:\Streaming\Windows\...`, finds nothing, and drops
the reference.

Streamer.bot's own **Find Refs** button appends absolute `C:\Windows\...` entries but leaves the broken
relative ones in place, so the error lines keep coming even after the action compiles again.

SBRefFix rewrites the reference strings that would not survive the trip, and writes it back. So not everything becomes absolute. A reference inside the Streamer.bot folder is portable precisely
because it is relative, and making it absolute would break it for everybody else.

## How to use it

Download the whole project as .ZIP, extract it somewhere, double-click or drag files onto:

| | |
| --- | --- |
| `Fix-Export.cmd` | drag `.sb` files onto it, or double-click to do everything lying in `Inbox\` |
| `Check-Export.cmd` | the same, but reports only and writes nothing |
| `Watch-Inbox.cmd` | keeps watching `Inbox\`: repaired files land in `Fixed\`, the originals in `Originals\` |

Or from a shell:

```
powershell -ExecutionPolicy Bypass -File Fix-SBExport.ps1 <file.sb> [<file2.sb> ...]
powershell -ExecutionPolicy Bypass -File Fix-SBExport.ps1 <folder> -Recurse
```

| switch | |
| --- | --- |
| `-Check` | report only, write nothing |
| `-OutDir <dir>` | write the result there instead of over the input |
| `-NoBackup` | do not keep a `.bak` next to an overwritten file |
| `-Strict` | write nothing unless every reference can be repaired |
| `-SbFolder <dir>` | a Streamer.bot folder, so rooted paths into it can be made relative |
| `-Recurse` | with a folder: its subfolders too |
| `-Watch` | keep watching `Inbox\` |

Exit code 0 means every reference now holds wherever Streamer.bot is installed. Exit code 1 means something
is still broken, and the lines starting with `FAIL` say what. By default the repairable references are
fixed even when one of them cannot be; `-Strict` turns that into all or nothing.

Run it on the export you are about to publish, not on the one you just imported.

## Checking a change

After changing `Fix-SBExport.ps1`, run the tests:

```
powershell -ExecutionPolicy Bypass -File Test-FixSBExport.ps1
```
