#!/usr/bin/env sh

# --- ENV VARS ---
# SOUND_DEVICE_NAME: Set the device broadcast name for AirPlay
SOUND_DEVICE_NAME=${SOUND_DEVICE_NAME:-"balenaSound AirPlay $(echo "$BALENA_DEVICE_UUID" | cut -c -4)"}

echo "Starting AirPlay plugin..."
echo "Device name: $SOUND_DEVICE_NAME"

# Start AirPlay
echo "Starting Shairport Sync. Device is discoverable as $SOUND_DEVICE_NAME"
exec shairport-sync \
  --name "$SOUND_DEVICE_NAME" \
  --output alsa \
  -- -d pulse
