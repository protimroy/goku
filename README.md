# Goku

Goku is a Static Site Generator written in Zig.

## Introduction

A static site generator (SSG) is typically run on some input source to produce a folder of html files, suitable for hosting on any HTTP server. Goku aims to be a SSG that can operate on a variety of input sources to generate static sites of up to hundreds of thousands of pages.

Today, Goku ships with a practical core for documentation sites, blogs, and research-style articles:

- Markdown pages with YAML frontmatter
- Mustache templates
- Server-side rendered JS components
- Built-in preview server
- Hashed static asset pipeline
- Collection pages with previous/next navigation
- SEO metadata, sitemap, Atom feed, and RSS feed generation
- Research-writing features like citations, bibliography imports, footnotes, sidenotes, figures, and interactive figures

## Notice

> [!NOTE]  
> Goku is in its early stages. The roadmap for features is prioritized on an as-needed basis. If you want to use Goku but it's lacking a key feature you need, feel free to check out the [contributing](#contributing) section of the readme.

## Requirements

- Officially supported Zig: `0.15.0-dev.885+e83776595` (you can get it from the [Zig Releases page](https://ziglang.org/download/))

## Installation

Use Zig to build the application binary. With a shell open in this project's directory:

```
/home/protim/Documents/zig-x86_64-linux-0.15.0-dev.885+e83776595/zig build -Doptimize=ReleaseSafe
```

The goku binary will be available at `zig-out/bin/goku`.

## Usage

See [the docs](./site/pages/docs/site.md) on how to scaffold your first Goku site.

To scaffold a new site:

```
./zig-out/bin/goku init my-site
```

To build a site rooted at `site/` into `build/`:

```
./zig-out/bin/goku build site -o build
```

To preview that same site locally:

```
./zig-out/bin/goku preview site -o build
```

The preview server listens on `http://localhost:8552`.

## Site Layout

A typical Goku site looks like this:

```
site/
	assets/
	bibliography/
	components/
	pages/
	templates/
```

Pages live under `site/pages`, templates under `site/templates`, components under `site/components`, and static assets under `site/assets`. Assets are copied into the build output with hashed filenames and resolved through an internal manifest.

## Templates

Templates are Mustache HTML files. The default site in this repository now uses two presentation modes:

- `page.html` for regular pages like docs and changelog entries
- `article.html` for research-style articles that need reading time, TOC, sidenotes, margin figures, and similar layout primitives

Pages choose a template through frontmatter:

```md
---
slug: /research-demo
title: Research Article Demo
template: article.html
---
```

## Research Writing Features

Goku supports a useful subset of research and technical publishing features directly in markdown:

- Footnotes with `[^note]`
- Inline citations like `[@smith2024]`
- Grouped citations like `[@smith2024; @jones2023]`
- Inline bibliography definitions like `[@smith2024]: Smith. Example Paper. 2024.`
- Imported bibliography files through `bibliography:` frontmatter using BibTeX or CSL JSON
- Table-of-contents generation with `options_toc: true`
- Directive blocks like `:::note`, `:::warning`, and `:::details`
- Figure directives like `:::figure` and `:::margin-figure`
- Interactive figure directives like `:::interactive research-plot.js Threshold sweep`
- Inline sidenotes with `^[...]`
- Math and code asset loading only on pages that need them

The repository includes a working example at [site/pages/research-demo.md](./site/pages/research-demo.md).

## Components

Goku components are JavaScript modules rendered on the server and can optionally contribute page-level CSS and JS bundles. They are typically referenced from templates or interactive figure directives.

The repository includes example components in [site/components/sample-code.js](./site/components/sample-code.js) and [site/components/research-plot.js](./site/components/research-plot.js).

## Output

During a build, Goku will:

- Scan `site/pages` recursively for markdown pages
- Parse YAML frontmatter for routing and metadata
- Render templates and components
- Copy and hash static assets
- Write page HTML into the output tree by slug
- Emit `_sitemap.html`, `sitemap.xml`, `atom.xml`, and `rss.xml`
- Write aggregated component CSS and JS bundles when needed

## Further Work

Goku is still evolving, but it is no longer just a bare markdown-to-html tool. The roadmap now focuses more on sharpening existing capabilities, improving authoring ergonomics, and expanding publishing workflows. If there's a feature you'd like to see, please open a GitHub issue.

## Contributing

Contributions are welcome, but I do request that if there's no open GitHub issue regarding your ideal change that you open one first! It's likely that I'm already working on the feature, so following this process helps to ensure that we're not spending double the time.

## Bug reports

If you find a bug in the software, please report it using the GitHub issue tracker for this project's repository.