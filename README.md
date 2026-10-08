# Richard Qin's Home Page

A small, document-first personal site built with Hugo, semantic HTML, and one CSS file. It has no JavaScript, theme, front-end package manager, external font, analytics, tracking, or cookies.

## Requirements

- Hugo 0.165.0 or newer
- POSIX `sh`
- Make

## Local use

```sh
make build
make serve
make clean
```

`make build` recreates `public/`, runs Hugo, and then copies every public Markdown source and its page-bundle attachments without changing their bytes. The default `BASE_URL` is `http://localhost:1314/`; pass `BASE_URL=https://example.org/` to generate absolute production URLs. `make serve` prepares that same output before starting Hugo at `http://localhost:1314/`; override the port with `make serve PORT=8080`. Hugo rebuilds HTML while serving; restart the command after editing Markdown when the raw `.md` snapshot also needs to change.

The source repository URL, per-file Git base URL, and public email are configured once in `hugo.toml`.

## Announcements

Announcements are separate from journal entries and technical notes. The home page shows the latest three notices above RECENT, with the full archive at `/announcements/`. Announcements and journal entries share `/rss.xml`; RECENT continues to show only journal entries and notes.

Create a notice with:

```sh
hugo new content --kind announcement announcements/your-announcement/index.md
```

Set the title and `created` publication date, keep `updated` current when editing, and write the notice in the generated Markdown file. The home page limit is configured by `params.announcementLimit` in `hugo.toml`.

## Licensing

Site code and templates are licensed under `GPL-3.0-or-later`; see `COPYING`.

Unless an individual document states otherwise, prose and other site content are licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).
