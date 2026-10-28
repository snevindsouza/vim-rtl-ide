# vim-rtl-ide — a plugin-free, server-friendly Vim IDE for Verilog / SystemVerilog / VHDL

Stock Vim, Vimscript only, installs into `$HOME` without root, works over
SSH/PuTTY, degrades gracefully when optional tools are absent.
Full reference inside Vim: `:help rtl-ide` (keys: `:help rtl-ide-keys`).

## 1. Architecture

| Layer | What it is | Needs |
|---|---|---|
| Core editor | options, mappings, netrw explorer, matchit `%`, persistent undo, paste toggle, OSC52 yank, statusline | Vim 7.4 with `+eval` |
| Language support | Vim's own `syntax/`, `indent/`, `ftplugin/` for verilog, systemverilog, vhdl (not duplicated, only extended in `after/ftplugin`) | stock Vim |
| Completion (`autoload/rtl/complete.vim`, `symbols.vim`) | omni completion from: instantiation port/param context, buffer declarations, other buffers, tags, keyword dictionaries, `include` file names; optional `[LSP]` source | Vim `+insert_expand` |
| Tags (`tags.vim`) | `:RtlTags` → `ctags -L filelist` (Universal/Exuberant) or a pure-Vimscript indexer writing a standard `tags` file | ctags optional |
| Navigation (`nav.vim`) | definition (LSP → tags → buffer), references (LSP → whole-word vimgrep), instantiation search, project grep/find | — |
| Lint (`lint.vim`) | verilator / iverilog / verible-verilog-lint / ghdl → quickfix + signs + statusline counts; async with `+job` | one tool, optional |
| LSP client (`lsp.vim`) | real JSON-RPC client: Content-Length framing over a raw channel, request ids, initialize/shutdown/exit, didOpen/didChange(full, debounced)/didSave/didClose, publishDiagnostics, hover, definition, references, documentSymbol, rename (WorkspaceEdit), formatting (explicit only), completion when advertised | Vim 8.0 `+job +channel`; a server (verible-verilog-ls, vhdl_ls, …) |
| Templates (`templates.vim`) | `.tmpl` files with `{{placeholders}}`, module skeleton, `:RtlInstantiate` from a parsed module header | — |
| Project (`project.vim`) | root markers, parsed (never sourced) `.rtlproject`, bounded source enumeration with directory pruning, `.f` filelists | `find` (pure-Vim `glob` fallback) |

**Minimum Vim:** 7.4 for the core (7.4.775 recommended for `noinsert`); **8.0 with `+job +channel`** for the LSP client and asynchronous lint; 8.2 for hover popups (otherwise hover is echoed). Everything feature-detects with `has()`/`exists()`; nothing errors on a smaller build.

**Without optional tools:** no lint → `:RtlLint` prints which tools it looked for; no ctags → built-in indexer; no server → `K`, `<Space>gn`, `<Space>lf` say so and `<Space>gd`/`<Space>gr` fall back to tags / text search. The editor always starts.

**Honesty notes:** the completion, tags fallback, `:RtlInstantiate` and the Enter-after-`begin` balance check are declaration-pattern matching, not elaboration. Only the external tools and the language server are semantic. Nothing here replaces simulation or synthesis lint.

## 2. File tree

```
vim-rtl-ide/
├── install.sh                      installer (dry-run, backup, restore, uninstall)
├── vimrc                           → ~/.vimrc
├── vim/                            → ~/.vim/
│   ├── autoload/rtl/
│   │   ├── project.vim             root, .rtlproject, file list, :RtlFind
│   │   ├── symbols.vim             declaration scanner, module header parser, inst context
│   │   ├── complete.vim            omnifunc + smart Tab
│   │   ├── tags.vim                :RtlTags (ctags or built-in indexer, VHDL scanner)
│   │   ├── nav.vim                 definition/references/instances/grep
│   │   ├── lint.vim                verilator/iverilog/verible/ghdl → quickfix, signs
│   │   ├── lsp.vim                 LSP client
│   │   ├── edit.vim                Enter handler, comments, indent toggle, OSC52
│   │   ├── templates.vim           templates, :RtlModule, :RtlInstantiate
│   │   ├── ft.vim                  shared buffer-local setup for the RTL filetypes
│   │   ├── status.vim              statusline segment
│   │   └── doctor.vim              :RtlDoctor
│   ├── after/ftplugin/{verilog,systemverilog,vhdl,rtlfilelist}.vim
│   ├── ftdetect/rtl.vim            *.vh *.vs *.svi … and .f filelists
│   ├── dict/{verilog,systemverilog,vhdl}.dict
│   ├── templates/verilog/*.tmpl    module always_ff always_ff_sync always_comb case generate function task fsm tb header
│   ├── templates/vhdl/*.tmpl       entity process_sync process_comb case header
│   └── doc/rtl-ide.txt             :help rtl-ide
└── tests/
    ├── run_tests.sh                repeatable verification (temp HOME with a space)
    ├── rtl_test.vim                headless Vim test suite T01–T12
    └── rtl/                        fixtures: counter.v top.v defs.vh bad.v pkg.sv simple.vhd filelist.f .rtlproject
```

