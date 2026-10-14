# Hardware Buttons (A/B/C/D)

InkyPi does not support the 4 physical buttons on the Pimoroni Inky Impression out
of the box. The only related work upstream is [PR #686](https://github.com/fatihak/InkyPi/pull/686),
which is unmerged and only wires up button A. This document describes the local
patch that adds all 4 buttons, based on that PR's approach.

Validated on an Inky Impression 7.3" (2025 board revision, the one with the
seal), on both an original Raspberry Pi Zero W (ARMv6) and a Raspberry Pi
Zero 2 W (ARMv8/`aarch64`) — same `gpiod`-based approach works on either, the
only hardware-dependent difference being the [ARMv6 Chromium
issue](ARMV6-RENDERING.md), which doesn't affect buttons at all.

## What each button does

| Button | GPIO | Action |
|---|---|---|
| A | 5  | Cycle to the **next** plugin in the active playlist |
| B | 6  | Cycle to the **previous** plugin in the active playlist |
| C | 16 | Force-refresh the **current** plugin (re-render without advancing) |
| D | 24 | **Pause/resume** automatic interval-based playlist cycling |

Pausing (D) only stops the automatic timer-based advance — A/B/C still work
normally while paused. Any button can also be set to **"Go to playlist/plugin..."**
instead of the actions above:

- **Jump to a specific plugin instance** (e.g. always show "Weather: Berlin"),
  regardless of where the playlist's cycle position currently is.
- **Jump to a plugin type**, generically — e.g. "always show Clock", without
  caring which named instance. If an instance of that type already exists in
  the target playlist, it's reused; otherwise one is created on the fly with
  default settings (empty `settings`/`refresh` dicts) and a name derived from
  the plugin's `display_name` (de-duplicated with a `(2)`, `(3)`, ... suffix
  if that name is already taken). The list of plugin types is read from
  whatever is actually installed under `src/plugins/` at request time
  (`device_config.get_plugins()`), so custom-installed plugins show up
  automatically — nothing is hardcoded.
- **Switch to a different playlist**, overriding the time-based schedule.
  This *pins* that playlist as active until another playlist-switch happens
  (button press, or another `switch_to_playlist` call) — it does not
  auto-revert to the schedule on its own.

## Configuring via the dashboard

![Settings page with the Hardware Buttons section expanded, showing each button's action dropdown and the debounce field](images/hardware-buttons-settings.png)

The **Settings** page has a "Hardware Buttons" section (only shown when
`display_type` is `inky`) where each button's action can be changed via a
dropdown (Next plugin / Previous plugin / Refresh current / Pause-resume /
**Go to playlist/plugin...** / Do nothing), plus a numeric field for the
debounce time. When "Go to..." is selected, a second dropdown appears,
grouped by playlist (`<optgroup>`), listing:
- "Whole playlist (auto-cycle)"
- one entry per already-configured plugin instance in that playlist
- one **"+ New `<Plugin Type>`"** entry per installed plugin type (all ~20
  built-in ones, plus any custom-installed plugins)

All of this takes effect **immediately** — no service restart needed, since
`button_task.py` reads `button_actions` and `button_debounce_seconds` from
config on every button press rather than caching them at startup.

GPIO pin assignments are **not** exposed in the dashboard, since
`_request_button_lines()` only requests the GPIO lines once when the button
thread starts — changing a pin requires a restart to take effect, unlike the
action mapping and debounce. They can still be set manually in `device.json`:

```json
{
  "button_a_gpio": 5,
  "button_b_gpio": 6,
  "button_c_gpio": 16,
  "button_d_gpio": 24,
  "button_actions": {
    "a": "next",
    "b": "previous",
    "c": "refresh",
    "d": "pause"
  },
  "button_debounce_seconds": 1.0
}
```

Each entry in `button_actions` is either a plain string (`next`, `previous`,
`refresh`, `pause`, `none`) or, for "go to" actions, a small object:

```json
{
  "button_actions": {
    "a": {"type": "plugin", "playlist": "Default", "plugin_id": "weather", "instance": "Berlin"},
    "b": {"type": "playlist", "playlist": "Evening"},
    "c": {"type": "plugin_type", "playlist": "Default", "plugin_id": "clock"}
  }
}
```

## Files changed

All paths relative to `InkyPi/src/`.

### `button_task.py` (new)

New `ButtonTask` class, modeled on PR #686's `ButtonTask` but extended to watch
all 4 GPIO lines instead of just one:

- Uses `gpiod` + `gpiodevice` (already installed as InkyPi dependencies) to
  request all 4 lines in one call, `Bias.PULL_UP` + `Edge.FALLING`.
- Runs in its own daemon thread, polling for edge events (`wait_edge_events`
  when available, falling back to a sleep loop otherwise).
- Per-button debounce (default 1s, configurable, read live from config on
  every press).
- Looks up each button's configured action from `button_actions` (defaulting
  to a=next, b=previous, c=refresh, d=pause if unset). An action is either a
  plain string dispatched to `refresh_task.cycle_playlist_next()` /
  `cycle_playlist_previous()` / `force_refresh_current()` / `toggle_pause()`
  (`none` is a no-op), or a dict with `"type": "plugin"` / `"type": "plugin_type"` /
  `"type": "playlist"` dispatched to `refresh_task.jump_to_plugin(...)` /
  `refresh_task.jump_to_plugin_type(...)` / `refresh_task.switch_to_playlist(...)`.
