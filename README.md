# SBRefFix

Makes the .NET references in a Streamer.bot export work on everyone else's PC.

Drop a `.sb` file on `Fix-Export.cmd` and the reference paths inside it are rewritten so the import
compiles wherever Streamer.bot happens to be installed. Nothing to install: a folder, Windows PowerShell
5.1, done.

## Why it's needed

You export an action, it imports fine for you and for half the people who try it. The other half get an
action that compiles into nothing - and often they do not even get an error on screen, only a line in the
Streamer.bot log.

The reason is how Streamer.bot 1.0.7 stores and resolves the reference list of a C# sub-action:

- A rooted path such as `C:\Windows\...` is used exactly as written.
- A relative path is combined with the Streamer.bot folder **of the PC doing the import**.
- A reference it cannot find is dropped silently. There is no lookup by file name and no GAC search, only
  an `ERR Unable to locate reference: <path>` line in the log.
- `mscorlib` is added back **only when no reference survived at all**. Then four entries from its own
  folder are always appended: `Streamer.bot.Plugin.Interface.dll`, `Streamer.bot.Common.dll`,
  `Newtonsoft.Json.dll`, `Twitch.Common.dll`. No `System.dll`, no `System.Core.dll`.

The trouble is that an export stores framework references **relative to the exporting Streamer.bot
folder**:

```
..\..\..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll
```

Those `..\` are counted from the importer's folder, so the path only means the same thing when their
Streamer.bot sits exactly as deep on the same drive as yours. A `..` past the drive root is ignored, so a
shallower folder still works by accident; deeper or on another drive it turns into nonsense. A Streamer.bot
in `E:\STREAMING\Streamerbot` reads the line above as `E:\STREAMING\Windows\...`, finds nothing, and drops
the reference.

Streamer.bot's own **Find Refs** button appends absolute `C:\Windows\...` entries but leaves the broken
relative ones in place, so the error lines keep coming even after the action compiles again.

## What it does

It opens the export, rewrites the reference strings that would not survive the trip, and writes it back:

| in the export | becomes | why |
| --- | --- | --- |
| `..\..\Windows\...` | `%SystemRoot%\...` of this PC | a rooted path is used as written |
| `D:\Windows\...` while this PC has Windows elsewhere | `%SystemRoot%\...` of this PC | absolute is not the same as correct |
| `C:\Users\Bob\Streamer.bot\Newtonsoft.Json.dll` | `.\Newtonsoft.Json.dll` | it resolves in every install's own folder |
| `.\Newtonsoft.Json.dll`, `Twitch.Common.dll` | left alone | already portable |
| `E:\Tools\Mine\Custom.dll` | left alone, reported | only your PC can say where that is |

So not everything becomes absolute. A reference inside the Streamer.bot folder is portable precisely
because it is relative, and making it absolute would break it for everybody else.

## How to use it

Double-click or drag files onto:

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

```
powershell -ExecutionPolicy Bypass -File Test-FixSBExport.ps1
```

31 assertions over synthetic exports: every kind of path, `-Check`, `-Strict`, `-OutDir`, backups, running
twice, a file that is not an export, and a whole folder at once.

## The file format

A `.sb` export is Base64 of the four bytes `SBAE` followed by gzipped JSON. There is no checksum, so the
JSON can be rewritten and packed up again.

## Where this comes from

The behaviour above was read out of `Streamer.bot.exe` 1.0.7 and confirmed by real imports: an export that
failed to compile in a Streamer.bot five folders deep imported and compiled cleanly in the same place after
the rewrite. The tool grew out of [TwitchSentry](https://github.com/aaskjer/TwitchSentry), which ships its
releases through it.
