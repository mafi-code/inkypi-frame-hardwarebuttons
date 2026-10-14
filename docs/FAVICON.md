# Favicon

InkyPi had no favicon out of the box. Added a minimal one, consistent with
the existing black-stroke icon style used elsewhere in the app (`clock.svg`,
`display.png`, etc.).

## What changed

- **`src/static/icons/favicon.svg`** (new) — a simple black rounded-square
  frame outline (fits the "picture frame" theme of the app).
- Added `<link rel="icon" type="image/svg+xml" href="{{ url_for('static', filename='icons/favicon.svg') }}">`
  to the `<head>` of all 5 page templates (there's no shared base template,
  so each needed it individually): `inky.html`, `plugin.html`,
  `apikeys.html`, `playlist.html`, `settings.html`.

## Note

If a new page/template is added later, it'll need the same `<link rel="icon">`
line added manually — there's no base template to inherit it from.
