#!/bin/bash
set -e

# PulseAudio configuration files for balena-sound
CONFIG_TEMPLATE=/usr/src/balena-sound.pa
CONFIG_FILE=/etc/pulse/default.pa.d/01-balenasound.pa

# Set loopback module latency
function set_loopback_latency() {
  local LOOPBACK="$1"
  local LATENCY="$2"
  
  sed -i "s/%$LOOPBACK%/$LATENCY/" "$CONFIG_FILE"
}

# Route "balena-sound.input" to the appropriate sink depending on selected mode
# Either "snapcast" fifo sink or "balena-sound.output"
function route_input_sink() {
  local MODE="$1"

  declare -A options=(
      ["MULTI_ROOM"]=0
      ["MULTI_ROOM_CLIENT"]=1
      ["STANDALONE"]=2
    )

  case "${options[$MODE]}" in
    ${options["STANDALONE"]} | ${options["MULTI_ROOM_CLIENT"]})
      sed -i "s/%INPUT_SINK%/sink=balena-sound.output/" "$CONFIG_FILE"
      echo "Routing 'balena-sound.input' to 'balena-sound.output'."
      ;;

    ${options["MULTI_ROOM"]} | *)
      sed -i "s/%INPUT_SINK%/sink=snapcast/" "$CONFIG_FILE"
      echo "Routing 'balena-sound.input' to 'snapcast'."
      ;;
  esac
}

# Route any existing source to the input router ("balena-sound.input")
function route_input_source() {
  local INPUT_DEVICE=$(arecord -l | awk '/card [0-9]:/ { print $3 }')

  if [[ -n "$INPUT_DEVICE" ]]; then
    local INPUT_DEVICE_FULLNAME="alsa_input.$INPUT_DEVICE.analog-stereo"
    echo "Routing audio from '$INPUT_DEVICE_FULLNAME' into 'balena-sound.input sink'"
    echo -e "\nload-module module-loopback source=$INPUT_DEVICE_FULLNAME sink=balena-sound.input" >> "$CONFIG_FILE"
  fi

}

# Route "balena-sound.output" to the appropriate audio hardware
function route_output_sink() {
  OUTPUT_SINK=""

  # Audio block outputs the default sink name to this file
  # If file doesn't exist, default to sink #0. This shouldn't happen though
  local SINK_FILE=/run/pulse/pulseaudio.sink
  if [[ -f "$SINK_FILE" ]]; then
    OUTPUT_SINK=$(cat "$SINK_FILE")
  fi
  OUTPUT_SINK="${OUTPUT_SINK:-0}"
  sed -i "s|%OUTPUT_SINK%|sink=$OUTPUT_SINK|" "$CONFIG_FILE"
  echo "Routing 'balena-sound.output' to '$OUTPUT_SINK'."
}

