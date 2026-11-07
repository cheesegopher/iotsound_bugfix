#!/usr/bin/env bash

if [[ -n "$SOUND_DISABLE_SPOTIFY" ]]; then
  echo "Spotify is disabled, exiting..."
  exit 0
fi

# --- ENV VARS ---
# SOUND_DEVICE_NAME: Set the device broadcast name for Spotify
# SOUND_SPOTIFY_BITRATE: Set the playback bitrate
SOUND_DEVICE_NAME=${SOUND_DEVICE_NAME:-"balenaSound Spotify $(echo "$BALENA_DEVICE_UUID" | cut -c -4)"}
SOUND_SPOTIFY_BITRATE=${SOUND_SPOTIFY_BITRATE:-160}

# SOUND_SPOTIFY_DISABLE_NORMALISATION: Disable volume normalization
if [[ -z ${SOUND_SPOTIFY_DISABLE_NORMALISATION+x} ]]; then
  set -- "$@" \
    --enable-volume-normalisation
fi

# SOUND_SPOTIFY_USERNAME: Login username for Spotify
# SOUND_SPOTIFY_PASSWORD: No longer supported. Spotify removed password authentication and
#   librespot >= 0.5 exits on startup if --password is passed, so it is ignored and zeroconf is used.
#   SOUND_SPOTIFY_USERNAME is still passed so cached credentials from a previous login can be reused.
if [[ -n "$SOUND_SPOTIFY_USERNAME" ]]; then
  set -- "$@" \
    --username "$SOUND_SPOTIFY_USERNAME"
fi
if [[ -n "$SOUND_SPOTIFY_PASSWORD" ]]; then
  echo "WARNING: SOUND_SPOTIFY_PASSWORD is ignored. Spotify no longer supports password login, connect from the Spotify app instead (zeroconf)."
fi

# SOUND_SPOTIFY_ENABLE_CACHE: Enable Spotify audio cache
if [[ -z ${SOUND_SPOTIFY_ENABLE_CACHE+x} ]]; then
  set -- "$@" \
    --disable-audio-cache
fi

# Start librespot
# We use set/$@ because librespot for some reason does not like env vars and quote escapes
echo "Starting Spotify plugin..."
echo "Device name: $SOUND_DEVICE_NAME"
[[ -n "$SOUND_SPOTIFY_USERNAME" ]] && echo "Using cached credentials for Spotify user $SOUND_SPOTIFY_USERNAME if available."
[[ -n ${SOUND_SPOTIFY_DISABLE_NORMALISATION+x} ]] && echo "Volume normalization disabled."
[[ -n ${SOUND_SPOTIFY_ENABLE_CACHE+x} ]] && echo "Spotify audio cache enabled."

set -- /usr/bin/librespot \
  --backend pulseaudio \
  --name "$SOUND_DEVICE_NAME" \
  --bitrate "$SOUND_SPOTIFY_BITRATE" \
  --cache /var/cache/raspotify \
  --volume-ctrl linear \
  "$@"

exec "$@"
