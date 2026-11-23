#!/bin/bash
# Runs before the audio block's entry.sh, which picks the output sink from the sound cards present at startup.
# Anything that adds or changes sound cards has to happen here, not in start.sh.

# Some balenaOS releases boot the Raspberry Pi with snd_bcm2835.enable_headphones=0 on the kernel command line
# (added by the firmware), which hides the 3.5mm jack even with dtparam=audio=on. That leaves only the HDMI
# outputs, which don't work without a connected display, so the device is silent.
# Reload the driver with the jack enabled. Needs a privileged container and the host's kernel modules
# (io.balena.features.kernel-modules label). Set SOUND_DISABLE_RPI_HEADPHONES_FIX=1 to skip.
function enable_rpi_headphones() {
  local PARAMS=/sys/module/snd_bcm2835/parameters

  [[ -n "$SOUND_DISABLE_RPI_HEADPHONES_FIX" ]] && return 0
  # Not a Raspberry Pi, or the driver isn't loaded
  [[ -r "$PARAMS/enable_headphones" ]] || return 0
  case "$(cat "$PARAMS/enable_headphones")" in Y|y|1) return 0 ;; esac
  grep -q 'bcm2835 Headphones' /proc/asound/cards && return 0

  local KO
  KO=$(find "/lib/modules/$(uname -r)" -name 'snd-bcm2835.ko*' 2> /dev/null | head -n 1)
  if [[ -z "$KO" ]]; then
    echo "WARNING: The 3.5mm jack is disabled, but snd-bcm2835 wasn't found in /lib/modules/$(uname -r)."
    echo "Is the io.balena.features.kernel-modules label set on the audio service?"
    return 0
  fi

  # busybox insmod can't read compressed modules
  local RAW=/tmp/snd-bcm2835.ko
  local OK=0
  case "$KO" in
    *.zst) zstd -q -d -c "$KO" > "$RAW" && OK=1 ;;
    *.xz)  xzcat "$KO" > "$RAW" && OK=1 ;;
    *.gz)  zcat "$KO" > "$RAW" && OK=1 ;;
    *)     cp "$KO" "$RAW" && OK=1 ;;
  esac
  if [[ "$OK" != 1 ]]; then
    echo "WARNING: Could not decompress $KO, leaving the 3.5mm jack disabled."
    return 0
  fi

  local HDMI
  HDMI=$(cat "$PARAMS/enable_hdmi" 2> /dev/null || echo N)

  echo "Enabling the Raspberry Pi 3.5mm jack (reloading snd_bcm2835 with enable_headphones=1)..."
  if ! rmmod snd_bcm2835; then
    echo "WARNING: Could not unload snd_bcm2835 (in use?), leaving the 3.5mm jack disabled."
    return 0
  fi
  if ! insmod "$RAW" enable_headphones=1 enable_hdmi="$HDMI"; then
    echo "WARNING: Could not load snd_bcm2835 with the jack enabled, restoring the previous settings."
    insmod "$RAW" enable_hdmi="$HDMI" || echo "WARNING: Could not reload snd_bcm2835."
    return 0
  fi

  # Wait for the card to show up before entry.sh scans for sound cards
  local i
  for i in $(seq 1 10); do
    grep -q 'bcm2835 Headphones' /proc/asound/cards && { echo "3.5mm jack enabled."; return 0; }
    sleep 0.5
  done
  echo "WARNING: snd_bcm2835 reloaded, but the 3.5mm jack didn't appear."
}

enable_rpi_headphones
rm -f /tmp/snd-bcm2835.ko

exec /bin/bash /usr/src/entry.sh "$@"
