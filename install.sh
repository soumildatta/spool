#!/bin/bash
# spool installer. builds the app, puts it on your PATH, and makes sure
# ollama is installed and running so setup stays painless.
set -euo pipefail

MODEL="qwen3.5:9b"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

say()  { printf "🧵 %s\n" "$1"; }
fail() { printf "✋ %s\n" "$1" >&2; exit 1; }

# 1. swift toolchain
command -v swift >/dev/null || fail "Swift not found. Install Xcode Command Line Tools first: xcode-select --install"

# 2. build
say "Building Spool..."
(cd "$REPO_DIR" && swift build -c release >/dev/null)

# 3. install the binary somewhere on PATH, no sudo if we can help it
if [ -w /opt/homebrew/bin ]; then
    BIN_DIR=/opt/homebrew/bin
elif [ -w /usr/local/bin ]; then
    BIN_DIR=/usr/local/bin
else
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) say "Note: add $BIN_DIR to your PATH (e.g. in ~/.zshrc)." ;;
    esac
fi

# restart cleanly if an old copy is running
"$REPO_DIR/.build/release/spool" stop >/dev/null 2>&1 || true
# rm first, copying over the existing file keeps its inode and macOS kills
# binaries whose cached code signature no longer matches on launch
rm -f "$BIN_DIR/spool"
cp "$REPO_DIR/.build/release/spool" "$BIN_DIR/spool"
say "Installed spool -> $BIN_DIR/spool"

# 4. ollama, install if missing
if ! command -v ollama >/dev/null; then
    if command -v brew >/dev/null; then
        say "Ollama not found, installing with Homebrew..."
        brew install ollama
    else
        say "Ollama not found and Homebrew isn't available, downloading the Ollama app..."
        TMP_ZIP="$(mktemp -d)/Ollama-darwin.zip"
        curl -fL --progress-bar https://ollama.com/download/Ollama-darwin.zip -o "$TMP_ZIP"
        ditto -xk "$TMP_ZIP" /Applications
        rm -f "$TMP_ZIP"
    fi
fi

# 5. the model. spool starts and stops ollama on demand, so nothing runs at
#    login and the model gets unloaded from memory after every job. for the
#    pull we briefly start a temporary server and stop it again afterwards.
server_up() { curl -s --max-time 2 http://localhost:11434/api/version >/dev/null; }

TEMP_PID=""
if ! server_up; then
    ollama serve >/dev/null 2>&1 &
    TEMP_PID=$!
    for _ in $(seq 1 20); do server_up && break; sleep 1; done
    server_up || fail "Ollama didn't come up on localhost:11434."
fi

if ollama list 2>/dev/null | grep -q "^${MODEL}"; then
    say "Model $MODEL is already downloaded."
elif [ -t 0 ]; then
    printf "🧵 Download the model now? %s is about 6.6 GB. [Y/n] " "$MODEL"
    read -r answer
    if [ "${answer:-Y}" != "n" ] && [ "${answer:-Y}" != "N" ]; then
        ollama pull "$MODEL"
    else
        say "Skipped. Later, run: ollama pull $MODEL"
    fi
else
    say "To download the model, run: ollama pull $MODEL"
fi

# stop the temporary server, spool will start ollama itself when needed
[ -n "$TEMP_PID" ] && kill "$TEMP_PID" 2>/dev/null || true

# 6. launch
"$BIN_DIR/spool"
say "All set. Click the spool in your menu bar."