## 3. Install (Linux over SSH, no root)

```sh
scp -r vim-rtl-ide user@server:~/          # or unpack the zip there
cd ~/vim-rtl-ide
sh install.sh --dry-run                     # shows every file it would write
sh install.sh                               # backs up, installs, prints a rollback command
vim some_file.v
:RtlDoctor                                  # what this machine can do
:RtlTags                                    # index the project once
```

Rollback: `sh install.sh --restore ~/.vim-rtl-ide-backup-<stamp>`; removal: `sh install.sh --uninstall` (removes only files in `~/.vim/rtl-ide.manifest`). Personal overrides go in `~/.vimrc.local`, which the installer never touches.

Windows: not a target. The same tree works in Vim on Windows for everything except `find`-based enumeration (it uses the pure-Vim `glob` fallback) and OSC52; `install.sh` needs a POSIX shell (Git Bash / WSL).

## 4. Optional tools

| Tool | Executable | Provides | Check | Configure | Lost if missing |
|---|---|---|---|---|---|
| Universal Ctags (or Exuberant) | `ctags` (`universal-ctags`, `ctags-universal` also probed) | accurate tags for Verilog/SV/VHDL | `ctags --version` | `g:rtl_ctags_cmd` | built-in indexer used instead (fewer kinds, slower on huge trees) |
| Verilator | `verilator` | lint with elaboration: undeclared ids, widths, port mismatches, unused/undriven | `verilator --version` | `g:rtl_verilator_exe`, `g:rtl_verilator_args`, `.rtlproject: verilator_args/top/defines/include_dirs` | no verilator diagnostics |
| Icarus Verilog | `iverilog` | parse + elaborate (`-t null`) | `iverilog -V` | `g:rtl_iverilog_exe`, `g:rtl_iverilog_args` | — |
| Verible | `verible-verilog-lint`, `verible-verilog-ls` (also ships `verible-verilog-format`, `-syntax`) | syntax/style lint; language server (hover, definition, references, symbols, rename, formatting, diagnostics — see `:RtlLspStatus` for what your version advertises; no completion) | `verible-verilog-lint --version` | `g:rtl_verible_lint_exe`, `g:rtl_lsp_command` | no Verible lint; LSP features fall back to tags/text |
| GHDL | `ghdl` | VHDL syntax check (`-s`) | `ghdl --version` | `g:rtl_ghdl_exe`, `g:rtl_ghdl_args` | no VHDL diagnostics |
| rust_hdl / ghdl-ls | `vhdl_ls`, `ghdl-ls` | VHDL language server | `vhdl_ls --version` | `g:rtl_lsp_command_vhdl` | VHDL stays tags/text based |

All are optional. Without root, put static binaries (Verible and Verilator publish release tarballs; ctags/iverilog/ghdl can be built with `--prefix=$HOME/.local`) in `~/.local/bin` and add it to `PATH`, or point the `g:rtl_*_exe` variables at the full path in `~/.vimrc.local`. No installation commands are run by this project; I did not verify installation procedures for your distribution.

Verified flags used: `verilator --lint-only -Wall -Wno-fatal +incdir+ +define+ --top-module -f`; `iverilog -t null -g2012 -I -D -s -f`; `verible-verilog-lint <files>`; `ghdl -s --std=08`; `ctags -f -L --sort=yes --languages= --kinds-<LANG>=* --extras=+q --fields=+nK --langmap=`. The language server is launched with no flags by default; add any via `g:rtl_lsp_command` (run `verible-verilog-ls --help` to see them).

## 5. Usage essentials

Leader is `<Space>`. All commands: `:Rtl<Tab>`. Full tables: `:help rtl-ide-keys`.

