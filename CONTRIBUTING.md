# Contributing

Bug reports are most useful with the output of `winapp doctor --deep` and the
log from `winapp logs` (it contains file paths but no passwords).

## Working on it

Clone the repository and link it into the shell's plugin folder:

```bash
git clone https://github.com/ryancoxrbc/omarchy-winapp
ln -s "$PWD/omarchy-winapp" ~/.config/omarchy/plugins/ryancoxrbc.winapp
omarchy-shell shell rescanPlugins
omarchy-winapp/setup
```

`bin/winapp` runs straight from the checkout. Changes to `Panel.qml` need
`omarchy restart shell` to take effect.

Before sending a change:

```bash
shellcheck -x bin/winapp setup tests/run tests/stubs/*
tests/run
```

The tests need no VM: the commands winapp calls (Docker, FreeRDP, Hyprland,
polkit) are replaced by the small stand-ins in `tests/stubs`. Behaviour that
only shows against a real Windows guest should be described in the pull
request: what you ran and what happened.

## Adding a program to the catalog

`catalog.json` gives well-known programs a stable id, a short name and a
curated list of file types. An entry looks like this:

```json
{
  "id": "coreldraw",
  "name": "CorelDRAW",
  "label": "CorelDRAW",
  "categories": "Graphics;VectorGraphics;",
  "exe": ["coreldrw.exe"],
  "ext": ["cdr", "cdt"],
  "opens": ["svg", "pdf"]
}
```

- `exe` is the executable's file name in lower case, as `winapp scan --all`
  prints it. Add `"pathContains": "vendor"` when the name alone is too generic
  (Affinity's `Photo.exe`).
- `ext` is for file types that belong to the program. Only these can make it
  the default app. Put formats it merely can open, like images or PDFs, under
  `opens`.
- `categories` are [desktop menu categories](https://specifications.freedesktop.org/menu-spec/latest/category-registry.html).

Please only add programs whose executable name you have seen in a scan.
A program does not need a catalog entry to work; the entry only makes its name
and file types nicer.