- `is_enabled()` gates on `display_type == "inky"` (default), so it's a no-op
  on Waveshare setups.

### `refresh_task.py`

`RefreshTask` gained 3 new public methods and one new internal branch in the
worker loop, mirroring the existing `manual_update()` pattern (condition
variable + wake the background thread):

- `cycle_playlist_next(wait=False)` / `cycle_playlist_previous(wait=False)`
  → set `self.playlist_cycle_direction` and wake the thread. The thread then
  calls `_determine_next_plugin(..., ignore_cycle_interval=True, reverse=...)`
  so the button press always takes effect immediately, regardless of the
  configured `plugin_cycle_interval_seconds`.
- `force_refresh_current(wait=False)` → sets `self.force_refresh_requested`;
  the thread re-renders whatever plugin is at the playlist's
  `current_plugin_index` with `force=True` (bypasses the plugin's own
  `should_refresh()` check), without advancing the index.
- `toggle_pause()` → flips `self.paused` and returns the new state. When
  `paused`, the periodic interval-check branch is skipped; the
  manual/button-triggered branches are unaffected.
- `_determine_next_plugin()` gained two new parameters:
  `ignore_cycle_interval` (skip the "is it time yet" check) and `reverse`
  (call `get_previous_plugin()` instead of `get_next_plugin()`).
- `jump_to_plugin(playlist_name, plugin_id, instance_name, wait=False)` → sets
  `self.jump_target`; the thread looks up the playlist, calls
  `playlist.set_current_plugin(...)` to both find the instance and update
  `current_plugin_index` to point at it, then force-refreshes it.
- `jump_to_plugin_type(playlist_name, plugin_id, wait=False)` → sets
  `self.jump_type_target`; the thread looks for an existing instance of that
  plugin_id in the playlist. If found, jumps to it like `jump_to_plugin`. If
  not, looks up the plugin's config via `device_config.get_plugin(plugin_id)`,
  builds a new `PluginInstance(plugin_id, name, {}, {})` (empty
  settings/refresh — whatever the plugin does with no config, e.g. Clock and
  Year Progress need none; others may error until configured properly via the
  normal playlist UI), appends it to `playlist.plugins`, and force-refreshes
  it. The instance name is `_unique_instance_name(playlist, display_name)` —
  the plugin's `display_name`, de-duplicated against existing instance names
  in that playlist with a `(2)`, `(3)`, ... suffix if needed.
- `switch_to_playlist(playlist_name, wait=False)` → sets
  `self.playlist_switch_target`; the thread sets
  `playlist_manager.pinned_playlist` to that name (see `model.py` below) and
  immediately refreshes whatever plugin that playlist's `_determine_next_plugin`
  resolves to.

### `model.py`

- `Playlist` gained `get_previous_plugin()`, a mirror of the existing
  `get_next_plugin()` but decrementing `current_plugin_index` (with
  wraparound) instead of incrementing it.
- `Playlist` gained `set_current_plugin(plugin_id, name)`, which finds a
  plugin instance by id+name, sets `current_plugin_index` to point at it, and
  returns it (or `None` if not found) — used by the "jump to plugin" button
  action.
- `PlaylistManager` gained a `pinned_playlist` attribute (persisted via
  `to_dict`/`from_dict`). When set, `determine_active_playlist()` returns
  that playlist directly instead of doing the time-window/priority lookup —
  this is what makes the "switch to playlist" button action override the
  schedule. It is *not* auto-cleared; switching to another playlist (or
  editing `device.json` directly) is what changes it. If the pinned playlist
  no longer exists (e.g. deleted), it's cleared automatically and normal
  schedule-based selection resumes.

### `inkypi.py`

Wired `ButtonTask` into the app lifecycle exactly like `RefreshTask`:
instantiated alongside it, started after `refresh_task.start()`, stopped
before `refresh_task.stop()` in the `finally` block, and exposed via
`app.config['BUTTON_TASK']` for consistency (not currently used by any route).

### `blueprints/settings.py`

`settings_page()` now also builds:
- `playlists_for_buttons` — a list of `{name, plugins: [{plugin_id, instance,
  display_name}]}` per playlist (using `device_config.get_plugin(id).display_name`
  for a human-readable label).