| Task | How |
|---|---|
| Complete | insert mode `<C-Space>` / `<Tab>` after a word or `.`; `<C-n>`/`<C-p>` plain keyword completion; `<CR>` accepts |
| Navigate suggestions | `<C-n>`/`<C-p>` or `<Tab>`/`<S-Tab>` while the menu is open |
| Definition / references | `<Space>gd` / `<Space>gr`; `<C-]>`/`<C-t>` plain tags; `<Space>gi` instantiation sites |
| Hover / outline / rename / format | `K` / `<Space>gs` / `<Space>gn` / `<Space>lf` (LSP; messages say when the server lacks it) |
| Lint | `<Space>ll` file, `<Space>lp` project (`:RtlLint iverilog` to pick a tool); results `]q [q <Space>co`; `<Space>ld` show, `<Space>lx` clear |
| Tags | `<Space>tg` / `:RtlTags` |
| Search project | `<Space>fg pattern`, `<Space>fw` word under cursor, `<Space>ff name` open file, `<Space>fe` tree |
| Templates | `<Space>it` menu, `<Space>im` module, `<Space>ii` instantiate module under cursor, `<Space>ia/ic/is` |
| Paste from local machine | `<Space>p` (auto-off on leaving insert) or `<Space>oi` to disable auto-indent |
| Buffers / windows | `]b [b <Space>fb <Space>bd <Space>ba`, `<Space>wv ws wh wj wk wl wo wc w=` |
| Diagnose | `:RtlDoctor`, `:RtlLspStatus`, `:RtlLspLog` |

Project config: optional `<root>/.rtlproject` (see `:help rtl-ide-project`); fixture example in `tests/rtl/.rtlproject`.

## 6. Verification

`sh tests/run_tests.sh` creates a temporary HOME **whose path contains a space**, installs there with a pre-existing `.vimrc`, checks the backup/manifest/idempotence/dry-run (T13), then runs `tests/rtl_test.vim` headlessly (`vim -es`) for T01–T12: startup, syntax of every module, missing-tool handling, completion (symbols, keywords, port/param context), navigation (root, tags, definition jump, instances, include path), diagnostics on `bad.v` (SKIP when no tool is installed), nested begin/end indentation, comment toggling, the Enter handler (function-level, plus a best-effort end-to-end `feedkeys` run), paths with spaces, repeated sourcing, and plugin-freeness.

**Status: the suite has not been executed yet.** The environment in which this package was generated has no Vim binary and no network, so I could not run it; `sh -n` syntax-checked the shell scripts and a structural pass checked block balance of the Vimscript, nothing more. Run `sh tests/run_tests.sh` on the target server first; if a test fails, the printed detail string shows the observed values. Interactive checks that cannot be automated are listed at the end of the runner's output (instantiation insertion, the completion menu, paste mode, LSP with a real server, undo of the Enter handler).

## 7. Changelog against the original `.vimrc`

- **Removed `set cindent`/`cinoptions`/`smartindent`**: they fought Vim's `indent/verilog.vim`; `filetype plugin indent on` now provides Verilog/SV/VHDL indentation (module bodies indented one level).
- **Fixed filetype handling**: `*.sv` was forced to `syntax=verilog`, hiding SystemVerilog highlighting; removed. Extra extensions (`*.vh *.vs …`) go through `ftdetect` with `setfiletype`.
- **`<Leader>q` was `:q!`** (silent data loss): now `:q`; `<Leader>Q` keeps the old behaviour.
- **Enter handler rewritten**: old version used `<C-o>:call…\n`, inserted `end` even when a matching `end` existed, inside comments, and mid-line. New handler checks popup, comment/string syntax, trailing text and begin/end balance, and stays in one insert session so `u` undoes it. Not applied to VHDL (its `end` needs a name).
- **Comment toggle**: old uncomment stripped all leading whitespace and commented at column 0; new one keeps/uses the common indentation, uses `--` for VHDL, works on counts and ranges.
- **`autocmd`s** moved into `augroup RtlIde` with `autocmd!`; filetype mappings are buffer-local and defined once per buffer via `after/ftplugin`.
- **`set clipboard=unnamedplus` / `termguicolors`** now guarded by `has()`/`$COLORTERM` (PuTTY/256-colour safe); `fileformat=unix` → `fileformats=unix,dos`; persistent undo only if `~/.vim/undo` is writable; `<Leader>z` got the `e` flag.
- Kept: numbers, cursorline, 2-space indent, search options, `autoread/autowrite`, statusline/wildmenu, Space leader, `<Leader>s n p z /`, visual `<Tab>`, `<C-a>` select-all (note: shadows increment), paste toggle (now also auto-off on `InsertLeave`).

## 8. Known limitations

- Port/parameter parsing handles ANSI and classic headers, parameters with defaults, multi-dimensional ranges and interface ports; macros that expand to port lists and `generate`-dependent ports are not expanded.
- Linting a single file of a multi-file design reports unknown sub-modules; use `:RtlLintProject` with a filelist or `src_dirs`.
- LSP positions are character-based (correct for ASCII/BMP text); incremental sync, snippets, code actions, workspace symbols and signature help are not implemented.
- `<Space>gr` without a server is a word search; `<Space>gi` is a pattern search.
- Verible's server does not offer completion; the `[LSP]` source only appears with a server that advertises `completionProvider`.
