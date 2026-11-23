# hwBro sources

Harbour sources of **hwBro**, a native (x64, no emulator) reconstruction of the DOS xBase application
**BroPlus 3.00**, merged with a two-panel file manager in the style of Norton Commander / Total Commander.

See the `README.md` at the root of the repository for the feature tour and the screenshots.

## Build

From the repository root, in a `cmd` window:

```
build.bat
```

The script sets up the toolchain itself (Harbour 3.2 in `C:\harbour` + MSVC 2019 x64, `HB_COMPILER=msvc64`,
`vcvarsall.bat x86_amd64`) and runs `hbmk2 src\hwbro.hbp`. The `-o..\hwbro` of the `.hbp` is relative to this
folder, so the binary lands as `hwbro.exe` in the repository root.

Exit codes: `0` built, `1` build failed, `2` toolchain missing, `3` a running `hwbro.exe` holds the previous
binary.

> Close `hwbro.exe` before rebuilding: the script deletes the previous binary on purpose, so a failed link
> never leaves an old executable behind.

## Run

`hwbro.exe` starts with the two-panel file manager. `Enter` on a `*.DBF` opens the database in the record
browser; `F2` opens the database manager (with the database, on a `*.DBF`; with none, on anything else);
`Alt-X` (or `F10`) exits.

The working directory is the data directory: it is where the panels start and where the `.DBF` files are
looked up.

## Modules

| File | Contents |
|---|---|
| `hwbro.prg` | start-up, splash, `F1..F9` menu bar, `DoMenu()`, error log |
| `bp_ui.prg` | screen toolkit: frames, messages, confirmation, line editor, list picker, themes |
| `bp_core.prg` | global state, work areas, opening databases, status line, record browser |
| `bp_cmds.prg` | the actions of every menu |
| `bp_struct.prg` | structure copy (`StructApply()`), validation and index rebuild |
| `bp_dot.prg` | dot prompt (`F9`): screen, history, command and expression interpreter |
| `bp_hc.prg` | Harbour Commander: two-panel file manager, viewer, editor, zip, tree, compare, sync, Commander Link |
| `bp_link.prg` | Commander Link transport and protocol (sockets, all in PRG) |
| `bp_win32.c` | native helpers: window hook (mouse, clipboard, close button), registration dump |
| `bp_def.ch` | colours, constants and common includes |
| `hwbro.hbp` | the `hbmk2` project (GTWVG, output `..\hwbro.exe`) |
| `hwbro.rc` / `hwbro.ico` / `ico.png` | icon and executable properties |

## Diagnostics

* Unhandled errors are written to **`hwbro.err`** next to the executable, with the description, the subsystem
  and the call stack.
* Detailed trace: set the environment variable `BP_DEBUG=1`.
* Key injection for automated captures: `set BP_AUTOKEYS=ENTER,DOWN,DOWN,ENTER` (names or numeric key codes,
  comma separated; the first key closes the splash screen and the rest go to the file manager).

## Screen

Driver **GTWVG** (Harbour contrib): it draws the DOS text look (colours, box characters) in a Win32 window,
without a DOS console and without an emulator. The canvas is 120x44 characters.