- `all_plugin_types` — `[{plugin_id, display_name}, ...]` for *every* plugin
  `settings_page()` finds via `device_config.get_plugins()`, which itself
  dynamically scans `src/plugins/*/plugin-info.json` on every config load —
  nothing is hardcoded, so custom-installed plugins appear automatically.

Both are passed to the template so the "go to" target dropdown can be
populated.

`save_settings()` gained two new optional blocks, following the same
"only touch this key if its field was present in the form" pattern already
used for `inky_saturation`:

- If `button_a_action` is present, all 4 `button_{a,b,c,d}_action` fields are
  read and validated against `VALID_BUTTON_ACTIONS`
  (`{next, previous, refresh, pause, goto, none}`). For `goto`, the matching
  `button_{btn}_target` field is parsed into the appropriate dict shape
  described above:
  - `playlist|<name>` → `{"type": "playlist", ...}`
  - `plugin|<playlist>|<plugin_id>|<instance>` → `{"type": "plugin", ...}`
  - `plugintype|<playlist>|<plugin_id>` → `{"type": "plugin_type", ...}`

  Any other action value is saved as the plain string.
- If `button_debounce_seconds` is present, it's parsed as a float, validated
  to be `>= 0`, and saved as-is.

### `templates/settings.html`

Added a new "Hardware Buttons" collapsible section (same pattern/CSS classes
as the existing "Image Settings" collapsible), shown only when
`display_type` is `inky`. Built with a `{% for %}` loop over the 4 buttons
(same pattern already used elsewhere in this template, e.g. for timezones):
per button, an action `<select>` (`.button-action-select`) and a paired
target `<select>`, grouped by playlist via `<optgroup>` with: one option for
"whole playlist", one per already-configured plugin instance, and one
**"+ New `<Plugin Type>`"** per entry in `all_plugin_types` (looped with a
nested `{% for %}` inside each playlist's `<optgroup>`) — the currently-saved
value is matched back to `selected` by re-encoding it the same way
(`playlist|...` / `plugin|...` / `plugintype|...`) and comparing strings.
Plus one plain number input for the debounce seconds, shared across all 4
buttons.

Two small JS additions (`updateButtonTargetVisibility` /
`initButtonTargetVisibility`) show/hide each target select based on whether
its action select is set to `goto` — purely cosmetic, since `FormData` submits
hidden fields too, so the existing save logic didn't need any changes.

## Installing

`install/apply-button-support.sh [path-to-InkyPi-checkout]` applies the patch
and works around every gotcha below automatically — checks out the right base
commit if the patch doesn't apply cleanly to a newer checkout, enables
SPI/I2C + the single-CS overlay (and tells you when a reboot is actually
needed, which it can detect directly rather than just guessing), makes sure
`python3-dev` is present before anything tries to build `spidev`, re-runs the
venv's `pip install` if it came out incomplete, and does a final restart +
verification. Safe to re-run at any point — every step checks whether it's
already done first. Can be run before or after `install/install.sh` itself,
since InkyPi symlinks `src/` into `/usr/local/inkypi/src`.

## Known gotchas hit during setup

These aren't about the buttons directly, but were required to get the device
into a working state first — noted here since they're easy to hit again after
a re-flash or re-install, and since `apply-button-support.sh` only works
around them for the button feature's own dependencies, not every package
`install.sh` touches:

- **`install/install.sh` race condition**: the script's "install system
  dependencies" step (apt-get, includes `python3-dev`) doesn't reliably finish
  before the "install python dependencies" step starts, so `spidev` can fail
  to build (`fatal error: Python.h: No such file or directory`) even though
  the script reports "Installation Complete". Fix: re-run
  `sudo /usr/local/inkypi/venv_inkypi/bin/pip install -r install/requirements.txt`
  once `python3-dev` is confirmed installed (`dpkg -s python3-dev`).
- **`earlyoom.service` fails to install**: same root cause — a concurrent
  apt-get holds the dpkg lock. Re-run
  `sudo apt-get install -y earlyoom && sudo systemctl enable --now earlyoom`
  afterwards if you see `Failed to enable unit: Unit earlyoom.service does not exist`.
- **Display crashes with `Chip Select: (line 8, GPIO8) currently claimed by spi0 CS0`**:
  the install script's single-CS SPI overlay (`dtoverlay=spi0-0cs` in
  `/boot/firmware/config.txt`) only takes effect after a **reboot**. If you
  decline the script's reboot prompt, the Inky library can't claim GPIO8 until
  you reboot manually.
- **Buttons detected but nothing happens**: check that the active playlist
  actually has plugins in it (`playlist_config.playlists[].plugins` in
  `device.json`) — A/B/C need something to cycle through or refresh.
