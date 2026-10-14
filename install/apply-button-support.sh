#!/usr/bin/env bash
#
# Applies the Inky hardware button support patch (patches/button-support.patch)
# to an InkyPi checkout, and works around the known gotchas documented in
# docs/BUTTONS.md that otherwise leave the device in a broken state:
#
#   - spidev failing to build because python3-dev isn't installed yet
#     ("install system dependencies" vs "install python dependencies" race
#     in install/install.sh)
#   - the venv ending up with only pip/setuptools/wheel because that same
#     race (or a flaky PyPI connection) silently aborted requirements.txt
#   - the spi0-0cs single-CS overlay only taking effect after a genuine
#     reboot, not just "SPI enabled this boot"
#
# Safe to re-run; every step checks whether it's already done first.
#
# Usage:
#   ./apply-button-support.sh [path-to-InkyPi-checkout]
#
# Defaults to ~/InkyPi if no path is given. Can be run before OR after
# install/install.sh -- InkyPi's installer symlinks src/ into
# /usr/local/inkypi/src, so patching the checkout takes effect on the next
# service restart either way.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PATCH_FILE="$SCRIPT_DIR/../patches/button-support.patch"
BASE_COMMIT="f7f27de"
INKYPI_DIR="${1:-$HOME/InkyPi}"
VENV_PIP="/usr/local/inkypi/venv_inkypi/bin/pip"

CONFIG_TXT="/boot/firmware/config.txt"
[ -f "$CONFIG_TXT" ] || CONFIG_TXT="/boot/config.txt"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$1" >&2; exit 1; }

[ -f "$PATCH_FILE" ] || die "Patch file not found at $PATCH_FILE (expected alongside this script's repo checkout)"
[ -d "$INKYPI_DIR/.git" ] || die "No InkyPi git checkout found at $INKYPI_DIR (pass the path as an argument)"

# Normalize the patch to LF before use -- if it's ever been copy/pasted or
# saved via a Windows editor, CRLF line endings make `git apply` reject every
# hunk with "patch does not apply" even though the content is identical.
TMP_PATCH="$(mktemp)"
trap 'rm -f "$TMP_PATCH"' EXIT
tr -d '\r' < "$PATCH_FILE" > "$TMP_PATCH"

cd "$INKYPI_DIR"

# --- 1. Apply the patch ------------------------------------------------------
if [ -f src/button_task.py ]; then
    ok "button_task.py already present, skipping patch step"
else
    log "Checking if the patch applies to the current checkout ($(git rev-parse --short HEAD))..."
    if git apply --check "$TMP_PATCH" 2>/dev/null; then
        git apply "$TMP_PATCH"
        ok "Patch applied"
    else
        warn "Doesn't apply cleanly here (upstream has likely moved on) -- checking out the known-good base commit $BASE_COMMIT"
        git fetch --quiet origin "$BASE_COMMIT" 2>/dev/null || true
        git checkout --quiet "$BASE_COMMIT" || die "Could not check out $BASE_COMMIT. Resolve manually: git apply --reject $TMP_PATCH"
        git apply "$TMP_PATCH" || die "Patch still failed to apply at $BASE_COMMIT -- this needs a manual look"
        ok "Patch applied (checked out $BASE_COMMIT first)"
    fi
fi

# --- 2. Enable SPI + I2C with the single-CS overlay the Inky library needs --
log "Checking SPI/I2C configuration in $CONFIG_TXT"
NEED_REBOOT=0

sudo cp "$CONFIG_TXT" "$CONFIG_TXT.bak-button-setup-$(date +%Y%m%d%H%M%S)"

if ! grep -q '^dtparam=i2c_arm=on' "$CONFIG_TXT"; then
    sudo sed -i 's/^#dtparam=i2c_arm=on/dtparam=i2c_arm=on/' "$CONFIG_TXT"
    grep -q '^dtparam=i2c_arm=on' "$CONFIG_TXT" || echo 'dtparam=i2c_arm=on' | sudo tee -a "$CONFIG_TXT" >/dev/null
    NEED_REBOOT=1
fi

