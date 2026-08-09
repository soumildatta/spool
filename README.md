# 🧵 Spool

Turn rough idea dumps into structured documents, from your macOS menu bar.

You think fast. Ideas land in random files as fragments and unfinished sentences. Spool reads a messy draft and rewrites it as a document you can actually follow later: every idea preserved, grouped into themed sections, fleshed out into complete sentences in your own voice, then a few small thoughts of its own tacked on under **🧵 Spool's notes**.

Named for the thing that takes loose, tangled thread and winds it into something you can actually use.

## How it works

- Native Swift, single SPM executable, no Electron, no cloud. Everything runs against a **local** OpenAI-compatible model server (LM Studio, Ollama, mlx, llama.cpp).
- Lives as a little thread spool in the menu bar (`NSStatusItem`, no dock icon). The spool winds — loose strands filling into a full barrel and back — while the model is thinking.
- Default model: **Qwen3.5 9B** served via Ollama (best performance-latency tradeoff tested). Settings lists the models Ollama has installed and can download or delete them in place, so swap in whatever fits your machine.
- **Nothing runs unless you're using it.** Ollama isn't installed as a login item. When you start a job, Spool launches `ollama serve` itself if it isn't already running, and once the job finishes it evicts the model from memory (`keep_alive: 0`) and shuts down any server it started. Your RAM is yours again the moment the document is written. If you run your own Ollama server already, Spool leaves it running and only unloads the model.

## Install

```sh
./install.sh
```

That's the whole thing. The installer builds Spool, puts it on your PATH (no sudo when possible), installs and starts Ollama if you don't have it (via Homebrew, or a direct download if you don't have that either), offers to download the model, and launches the app.

Manual alternative:

```sh
swift build -c release
cp .build/release/spool /opt/homebrew/bin/spool   # or anywhere on PATH
ollama pull qwen3.5:9b
```

## Use

```sh
spool              # start the menu bar app, then close the terminal, it keeps running
spool run <file…>  # structure one or more documents right in the terminal
spool stop         # quit it
spool status       # is it running?
```

Then click the 🧵 in the menu bar. The top of the menu is a live status readout: `idle · point me at a rough draft`, then `waking up the model…`, `thinking about ideas.md…`, `writing · 2.4k chars`, plus a `model:` row showing what's configured.

Three ways to feed it a draft:

- **Structure Documents:**, file picker (`.md`/`.txt`), which takes as many files as you want to select.
- **Structure Newest: `<file>`**, shows up once you set a **Watched Folder** in Settings (your Obsidian vault, a notes directory, whatever). One click structures the most recently edited note in it. Hidden folders like `.obsidian` and Spool's own outputs are skipped.
- **Drag & drop** files, or whole folders, which each contribute their newest draft, straight onto the 🧵 in the menu bar.

### Queueing

Works on one job at a time, so anything you submit joins a queue. **Clear Queue** drops whatever hasn't started yet. Duplicates of a file already waiting are ignored, and a draft that turns out to be empty or unreadable is skipped rather than killing the rest of the run. The model is loaded once for the whole queue and unloaded when the last file is done.

When it finishes, **Open Results** lists everything the run produced (or **Open Last Result** if there was only one). `spool run a.md b.md notes/` works through several drafts the same way.

By default each result is written next to its original as `<name>.structured.md`. In Settings you can instead choose to **rewrite the original file in place**, and every rewrite first saves a copy of the original to `~/Library/Application Support/Spool/backups`, so nothing gets lost.

**Settings** lets you change the model and server URL.

When you're on a local Ollama, the model field is a list of what's installed. **+** downloads any model from [ollama.com/library](https://ollama.com/library) with a progress bar, **−** deletes the selected one from disk.

| Server | URL |
|---|---|
| Ollama (default) | `http://localhost:11434/v1` |
| LM Studio | `http://localhost:1234/v1` |

## Requirements

- macOS 14+ (Apple Silicon recommended, as it is what it was tested on, the model wants ~7 GB of memory free)
- Swift toolchain (Xcode Command Line Tools) to build

## How we use it
Spool is a collaboration between Soumil and Sukhleen, built to bring some structure to our messy, hurried notes, including short notes that we record via TTS (text-to-speech). We generally organize ideas into Obsidian folders, and allow spool to watch the most important folder. 

**Support for watching multiple folders, and queueing multiple tasks coming soon!**
