# SBRefFix: Setup Guide

Download **[`SBRefFix.zip`](https://github.com/aaskjer/SBRefFix/releases/latest/download/SBRefFix.zip)** from the [latest release](https://github.com/aaskjer/SBRefFix/releases/latest), extract it somewhere, double-click or drag files onto:

| | |
| --- | --- |
| `Fix-Clipboard.cmd` | copy an import string, double-click, paste the repaired one into Streamer.bot |
| `Fix-Export.cmd` | drag `.sb`, `.txt` or `.md` files onto it, or double-click to do everything lying in `Inbox\` |
| `Check-Export.cmd` | the same, but reports only and writes nothing |
| `Watch-Inbox.cmd` | keeps watching `Inbox\`: repaired files land in `Fixed\`, the originals in `Originals\` |

It takes an export in any of these forms:

- a `.sb` file, as Streamer.bot exports it
- a `.txt` or `.md` file holding an import string, such as an `Import-String.md` with a heading, badges and
  the string in a code block. The string is the block of text starting with `U0JBR`, on one line or wrapped
  over many. Only that block is replaced: the text around it stays as it was, and a wrapped string is
  wrapped again at the same width.
- the clipboard, with `Fix-Clipboard.cmd` or `-Clipboard`. The repaired string goes back onto the clipboard
  on one line; when nothing needs repairing, the clipboard is left alone.

Or from a shell:

```
powershell -ExecutionPolicy Bypass -File Fix-SBExport.ps1 <file.sb> [<Import-String.md> ...]
powershell -ExecutionPolicy Bypass -File Fix-SBExport.ps1 <folder> -Recurse
powershell -ExecutionPolicy Bypass -File Fix-SBExport.ps1 -Clipboard
```

| switch | |
| --- | --- |
| `-Check` | report only, write nothing |
| `-OutDir <dir>` | write the result there instead of over the input |
| `-NoBackup` | do not keep a `.bak` next to an overwritten file |
| `-Strict` | write nothing unless every reference can be repaired |
| `-ImportString` | also write the repaired export as an import string on one line, `<name>.import.txt`, next to the repaired file |
| `-Clipboard` | repair the import string on the clipboard instead of files |
| `-SbFolder <dir>` | a Streamer.bot folder, so rooted paths into it can be made relative |
| `-Recurse` | with a folder: its subfolders too |
| `-Watch` | keep watching `Inbox\` |

A folder, `Inbox\` and `-Watch` take every `.sb` file, and every `.txt` or `.md` file that holds an import
string; other text files are skipped.

Exit code 0 means every reference now holds wherever Streamer.bot is installed. Exit code 1 means something
is still broken, and the lines starting with `FAIL` say what. By default the repairable references are
fixed even when one of them cannot be; `-Strict` turns that into all or nothing.

Run it on the export you are about to publish, not on the one you just imported.

## Checking a change

After changing `Fix-SBExport.ps1`, run the tests:

```
powershell -ExecutionPolicy Bypass -File Test-FixSBExport.ps1
```
