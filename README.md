# emacs-weathergov

An Emacs package for fetching and using weather forecast data from
the U.S. National Weather Service (weather.gov).

## What it does

`weathergov.el` fetches the "DWML" XML forecast feed from
weather.gov and parses it into a plain Emacs Lisp s-expression (the
same structure produced by `xml-parse-region`). That general-purpose
data structure is then available to any Emacs Lisp code, including
the commands built into this package.

## Installation

Put `weathergov.el` somewhere on your `load-path` and:

```elisp
(require 'weathergov)
```

## Customization

- `weathergov-data-url` — the weather.gov "MapClick" DWML URL to
  fetch. The default points at a fixed latitude/longitude. Get a URL
  for your own location from <https://forecast.weather.gov/>, making
  sure it includes `FcstType=dwml` in the query string so that XML
  is returned instead of an HTML page.

## Commands

- `M-x weathergov-insert` — fetch the data and insert a compact
  one-line ASCII summary of current conditions at point, for logging
  into notes, e.g.:

  ```
  Weather.gov 75F 36% a-few-clouds (high 81F low 61F) pressure 30.09in wind (nnw)8kt dewpoint 46F
  ```

  With a prefix argument (`C-u`), prompts for a URL to fetch instead
  of using `weathergov-data-url`.

## Functions

- `weathergov-fetch-data` — fetches and parses the data, returning
  the s-expression structure. Intentionally general-purpose, so
  other functions can extract whatever they need from it.

- `weathergov-show` — fetches the data and pops to a buffer,
  `*weathergov-show*`, showing a human-readable report of current
  conditions and the text forecast, with faces for readability.

- `weathergov-raw` — fetches the data and pops to a buffer,
  `*weathergov-raw*`, showing the raw parsed s-expression,
  pretty-printed.

  `weathergov-show` and `weathergov-raw` are plain functions rather
  than commands, to keep the `M-x` namespace to just
  `weathergov-insert`; call them from Lisp, e.g. `M-: (weathergov-show)`.

## Provenance

Created by [AI Sloperator](https://www.aisloperator.com/) using
Claude Code, on July 15th, 2026.
