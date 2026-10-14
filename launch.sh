#!/usr/bin/env bash
# Lanza rofi y le asegura el foco de entrada.
# Con focus_follows_pointer en bspwm, rofi (override-redirect) no gana foco solo.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/localplayer"
sr=$(cat "$CACHE/last.idx" 2>/dev/null || echo 0)
# Fuerza que el primer pintado emita el theme (color del cursor + cover).
rm -f "$CACHE/last.theme"
rofi \
    -selected-row "$sr" \
    "$@" &
pid=$!
w=""
for _ in $(seq 1 50); do
    for c in $(xdotool search --class rofi 2>/dev/null); do
        p=$(xprop -id "$c" _NET_WM_PID 2>/dev/null | awk '{print $3}')
        if [ "$p" = "$pid" ]; then
            w="$c"
            break
        fi
    done
    [ -n "$w" ] && break
    sleep 0.1
done
[ -n "$w" ] && xdotool windowfocus --sync "$w" 2>/dev/null
wait "$pid"