if ! grep -q '^dtparam=spi=on' "$CONFIG_TXT"; then
    sudo sed -i 's/^#dtparam=spi=on/dtparam=spi=on/' "$CONFIG_TXT"
    grep -q '^dtparam=spi=on' "$CONFIG_TXT" || echo 'dtparam=spi=on' | sudo tee -a "$CONFIG_TXT" >/dev/null
    NEED_REBOOT=1
fi

if ! grep -q '^dtoverlay=spi0-0cs' "$CONFIG_TXT"; then
    sudo sed -i '/^dtparam=spi=on/a dtoverlay=spi0-0cs' "$CONFIG_TXT"
    NEED_REBOOT=1
fi

# config.txt can be correct while the *running* kernel still has GPIO7/8 held
# by the standard spi0 CS0/CS1 -- that only clears up after a real reboot, not
# just "SPI got enabled earlier this boot" (e.g. by install.sh's own
# raspi-config call). Detect that directly instead of trusting NEED_REBOOT
# alone, since a prior partial setup can leave things in this state even
# when config.txt itself was already correct going into this run.
if command -v gpioinfo >/dev/null 2>&1 && sudo gpioinfo 2>/dev/null | grep -q 'consumer="spi0 CS'; then
    warn "GPIO7/8 are still held by the kernel's SPI driver -- the single-CS overlay isn't active yet"
    NEED_REBOOT=1
fi

if [ "$NEED_REBOOT" = "1" ]; then
    warn "A reboot is required before the button feature will work."
    warn "Re-run this script afterwards to finish checking python dependencies and (re)start the service."
    if [ -t 0 ]; then
        read -r -p "Reboot now? [y/N] " REPLY
        if [[ "${REPLY:-}" =~ ^[Yy]$ ]]; then
            sudo reboot
        fi
    else
        warn "Not an interactive shell -- not rebooting automatically. Run: sudo reboot"
    fi
    exit 0
fi
ok "SPI/I2C already configured and active, no reboot needed"

# --- 3. System + python dependencies -----------------------------------------
log "Ensuring python3-dev is installed (needed to build the spidev extension)"
sudo apt-get install -y python3-dev >/dev/null

if [ ! -x "$VENV_PIP" ]; then
    warn "InkyPi venv not found at $VENV_PIP yet -- run install/install.sh, then re-run this script"
    exit 0
fi

log "Checking the venv actually has InkyPi's dependencies (a flaky PyPI connection during install.sh can silently leave this incomplete)"
if ! "$VENV_PIP" show inky >/dev/null 2>&1 || ! "$VENV_PIP" show flask >/dev/null 2>&1; then
    warn "venv is missing packages -- re-running pip install (this can take a while on slower Pis)"
    sudo "$VENV_PIP" install -r install/requirements.txt
fi
ok "Python dependencies present"

# --- 4. Restart and verify ----------------------------------------------------
log "Restarting inkypi.service"
sudo systemctl restart inkypi.service

# Startup does a full e-ink refresh before the web server starts listening,
# which can take anywhere from ~20s to a minute depending on the Pi and
# display model -- poll instead of a single fixed sleep so this works
# consistently on both a Pi Zero W and faster hardware.
log "Waiting for the service to finish its startup display refresh..."
STATUS="000"
for _ in $(seq 1 30); do
    sleep 2
    STATUS="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:80/)"
    [ "$STATUS" = "200" ] && break
done

LOG_TAIL="$(sudo journalctl -u inkypi.service --no-pager -n 50)"

if grep -q "Woah there" <<< "$LOG_TAIL"; then
    die "GPIO pin conflict still present after restart -- a reboot is required. Run: sudo reboot, then re-run this script."
fi

if grep -q "Started Inky button task" <<< "$LOG_TAIL"; then
    ok "Button task started successfully"
else
    warn "Could not confirm the button task started -- check: sudo journalctl -u inkypi.service -n 50"
fi

if [ "$STATUS" = "200" ]; then
    ok "Dashboard responding at http://$(hostname).local or http://$(hostname -I | awk '{print $1}')"
else
    warn "Dashboard did not respond within 60s (HTTP $STATUS) -- check: sudo journalctl -u inkypi.service -n 50"
fi

ok "Done."
