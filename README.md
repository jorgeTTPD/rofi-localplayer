# rofi-localplayer

Local music player UI for `~/Music` (`cmus` backend) as a rofi script-mode dialog. Cover art, dominant-color selection, shuffle-all, indexed search.

Bound to `super+p` in my bspwm setup.

## Files
- `localplayer.sh` — rofi script mode: index, thumbs, playback, theming
- `launch.sh` — launches rofi and forces input focus (bspwm `focus_follows_pointer` fix)
- `localplayer.rasi` — translucent theme (Catppuccin-ish)

## Deps
`rofi cmus tmux ffmpeg/ffprobe metaflac imagemagick xdotool xprop shuf flock`

## Install
```bash
mkdir -p ~/.config/rofi/localplayer ~/.cache/localplayer
cp launch.sh localplayer.sh localplayer.rasi ~/.config/rofi/localplayer/
chmod +x ~/.config/rofi/localplayer/{launch.sh,localplayer.sh}
```

## sxhkd (super+p)
```
super + p
    pkill -x rofi || ~/.config/rofi/localplayer/launch.sh -show localplayer -modes "localplayer:$HOME/.config/rofi/localplayer/localplayer.sh" -show-icons -theme "$HOME/.config/rofi/localplayer/localplayer.rasi"
```

Music dirs are `$HOME/Music` and `$HOME/Música` (edit `MUSIC_DIRS` in `localplayer.sh` to change).
Cache lives in `$XDG_CACHE_HOME/localplayer` (index, playlist, thumbs, cmus socket).
