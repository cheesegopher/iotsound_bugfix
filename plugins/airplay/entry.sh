#!/usr/bin/env sh

# Check this before starting supervisord: supervisord restarts programs that exit,
# so exiting from start.sh would just loop forever and leave nqptp running.
if [ -n "$SOUND_DISABLE_AIRPLAY" ]; then
  echo "Airplay is disabled, exiting..."
  exit 0
fi

exec supervisord -c /usr/src/supervisor.conf
