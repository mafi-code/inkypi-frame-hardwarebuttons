# ARMv6 HTML rendering fallback

## Problem

On an original Raspberry Pi Zero W (ARMv6, `armv6l`), HTML/CSS-based plugins
(e.g. weather) fail with:

```
ERROR - utils.image_utils - Failed to take screenshot (return code: 132)
ERROR - refresh_task - Exception during refresh
RuntimeError: Failed to take screenshot, please check logs.
```

Running the Chromium binary directly confirms the root cause:

```
$ chromium-headless-shell --version
Illegal instruction
$ echo $?
132
```

Exit 132 = terminated by signal 4 (SIGILL). Debian/Raspbian's
`chromium-headless-shell` package requires ARMv7+ instructions and simply
cannot execute on a genuine ARMv6 core (the Pi Zero W's ARM1176). This is a
hardware ceiling, not a config or install problem — it affects every device
with this CPU (Pi Zero / Zero W / Pi 1), not just Pi Zero 2 W or later, which
are ARMv8 (`aarch64`) and unaffected.

## Fix

Raspbian's own repo (as opposed to generic Debian armhf) still ships
`wkhtmltopdf`/`wkhtmltoimage` (WebKit-based) built for the ARMv6 baseline, since
Raspbian exists specifically to keep Pi Zero support alive. Install it:

```
sudo apt-get install -y wkhtmltopdf
```

Then apply `patches/armv6-wkhtmltoimage-fallback.patch` to
`src/utils/image_utils.py`. It makes `take_screenshot()` try Chromium first
(unchanged behavior on normal hardware) and transparently fall back to
`wkhtmltoimage` whenever Chromium is missing or fails to run (any nonzero
return code — not just SIGILL, so a missing Chromium package degrades the
same way). No plugin code changes needed; `weather.py` and friends still
just call `take_screenshot_html()`.

## Applying

```
cd InkyPi
git apply patches/armv6-wkhtmltoimage-fallback.patch
sudo apt-get install -y wkhtmltopdf
sudo systemctl restart inkypi.service
```
