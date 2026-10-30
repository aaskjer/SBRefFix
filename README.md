<h1 align="center">SBRefFix</h1>

<p align="center">
  <b>Makes the .NET references in a Streamer.bot export work on everyone else's PC.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/tool-streamer.bot-0b73ff" alt="Streamer.bot">
  <img src="https://img.shields.io/github/license/aaskjer/SBRefFix" alt="License">
  <img src="https://img.shields.io/github/v/release/aaskjer/SBRefFix" alt="Release">
  <img src="https://img.shields.io/github/downloads/aaskjer/SBRefFix/total" alt="Downloads">
</p>

<p align="center">
  <a href="https://github.com/aaskjer/SBRefFix/releases/latest"><b>Download</b></a> &nbsp;·&nbsp;
  <a href="Setup-Guide.md"><b>Setup Guide</b></a>
</p>

---

## 📖 Overview

A Streamer.bot 1.0.7 export stores framework references relative to the exporting Streamer.bot folder:

```
..\..\..\..\Windows\Microsoft.NET\Framework64\v4.0.30319\System.dll
```

The importer counts those `..\` from their own folder. A Streamer.bot in `E:\Streaming\Streamer.bot` reads
the line above as `E:\Streaming\Windows\...`, finds nothing and drops the reference. Streamer.bot's
**Find Refs** button adds absolute `C:\Windows\...` entries but leaves the broken relative ones in place,
so the errors keep coming. SBRefFix rewrites the references that would not survive the trip.

## ✨ Highlights

- 🎯 **Only what would break.** References inside the Streamer.bot folder stay relative, because that is what
  makes them portable. Making them absolute would break them for everybody else.
- 📦 **Every export format.** `.sb` files, `.txt` or `.md` files that hold an import string, and the clipboard.
- 📄 **The text around it stays.** In an `Import-String.md` only the string block is replaced. A wrapped string
  is wrapped again at the same width.
- 🖱️ **Four batch files.** Repair the clipboard, repair dropped files, check without writing, or watch an
  `Inbox\` folder.
- ✅ **Made for publishing.** A report-only mode, an all-or-nothing mode, and an exit code that says whether
  every reference now holds wherever Streamer.bot is installed.

---

## Credits

- **Author:** [aaskjer on Twitch](https://twitch.tv/aaskjer) · [aaskjer.github.io](https://aaskjer.github.io/)
- **Built for:** [Streamer.bot](https://streamer.bot) by [nate1280](https://www.patreon.com/c/nate1280/home)
- **Thanks:** YOU ♡
