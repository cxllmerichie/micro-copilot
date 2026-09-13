# Micro Copilot

Micro Copilot is an AI-powered Fill-In-the-Middle (FIM) suggestion engine for the [micro](https://github.com/micro-editor/micro) terminal-based text editor. It provides VS Code-style ghost text autocompletion natively within your terminal.

## Architecture

This project achieves lightning-fast background streaming by splitting responsibilities:
1. **Core Patch (`patches/2.0.15.patch`)**: A lightweight patch to the `micro` core that exposes a new `VirtualText` rendering engine and a non-blocking `shell.HttpStream` API to Lua plugins.
2. **Lua Plugin (`plugin/plugin.lua`)**: A fully customizable Lua plugin that intercepts your typing, implements a logical debounce timer, natively streams Server-Sent Events (SSE) from your local LLM (like `llama.cpp`), and updates the ghost text smoothly without blocking the editor.

## Requirements
- Go (to compile `micro`)
- `make`
- A local LLM FIM endpoint (e.g. `llama.cpp` running at `http://127.0.0.1:65432/infill`)

## Installation

This repository acts as a build system to compile a Copilot-enabled `micro` binary from the v2.0.15 release.

1. **Bootstrap the build:**
   ```bash
   make bootstrap
   ```
   *This clones the upstream repo, checks out the v2.0.15 commit (`6a62575bcfdf4965f187eedafceb3400316e612b`), applies the patch, and builds the binary in `micro/micro`.*

2. **Move the binary:**
   ```bash
   sudo cp micro/micro /usr/local/bin/micro
   ```

3. **Install the Lua Plugin:**
   ```bash
   make install
   ```
   *This copies the plugin to `~/.config/micro/plug/copilot`.*

## Configuration

You can configure Copilot directly inside `micro` using the command bar. Press `Ctrl-E` to open the command bar and type `set copilot.<option> <value>`. These settings are saved automatically.

### Available Settings

| Setting | Default | Description |
|---|---|---|
| `copilot.url` | `http://127.0.0.1:65432/infill` | The URL of your FIM endpoint. |
| `copilot.model` | `deepseek-coder-1.3b-base.Q8_0.gguf` | The model to use. |
| `copilot.trigger_delay_ms` | `250` | The delay in milliseconds after typing before FIM triggers. |
| `copilot.accept_line_shortcut` | `Alt-l` | The keyboard shortcut to accept the suggested ghost text up to the next newline. |
| `copilot.accept_full_shortcut` | `Alt-Shift-l` | The keyboard shortcut to accept the entire ghost text block. |
| `copilot.text_color` | `gray` | The foreground color of the ghost text (requires restarting micro to take effect). |
| `copilot.log_filepath` | `~/.config/micro/plug/copilot/events.log` | Optional. Path to a file where Copilot FIM generations will be logged as pretty JSON for debugging. |

> [!NOTE]
> **Advanced Steering:** To drastically improve suggestion quality, you can use a secondary AI model to guide the FIM completion. See the [micro-copilot-steering](../micro-copilot-steering) repository for instructions and its dedicated configuration options!

## Usage

1. Open `micro`.
2. Start typing.
3. Ghost text will appear ahead of your cursor.
4. Press `Alt-l` (or your configured shortcut) to accept a single line. Press `Alt-Shift-l` to accept the entire block.

## Development & Contributing

If you want to contribute to the core Go patch, we have provided tools to make this workflow seamless.

1. **Setup Development Branch:**
   ```bash
   make dev
   ```
   *This clones the repo, checks out a new branch (`copilot-dev`), applies the patch, and commits it. You can now freely edit the Go code inside the `micro/` directory.*

2. **Update the Patch:**
   Once you've made changes and committed them to your `copilot-dev` branch inside `micro/`, you can regenerate the patch file by running:
   ```bash
   make patch
   ```
   *This automatically updates `patches/2.0.15.patch` using your new commits.*
