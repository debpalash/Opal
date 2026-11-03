#!/bin/sh
# Owned helper, started only after Restart. Arguments are paths, never shell code.
set -eu
parent_pid=$1
target=$2
stage=$3
wait_seconds=${4:-60}
backup="$stage/previous.app"
ready="$stage/ready"
new_app="$stage/Opal.app"
[ -d "$new_app/Contents" ] && [ -d "$target/Contents" ] || exit 1
# The existing process finishes its normal session/config shutdown first.
i=0
while kill -0 "$parent_pid" 2>/dev/null; do
    [ "$i" -lt "$wait_seconds" ] || exit 1
    sleep 1
    i=$((i+1))
done
failed() {
    if [ -d "$backup" ]; then
        if [ -e "$target" ]; then mv "$target" "$stage/failed.app" || exit 1; fi
        mv "$backup" "$target" || exit 1
    fi
    "$target/Contents/MacOS/Opal" >/dev/null 2>&1 &
    if [ "${OPAL_UPDATE_TEST:-}" != 1 ]; then
        /usr/bin/osascript -e 'display alert "Opal could not finish updating" message "Your previous app has been restored. Try again from Settings > About." as critical' >/dev/null 2>&1 || true
    fi
    exit 1
}
mv "$target" "$backup" || exit 1
mv "$new_app" "$target" || failed
# The new app acknowledges its first healthy GUI frames. Preserve the backup
# until then so an app that cannot launch never destroys the working version.
OPAL_UPDATE_ACK="$ready" "$target/Contents/MacOS/Opal" >"$stage/launch.log" 2>&1 &
new_pid=$!
i=0
while [ ! -f "$ready" ]; do
    if ! kill -0 "$new_pid" 2>/dev/null || [ "$i" -ge "$wait_seconds" ]; then
        kill -TERM "$new_pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$new_pid" 2>/dev/null || true
        failed
    fi
    sleep 1
    i=$((i+1))
done
# Both paths are owned children of the randomly created staging directory.
rm -rf "$backup"
rm -rf "$stage"
