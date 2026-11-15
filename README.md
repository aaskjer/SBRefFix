<h1 align="center">SBRefFix</h1>

<p align="center">
  <b>Rewrites the C# assembly references in a Streamer.bot export so they resolve on any PC.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/tool-streamer.bot-0b73ff" alt="Streamer.bot">
  <img src="https://img.shields.io/github/license/aaskjer/SBRefFix" alt="License">
  <img src="https://img.shields.io/github/v/release/aaskjer/SBRefFix" alt="Release">
  <img src="https://img.shields.io/github/downloads/aaskjer/SBRefFix/total" alt="Downloads">
  <img src="https://img.shields.io/github/stars/aaskjer/SBRefFix" alt="Stars">
</p>

<p align="center">
  <a href="https://github.com/aaskjer/SBRefFix/releases/latest"><b>Download</b></a> &nbsp;·&nbsp;
  <a href="Setup-Guide.md"><b>Setup Guide</b></a>
</p>

---

## Problem

Streamer.bot 1.0.7 stores the references of C# sub-actions relative to its own folder. Exported from
`C:\Users\you\Desktop\Streamer.bot`, a framework reference reads:

```
..\..\..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll
```

The importing Streamer.bot resolves the `..\` against its own folder. A `..` above the drive root is dropped:

| Importer's folder | Resolves to | |
| --- | --- | --- |
| `C:\Streamer.bot` | `C:\Windows\...\System.dll` | found, by accident |
| `D:\Streamer.bot` | `D:\Windows\...\System.dll` | missing |
| `C:\Users\you\Documents\Tools\Streamer.bot` | `C:\Users\Windows\...\System.dll` | missing |

A missing reference is dropped. **Find Refs** adds absolute `C:\Windows\...` entries but keeps the broken
relative ones, which go on producing errors.

## Rules

SBRefFix judges every string in a `references` list and rewrites only paths that depend on the exporting
PC's folder layout:

| Reference | Result |
| --- | --- |
| `Foo.dll`, `.\Foo.dll`, `lib\Foo.dll` | kept: relative inside the Streamer.bot folder, portable as is |
| `C:\Windows\...` on the local Windows drive | kept |
| `..\..\Windows\...`, `\Windows\...`, `X:\Windows\...` on another drive | `%SystemRoot%\...` |
| `..\...\Foo.dll` or `X:\...\Foo.dll`, where `Foo.dll` is a local DLL | `.\Foo.dll` |
| any other path that is rooted or climbs out of the folder | `FAIL`, unchanged |
| `\\server\...`, a `..` midway, an empty string | `FAIL`, unchanged |

`%SystemRoot%` is taken from the PC running SBRefFix, normally `C:\Windows`. A local DLL is one of
`Streamer.bot.Plugin.Interface.dll`, `Streamer.bot.Common.dll`, `Newtonsoft.Json.dll`, `Twitch.Common.dll`,
any DLL the same export references by bare file name, and with `-SbFolder` every `*.dll` in that folder.

## Processing

1. **Decode.** An export is Base64 over the 4-byte magic `SBAE` (Base64 `U0JBR...`), followed by a gzip
   stream of UTF-8 JSON, optionally with BOM. The gzip trailer's length field must match the unpacked size;
   a truncated string or trailing text fails here.
2. **Collect.** The JSON is parsed; each string in a `references` array is recorded with the name of the
   action it belongs to.
3. **Rewrite.** Each affected reference is replaced as a JSON string literal in the original JSON text. The
   JSON is not re-serialized, so key order, formatting and all other values stay byte-identical.
4. **Encode.** Magic, gzip and BOM as in the input.

Nothing is written if one of these checks fails:

- an affected string occurs in the JSON more often than in `references` lists, e.g. inside C# code
- the rewritten JSON yields a different number of references, or one differs from its expected value
- a rewritten reference does not pass the rules as kept
- the re-encoded export does not decode back to the rewritten JSON
- the written text file or clipboard does not read back as the repaired string

## Not handled

- Rooted paths outside Windows (`D:\Libs\Foo.dll`) to DLLs that are not local: no path on another PC can be
  derived from them. They are reported and left as they are.
- Absolute paths in other fields, such as file paths in sub-actions, are listed as `note:` and not changed.
- A rewritten Windows path missing on the PC running SBRefFix is listed as `note: not on this PC`.

---

## Credits

- **Author:** [aaskjer on Twitch](https://twitch.tv/aaskjer) · [aaskjer.github.io](https://aaskjer.github.io/)
- **Built for:** [Streamer.bot](https://streamer.bot) by [nate1280](https://www.patreon.com/c/nate1280/home)
- **Thanks:** YOU ♡
