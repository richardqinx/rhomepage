# Richard Qin's Home Page

A small, document-first personal site built with Hugo, semantic HTML, and one CSS file. It has no JavaScript, theme, front-end package manager, external font, analytics, tracking, or cookies.

## Requirements

- Hugo 0.123.7 or newer
- POSIX `sh`
- Make

## Local use

```sh
make build
make serve
make clean
```

`make build` recreates `public/`, runs Hugo, and then copies every public Markdown source and its page-bundle attachments without changing their bytes. `make serve` prepares that same output before starting Hugo at `http://localhost:1314/`; override the port with `make serve PORT=8080`. Hugo rebuilds HTML while serving; restart the command after editing Markdown when the raw `.md` snapshot also needs to change.

The source repository URL, per-file Git base URL, and public email are configured once in `hugo.toml`.

The specification files and acceptance content in this working tree are deliberately ignored through exact `.gitignore` entries. Remove the relevant fixture entry when replacing it with real content that should be tracked.

## Licensing

Site code and templates are licensed under `GPL-3.0-or-later`; see `LICENSE`.

Unless an individual document states otherwise, prose and other site content are licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
