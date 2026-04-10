---
slug: /docs/shortcode
title: Shortcode
template: page.html
collection: docs
---

With shortcodes, you can inject static and dynamic content into a [page](/docs/page) or a [template](/docs/template).

## Markdown Directives

Goku also supports content-side markdown directives for article layouts that are awkward to express with plain markdown alone.

### Admonitions

Use fenced directives like these:

```md
:::note Reading hint
This is a note block.
:::

:::warning
This is a warning block.
:::
```

Supported directive names are `note`, `tip`, `info`, `warning`, `important`, `caution`, `details`, `figure`, and `margin-figure`.

### Expandable Details

```md
:::details Expand this section
This content is hidden until the reader expands it.
:::
```

### Figures And Margin Figures

```md
:::figure Training curve after the first ten epochs
![A toy calibration curve](/assets/research-curve.svg)
:::

:::margin-figure A side observation that should sit in the margin on wide screens
![A toy calibration curve](/assets/research-curve.svg)
:::
```

### Interactive Figures

Interactive directives render a component before markdown processing, so they do not require `allow_html: true`.

```md
:::interactive research-plot.js Threshold sweep
Drag the slider to move the decision boundary and inspect the updated confusion counts.
:::
```

### Sidenotes

Inline sidenotes use `^[...]` syntax:

```md
This sentence has a sidenote ^[This note will render beside the paragraph on wide screens.].
```