# SOUND_VOLUME is applied by the sound supervisor to the virtual "balena-sound.input" sink only,
# while the hardware sink volume is set by the audio block from AUDIO_VOLUME (default 75%).
# Unless AUDIO_VOLUME is explicitly set, make the hardware sink honor SOUND_VOLUME as well.
function set_hardware_volume() {
  local BLOCK_CONFIG=/etc/pulse/default.pa.d/00-audioblock.pa
  local VOLUME="${SOUND_VOLUME//%}"

  if [[ -n "$AUDIO_VOLUME" || -z "$VOLUME" || ! -f "$BLOCK_CONFIG" ]]; then
    return
  fi
  if [[ ! "$VOLUME" =~ ^[0-9]+$ ]] || (( 10#$VOLUME > 100 )); then
    echo "WARNING: Invalid SOUND_VOLUME '$SOUND_VOLUME', expected an integer between 0 and 100."
    return
  fi
  VOLUME=$(( 10#$VOLUME ))

  local VOLUME_ABSOLUTE=$(( VOLUME * 65536 / 100 ))
  sed -i "s/^set-sink-volume @DEFAULT_SINK@ .*/set-sink-volume @DEFAULT_SINK@ $VOLUME_ABSOLUTE/" "$BLOCK_CONFIG"
  echo "Setting hardware output volume to $VOLUME%."
}

# The audio block guesses the hardware sink name (e.g. "alsa_output.bcm2835-jack.stereo-fallback"), but newer
# kernels/OS releases name sinks differently (e.g. "alsa_output.platform-fe00b840.mailbox.stereo-fallback"),
# which makes the output loopback fail to load and leaves the device silent.
# Once PulseAudio is up, verify the sink exists and otherwise route to the closest matching hardware sink.
function ensure_output_sink() {
  local WANTED="$1"
  local SINKS=""
  local i

  for i in $(seq 1 30); do
    if pactl info > /dev/null 2>&1; then
      SINKS=$(pactl list short sinks 2> /dev/null)
      break
    fi
    sleep 1
  done

  if [[ -z "$SINKS" ]]; then
    echo "WARNING: Could not query PulseAudio sinks, skipping output sink verification."
    return
  fi

  # Sink exists (either by name or by index), nothing to do
  if awk -v s="$WANTED" '$1 == s || $2 == s { found = 1 } END { exit !found }' <<< "$SINKS"; then
    return
  fi

  local HW_SINKS
  HW_SINKS=$(awk '$2 ~ /^alsa_output\./ { print $2 }' <<< "$SINKS")
  if [[ -z "$HW_SINKS" ]]; then
    echo "WARNING: Output sink '$WANTED' not found and no hardware sinks are available."
    return
  fi

  local HINT=""
  case "$WANTED" in
    *jack*|*[Hh]eadphones*) HINT='jack|[Hh]eadphones|mailbox' ;;
    *hdmi1*)                HINT='hdmi1|fef05700' ;;
    *hdmi*)                 HINT='hdmi0|fef00700|hdmi' ;;
    *dac*)                  HINT='dac|DAC|Dac' ;;
    *usb*)                  HINT='usb' ;;
  esac

  local FALLBACK=""
  if [[ -n "$HINT" ]]; then
    FALLBACK=$(grep -E "$HINT" <<< "$HW_SINKS" | head -n 1)
  fi
  FALLBACK="${FALLBACK:-$(head -n 1 <<< "$HW_SINKS")}"

  echo "WARNING: Output sink '$WANTED' not found. Routing 'balena-sound.output' to '$FALLBACK' instead."
  echo "Set AUDIO_OUTPUT to the desired sink name to silence this warning. Available hardware sinks:"
  echo "$HW_SINKS"
  pactl load-module module-loopback latency_msec="$SOUND_OUPUT_LATENCY" source=balena-sound.output.monitor sink="$FALLBACK" > /dev/null \
    || echo "WARNING: Failed to route 'balena-sound.output' to '$FALLBACK'."
}

function reset_sound_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    rm "$CONFIG_FILE"
  fi 
  cp "$CONFIG_TEMPLATE" "$CONFIG_FILE"
}

SOUND_SUPERVISOR_PORT=${SOUND_SUPERVISOR_PORT:-80}
SOUND_SUPERVISOR="$(ip route | awk '/default / { print $3 }'):$SOUND_SUPERVISOR_PORT"
# Wait for sound supervisor to start
while ! curl --silent --output /dev/null "$SOUND_SUPERVISOR/ping"; do sleep 5; echo "Waiting for sound supervisor to start at $SOUND_SUPERVISOR"; done

# Get mode from sound supervisor. 
# mode: default to MULTI_ROOM
MODE=$(curl --silent "$SOUND_SUPERVISOR/mode" || true)

# Get latency values
SOUND_INPUT_LATENCY=${SOUND_INPUT_LATENCY:-200}
SOUND_OUPUT_LATENCY=${SOUND_OUTPUT_LATENCY:-200}

# Audio routing: route intermediate balena-sound input/output sinks
echo "Setting audio routing rules..."
reset_sound_config
route_input_sink "$MODE"
route_output_sink
set_loopback_latency "INPUT_LATENCY" "$SOUND_INPUT_LATENCY"
set_loopback_latency "OUTPUT_LATENCY" "$SOUND_OUPUT_LATENCY"
if [[ -n "$SOUND_ENABLE_SOUNDCARD_INPUT" ]]; then
  route_input_source
fi
set_hardware_volume

# Run PulseAudio in the background so the output route can be verified once it's up,
# forwarding stop signals so the container still shuts down cleanly
set +e
pulseaudio &
PA_PID=$!
trap 'kill -TERM "$PA_PID" 2> /dev/null' TERM INT
ensure_output_sink "$OUTPUT_SINK"

# wait returns early when a trapped signal arrives, keep waiting until PulseAudio actually exits
wait "$PA_PID"
PA_EXIT=$?
while kill -0 "$PA_PID" 2> /dev/null; do
  wait "$PA_PID"
  PA_EXIT=$?
done
exit "$PA_EXIT"