#!/usr/bin/env bash
# Reproductor local de ~/Music y ~/Música (backend cmus) — modo script de rofi
set -u

ROFI_DIR="$HOME/.config/rofi/localplayer"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/localplayer"
THUMBS="$CACHE/thumbs"
MUSIC_DIRS=("$HOME/Music" "$HOME/Música")
SONGS="$CACHE/songs.tsv"
PL="$CACHE/playlist.m3u"
COVER="$CACHE/cover.jpg"
COVER_SRC="$CACHE/cover.src"
NOCOVER="$CACHE/nocover.jpg"
CMUS_SOCK="$CACHE/cmus.sock"
CMUS_HOME="$CACHE/cfg" # XDG aislado: autosave/caché propios, sin tocar ~/.config/cmus
MPV_SOCK="$CACHE/mpv.sock" # backend anterior: solo para apagarlo una vez
TMUX_SESSION="localplayer"
SEP=$'\x1f'
ICON_MUSIC="audio-x-generic"
# Selector según carátula (igual que lyrics): fondo del cursor con el tono
# dominante del álbum. COLORCACHE compartida con lyrics (mismos thumbs).
DEFAULT_SELECTED="#89b4fa"
COLORCACHE="${XDG_CACHE_HOME:-$HOME/.cache}/lyrics/colors"

mkdir -p "$CACHE" "$COLORCACHE"
[ -f "$NOCOVER" ] || ffmpeg -y -v error -f lavfi -i "color=c=0x313244:s=400x400" \
    -frames:v 1 "$NOCOVER" >/dev/null 2>&1

find_audio() {
    local d
    for d in "${MUSIC_DIRS[@]}"; do
        [ -d "$d" ] || continue
        find "$d" -type f -size +0c \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.wav' \
            -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.opus' \) -print0 2>/dev/null
    done
}

count_audio() {
    find_audio | tr -cd '\0' | wc -c
}

index_stale() {
    local d
    [ -f "$SONGS" ] && [ -f "$PL" ] || return 0
    [ "$(wc -l < "$SONGS")" -ne "$(count_audio)" ] && return 0
    for d in "${MUSIC_DIRS[@]}"; do
        [ -d "$d" ] || continue
        [ -n "$(find "$d" -type f -size +0c \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.wav' \
            -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.opus' \) -newer "$SONGS" -print -quit 2>/dev/null)" ] && return 0
    done
    return 1
}

thumb_key_for() { # artista álbum ruta — clave de miniatura (igual que cover_thumb)
    local artist="$1" album="$2" f="$3"
    if [ -n "$artist" ] && [ -n "$album" ]; then
        printf '%s|%s' "$artist" "$album" | md5sum | cut -c1-16
    else
        printf '%s' "$f" | md5sum | cut -c1-16
    fi
}

build_index() {
    local tmp="$SONGS.tmp" tmpl="$PL.tmp" f n=0 title artist album line key val tkey
    : > "$tmp"
    : > "$tmpl"
    while IFS= read -r -d '' f; do
        title=""; artist=""; album=""
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            key="${line%%=*}"; key="${key#TAG:}"; key="${key,,}"
            val="${line#*=}"
            case "$key" in
                title)  title="$val" ;;
                artist) artist="$val" ;;
                album)  album="$val" ;;
            esac
        done < <(ffprobe -v error -show_entries format_tags=title,artist,album \
                    -of default=noprint_wrappers=1 "$f" 2>/dev/null)
        [ -z "$title" ] && title="$(basename "${f%.*}")"
        [ -z "$artist" ] && artist="Desconocido"
        tkey=$(thumb_key_for "$artist" "$album" "$f")
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$artist" "$title" "$album" "$f" "$tkey" >> "$tmp"
        printf '%s\n' "$f" >> "$tmpl"
        n=$((n + 1))
    done < <(find_audio | sort -z)
    mv "$tmp" "$SONGS"
    mv "$tmpl" "$PL"
    rm -f "$CACHE/thumbs.done"
}

migrate_index() { # añade la columna de portada al índice viejo (una sola vez)
    local first
    [ -f "$SONGS" ] || return 0
    first=$(head -n 1 "$SONGS" 2>/dev/null) || return 0
    [ -n "$first" ] || return 0
    awk -F'\t' 'NR == 1 { exit (NF >= 6 ? 0 : 1) }' "$SONGS" && return 0
    command -v python3 >/dev/null || return 1
    python3 - "$SONGS" <<'EOF' || return 1
import hashlib, sys
p = sys.argv[1]
out = []
with open(p, encoding='utf-8', errors='replace') as fh:
    for line in fh:
        f = line.rstrip('\n').split('\t')
        if len(f) >= 6 or len(f) < 5:
            out.append(line)
            continue
        n, a, t, al, fp = f[0], f[1], f[2], f[3], f[4]
        if a and al:
            key = hashlib.md5(f'{a}|{al}'.encode('utf-8')).hexdigest()[:16]
        else:
            key = hashlib.md5(fp.encode('utf-8')).hexdigest()[:16]
        out.append('\t'.join([n, a, t, al, fp, key]) + '\n')
with open(p + '.tmp', 'w', encoding='utf-8') as fh:
    fh.writelines(out)
EOF
    mv "$SONGS.tmp" "$SONGS"
    rm -f "$CACHE/thumbs.done"
}

gen_missing_thumbs() { # genera portadas ausentes en 2º plano (aperturas siempre rápidas)
    local n artist_i title_i album_i path_i key_i out made=0
    [ -f "$CACHE/thumbs.done" ] && return 0
    (
        command -v flock >/dev/null || exit 0
        exec 10>"$CACHE/thumbs.lock"
        flock -n 10 || exit 0
        mkdir -p "$THUMBS"
        while IFS=$'\t' read -r n artist_i title_i album_i path_i key_i; do
            [ -n "$key_i" ] || continue
            out="$THUMBS/$key_i.jpg"
            [ -f "$out" ] || [ -f "$out.none" ] || [ -f "$path_i" ] || continue
            [ -f "$out" ] || [ -f "$out.none" ] || {
                case "$path_i" in
                    *.flac|*.FLAC)
                        metaflac --export-picture-to="$out" "$path_i" >/dev/null 2>&1 ;;
                    *.mp3|*.MP3|*.m4a|*.M4A|*.ogg|*.OGG|*.opus|*.OPUS|*.wav|*.WAV)
                        ffmpeg -y -v error -i "$path_i" -an -vcodec copy -frames:v 1 "$out" >/dev/null 2>&1 ;;
                    *) : > "$out.none" ;;
                esac
                [ -f "$out" ] || : > "$out.none"
                made=$((made + 1))
                [ "$made" -ge 25 ] && exit 0
            }
        done < "$SONGS"
        touch "$CACHE/thumbs.done"
    ) >/dev/null 2>&1 &
}

index_stale && build_index
migrate_index
gen_missing_thumbs

total=$(wc -l < "$SONGS")

lookup()   { awk -F'\t' -v p="$1" '$5 == p { print $2 "\t" $3; exit }' "$SONGS"; }
index_of() { awk -F'\t' -v p="$1" '$5 == p { print $1; exit }' "$SONGS"; }

cmus_alive() {
    timeout 1 cmus-remote --server "$CMUS_SOCK" -Q >/dev/null 2>&1
}

purge_cmus_state() { # borra playlist/setting persistidos (si no, resucitan al arrancar)
    rm -f "$CMUS_HOME/cmus/autosave"
    rm -rf "$CMUS_HOME/cmus/playlists"
}

start_cmus_server() { # lanza cmus aislado (config propia) en tmux
    mkdir -p "$CMUS_HOME"
    tmux new-session -d -s "$TMUX_SESSION" \
        env XDG_CONFIG_HOME="$CMUS_HOME" cmus --listen "$CMUS_SOCK" >/dev/null 2>&1
}

wait_cmus_dead() { # espera a que no quede ningún proceso cmus (para purgar autosave sin carrera)
    local i
    for i in $(seq 1 150); do
        pgrep -x cmus >/dev/null || return 0
        sleep 0.1
    done
    pkill -9 -x cmus 2>/dev/null
    for i in $(seq 1 50); do
        pgrep -x cmus >/dev/null || return 0
        sleep 0.1
    done
    return 0
}

ensure_cmus() { # servidor arriba y playlist cargada (con lock anti-concurrencia)
    local i
    if cmus_alive; then
        apply_playback_mode
        return 0
    fi
    pkill -f "input-ipc-server=$MPV_SOCK" 2>/dev/null
    rm -f "$MPV_SOCK"
    command -v tmux >/dev/null || return 1
    command -v flock >/dev/null || return 1
    exec 9>"$CACHE/server.lock"
    flock -w 30 9 || return 1
    if ! cmus_alive; then
        tmux kill-session -t "$TMUX_SESSION" 2>/dev/null
        wait_cmus_dead
        purge_cmus_state # estado anterior fuera: arranque limpio
        start_cmus_server
        # Espera acotada: recién arrancado a veces tarda en responder.
        # Si no despierta, se deja el servidor (suele converger solo) y se
        # reintenta en la próxima acción; rofi no se cuelga indefinidamente.
        for i in $(seq 1 30); do
            cmus_alive && break
            sleep 1
        done
        cmus_alive && load_full_playlist
        cmus_alive && apply_playback_mode
        # Foco al panel de temas: `view playlist` deja el foco en el panel
        # izquierdo (lista de playlists); sin `win-next` el `win-activate`
        # de play_index siempre suena la pista 0. Se aparca una sola vez:
        # ni `view` repetido ni `pl-delete/-P` mueven el foco después.
        if cmus_alive; then
            timeout 5 cmus-remote --server "$CMUS_SOCK" -C "view playlist" >/dev/null 2>&1
            timeout 5 cmus-remote --server "$CMUS_SOCK" -C "win-next" >/dev/null 2>&1
        fi
    fi
    flock -u 9
    if cmus_alive; then
        apply_playback_mode
        return 0
    fi
    return 1
}

cmus_field() { # $1 = clave (status|file|tag <nombre>) — extrae de `cmus-remote -Q`
    local key="$1"
    timeout 2 cmus-remote --server "$CMUS_SOCK" -Q 2>/dev/null | awk -v k="$key" 'index($0, k " ") == 1 { sub(k " ", ""); print; exit }'
}

cmus_shuffle_on() { # 0 si el modo aleatorio está activo (off|tracks|albums)
    timeout 3 cmus-remote --server "$CMUS_SOCK" -C "set shuffle?" 2>/dev/null | grep -Eq "shuffle=(tracks|albums|true|1|on)"
}

set_cmus_shuffle() { # $1 = on|off — fija shuffle sin alternar a ciegas
    local want="$1"
    if [ "$want" = "on" ]; then
        cmus_shuffle_on || timeout 5 cmus-remote --server "$CMUS_SOCK" -C "set shuffle=tracks" >/dev/null 2>&1
    else
        cmus_shuffle_on && timeout 5 cmus-remote --server "$CMUS_SOCK" -C "set shuffle=off" >/dev/null 2>&1
    fi
}

apply_playback_mode() { # playlist como fuente + avance automático
    timeout 5 cmus-remote --server "$CMUS_SOCK" -C "set play_library=false" >/dev/null 2>&1
    timeout 5 cmus-remote --server "$CMUS_SOCK" -C "set continue=true" >/dev/null 2>&1
}

wipe_playlist() { # borra las playlists en memoria (el clear no las quita)
    timeout 10 cmus-remote --server "$CMUS_SOCK" -C "pl-delete -a" >/dev/null 2>&1
}

load_full_playlist() { # deja la playlist idéntica a PL (sin duplicados).
    # Nota: `cmus-remote -P` anexa (crea otra playlist si se repite), por eso
    # se borra antes con pl-delete. El servidor importa en 1er plano y puede
    # tardar; se verifica y reintenta un par de veces. Recién arrancado a
    # veces ignora los primeros comandos.
    local i n want
    want=$(wc -l < "$PL")
    for i in 1 2; do
        wipe_playlist
        sleep 1
        timeout 30 cmus-remote --server "$CMUS_SOCK" -P "$PL" >/dev/null 2>&1
        sleep 1
        n=$(timeout 10 cmus-remote --server "$CMUS_SOCK" -C 'save -p -' 2>/dev/null | wc -l)
        [ "$n" -eq "$want" ] && return 0
        sleep 2
    done
    return 1
}

maybe_topup_playlist() { # $1 = salida de `cmus-remote -Q` (vacía = sordo)
    local n last now want
    [ -n "${1:-}" ] || return 0
    [ -s "$PL" ] || return 0
    want=$(wc -l < "$PL")
    n=$(timeout 5 cmus-remote --server "$CMUS_SOCK" -C 'save -p -' 2>/dev/null | wc -l)
    [ "$n" -eq "$want" ] && return 0
    last=$(cat "$CACHE/topup.ts" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $((now - last)) -lt 20 ] && return 0
    exec 8>"$CACHE/topup.lock"
    flock -n 8 || return 0
    n=$(timeout 5 cmus-remote --server "$CMUS_SOCK" -C 'save -p -' 2>/dev/null | wc -l)
    if [ "$n" -ne "$want" ]; then
        echo "$now" > "$CACHE/topup.ts"
        load_full_playlist
        apply_playback_mode
    fi
    flock -u 8
    return 0
}

play_file() { # $1 = path — reproduce y confirma (reintenta acotado)
    local p="$1" i got att
    for att in 1 2 3; do
        timeout 10 cmus-remote --server "$CMUS_SOCK" -f "$p" >/dev/null 2>&1
        for i in $(seq 1 20); do
            got=$(cmus_field file)
            [ "$got" = "$p" ] && return 0
            sleep 0.1
        done
    done
    return 1
}

play_index() { # $1 = índice 0-based en PL — salta al cursor de playlist
    # `player-play FILE` (-f) no mueve el cursor: el siguiente tema caía en
    # cualquier lado. Con view+win-down+win-activate el next/prev quedan en orden.
    # Invariante de foco: el foco queda en el panel derecho (ver ensure_cmus);
    # el reintento con `win-next` lo repara solo si algo lo movió.
    local idx="$1" i got att line want
    [ -n "$idx" ] || return 1
    want=$(sed -n "$((idx + 1))p" "$PL")
    [ -n "$want" ] || return 1
    for att in 1 2; do
        line=$(timeout 5 cmus-remote --server "$CMUS_SOCK" -C 'save -p -' 2>/dev/null | sed -n "$((idx + 1))p")
        if [ "$line" != "$want" ]; then
            load_full_playlist || return 1
        fi
        timeout 5 cmus-remote --server "$CMUS_SOCK" -C "view playlist" >/dev/null 2>&1
        [ "$att" = 2 ] && timeout 5 cmus-remote --server "$CMUS_SOCK" -C "win-next" >/dev/null 2>&1
        timeout 5 cmus-remote --server "$CMUS_SOCK" -C "win-top" >/dev/null 2>&1
        if [ "$idx" -gt 0 ]; then
            timeout 5 cmus-remote --server "$CMUS_SOCK" -C "win-down $idx" >/dev/null 2>&1
        fi
        timeout 5 cmus-remote --server "$CMUS_SOCK" -C "win-activate" >/dev/null 2>&1
        for i in $(seq 1 20); do
            got=$(cmus_field file)
            [ "$got" = "$want" ] && return 0
            sleep 0.1
        done
    done
    return 1
}

select_track() { # $1 = path — reproduce y sigue en orden desde ahí
    local p="$1" idx
    [ -n "$p" ] || return 1
    ensure_cmus || return 1
    apply_playback_mode
    set_cmus_shuffle off
    idx=$(index_of "$p")
    if [ -n "$idx" ]; then
        play_index "$idx" || play_file "$p"
    else
        play_file "$p"
    fi
}

play_shuffled() { # shuffle de cmus: arranca en azar y sigue en azar
    local idx max
    ensure_cmus || return 1
    apply_playback_mode
    set_cmus_shuffle on
    timeout 5 cmus-remote --server "$CMUS_SOCK" -C "reshuffle" >/dev/null 2>&1
    max=$(wc -l < "$PL")
    [ "$max" -gt 0 ] || return 1
    idx=$(shuf -i "0-$((max - 1))" -n 1)
    [ -n "$idx" ] || return 1
    play_index "$idx"
}

cover_for() {
    local f="$1" data artist album thumb
    [ -z "$f" ] && return 1
    [ -f "$COVER_SRC" ] && [ "$(cat "$COVER_SRC" 2>/dev/null)" = "$f" ] && [ -f "$COVER" ] && return 0
    rm -f "$COVER" "$COVER_SRC"
    case "$f" in
        *.flac|*.FLAC)
            metaflac --export-picture-to="$COVER" "$f" >/dev/null 2>&1 ;;
        *.mp3|*.MP3|*.m4a|*.M4A|*.ogg|*.opus)
            ffmpeg -y -v error -i "$f" -an -vcodec copy -frames:v 1 "$COVER" >/dev/null 2>&1 ;;
    esac
    if [ -f "$COVER" ]; then
        printf '%s' "$f" > "$COVER_SRC"
        return 0
    fi
    data=$(awk -F'\t' -v p="$f" '$5 == p {print $1 "\t" $2; exit}' "$SONGS")
    if [ -n "$data" ]; then
        artist="${data%%$'\t'*}"
        album="${data#*$'\t'}"
        thumb=$(cover_thumb "$artist" "$album" "$f") || thumb=""
        if [ -n "$thumb" ] && [ -f "$thumb" ]; then
            cp "$thumb" "$COVER" 2>/dev/null && printf '%s' "$f" > "$COVER_SRC"
            return 0
        fi
    fi
    thumb=$(ls "$THUMBS"/*.jpg 2>/dev/null | head -1)
    [ -n "$thumb" ] && cp "$thumb" "$COVER" 2>/dev/null && printf '%s' "$f" > "$COVER_SRC"
    return 1
}

cover_url_for() { # path → ruta única de portada (thumb del álbum o respaldo)
    local p="$1" a="" al="" t
    [ -z "$p" ] && return 1
    IFS=$'\t' read -r a al _ < <(awk -F'\t' -v q="$p" '$5 == q {print $2 "\t" $4; exit}' "$SONGS")
    t=$(cover_thumb "$a" "$al" "$p") && [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    t=$(ls "$THUMBS"/*.jpg 2>/dev/null | head -1) && [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    [ -f "$NOCOVER" ] && { printf '%s' "$NOCOVER"; return 0; }
    return 1
}

esc() {
    printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

dominant_color() { # cover.jpg — imprime #rrggbb vibrante (cacheado) o default
    local cover="$1" base hexfile hex
    [ -n "$cover" ] && [ -f "$cover" ] || { printf '%s' "$DEFAULT_SELECTED"; return 0; }
    # Sin carátula real no hay nada que extraer: conserva el azul del rasi.
    [ "$cover" = "$NOCOVER" ] && { printf '%s' "$DEFAULT_SELECTED"; return 0; }
    base=$(basename "$cover")
    base="${base%.*}"
    hexfile="$COLORCACHE/$base.hex"
    if [ -f "$hexfile" ] && [ "$hexfile" -nt "$cover" ]; then
        hex=$(cat "$hexfile" 2>/dev/null)
        case "$hex" in \#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
            printf '%s' "$hex"; return 0 ;; esac
    fi
    # Histograma de 6 colores: puntúa píxeles × saturación, descarta grises,
    # negros y blancos puros; luego fija luminancia al rango legible [90,200]
    # para que el texto oscuro (@dark) contraste sobre el seleccionado.
    hex=$(timeout 5 magick "$cover" -resize 80x80! -colors 6 -format "%c" histogram:info:- 2>/dev/null | awk '
        {
            count = $1; sub(/:$/, "", count)
            if (match($0, /\(([0-9.]+),([0-9.]+),([0-9.]+)\)/)) {
                rgb = substr($0, RSTART + 1, RLENGTH - 2)
                n = split(rgb, c, ",")
                r = c[1] + 0; g = c[2] + 0; b = c[3] + 0
                mx = (r > g) ? ((r > b) ? r : b) : ((g > b) ? g : b)
                mn = (r < g) ? ((r < b) ? r : b) : ((g < b) ? g : b)
                sat = mx - mn
                if (match($0, /#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/))
                    hx = substr($0, RSTART, 7)
                else
                    next
                score = count * sat
                if (score > best_score && sat >= 25 && mx >= 50 && mx <= 235) {
                    best_score = score; best_hx = hx
                }
                if (count * (1 + sat / 60) > fb_score) {
                    fb_score = count * (1 + sat / 60); fb_hx = hx
                }
            }
        }
        END {
            hx = (best_score > 0) ? best_hx : fb_hx
            if (hx == "") exit 1
            print hx
        }')
    if [ -z "$hex" ]; then
        hex=$(timeout 5 magick "$cover" -resize 1x1 txt:- 2>/dev/null | grep -om1 '#[0-9A-Fa-f]\{6\}')
    fi
    case "$hex" in \#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) hex="$DEFAULT_SELECTED" ;; esac
    # Normaliza luminancia a [90,200] escalando canales (conserva el tono).
    if [ "$hex" != "$DEFAULT_SELECTED" ]; then
        hex=$(printf '%s' "$hex" | awk '
            {
                hx = $0; sub(/^#/, "", hx)
                r = strtonum("0x" substr(hx, 1, 2)) + 0
                g = strtonum("0x" substr(hx, 3, 2)) + 0
                b = strtonum("0x" substr(hx, 5, 2)) + 0
                lum = (299 * r + 587 * g + 114 * b) / 1000
                if (lum < 90 && lum > 0) {
                    f = 90 / lum
                    r = (r * f > 255) ? 255 : int(r * f)
                    g = (g * f > 255) ? 255 : int(g * f)
                    b = (b * f > 255) ? 255 : int(b * f)
                } else if (lum > 200) {
                    f = 200 / lum
                    r = int(r * f); g = int(g * f); b = int(b * f)
                }
                printf "#%02X%02X%02X", r, g, b
            }')
    fi
    case "$hex" in \#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) hex="$DEFAULT_SELECTED" ;; esac
    printf '%s' "$hex" > "$hexfile" 2>/dev/null
    printf '%s' "$hex"
}

cover_thumb() { # artista álbum path → ruta de miniatura o ""
    local artist="$1" album="$2" f="$3" key out
    # Clave por álbum solo con tags completos; si no, por ruta (evita colisiones
    # tipo md5("|") donde varias canciones compartirían portada).
    if [ -n "$artist" ] && [ -n "$album" ]; then
        key=$(printf '%s|%s' "$artist" "$album" | md5sum | cut -c1-16)
    else
        key=$(printf '%s' "$f" | md5sum | cut -c1-16)
    fi
    out="$THUMBS/$key.jpg"
    [ -f "$out" ] && { printf '%s' "$out"; return 0; }
    [ -f "$out.none" ] && return 1
    mkdir -p "$THUMBS"
    case "$f" in
        *.flac|*.FLAC)
            metaflac --export-picture-to="$out" "$f" >/dev/null 2>&1 ;;
        *.mp3|*.MP3|*.m4a|*.M4A|*.ogg|*.opus)
            ffmpeg -y -v error -i "$f" -an -vcodec copy -frames:v 1 "$out" >/dev/null 2>&1 ;;
    esac
    if [ -f "$out" ]; then
        printf '%s' "$out"
    else
        : > "$out.none"
        return 1
    fi
}

mode_opt() { # clave valor — cabecera de modo: \0clave\x1fvalor\n
    printf '\0%s%s%s\n' "$1" "$SEP" "$2"
}

row() { # texto ["clave\x1fvalor"...] — fila: texto\0clave\x1fvalor\x1fclave\x1fvalor\n
    local text="$1" kv k v first=1
    shift
    printf '%s' "$text"
    for kv in "$@"; do
        k="${kv%%"$SEP"*}"
        v="${kv#*"$SEP"}"
        if [ "$first" = 1 ]; then
            printf '\0%s%s%s' "$k" "$SEP" "$v"
            first=0
        else
            printf '%s%s%s' "$SEP" "$k" "$SEP" "$v"
        fi
    done
    printf '\n'
}

print_rows() {
    local alive=0 state="idle" path="" artist="" title="" msg data last
    local cover_path="" cover_url="" cstate="" stopped_file=""

    mode_opt "prompt" "♪ Música"
    mode_opt "no-custom" "true"
    mode_opt "keep-filter" "true"
    mode_opt "keep-selection" "true"

    # Una sola consulta acotada: si el servidor está sordo, rofi no se cuelga.
    if qstatus=$(timeout 3 cmus-remote --server "$CMUS_SOCK" -Q 2>/dev/null); then
        cstate=$(awk '$1 == "status" {print $2; exit}' <<<"$qstatus")
        if [ "$cstate" = "playing" ] || [ "$cstate" = "paused" ]; then
            alive=1
            path=$(awk '/^file /{sub(/^file /,""); print; exit}' <<<"$qstatus")
            state="paused"; [ "$cstate" = "playing" ] && state="playing"
            if [ -n "$path" ]; then
                data=$(lookup "$path")
                if [ -n "$data" ]; then
                    artist="${data%%$'\t'*}"
                    title="${data#*$'\t'}"
                fi
            fi
            [ -z "$title" ] && title=$(awk '/^tag title /{sub(/^tag title /,""); print; exit}' <<<"$qstatus")
            [ -z "$title" ] && title="$(basename "${path%.*}")"
            [ -z "$artist" ] && artist=$(awk '/^tag artist /{sub(/^tag artist /,""); print; exit}' <<<"$qstatus")
            [ -z "$artist" ] && artist="Desconocido"
            printf '%s' "$path" > "$CACHE/last.path"
        else
            stopped_file=$(cmus_field file)
            if [ -n "$stopped_file" ] && [ -f "$stopped_file" ]; then
                printf '%s' "$stopped_file" > "$CACHE/last.path"
            fi
        fi
    fi

    if [ "$alive" = "1" ]; then
        if [ "$state" = "playing" ]; then
            msg="<b>$(esc "$title")</b>&#10;$(esc "$artist")&#10;&#10;⏸  En reproducción"
        else
            msg="<b>$(esc "$title")</b>&#10;$(esc "$artist")&#10;&#10;▶  En pausa"
        fi
        cover_for "$path"
        cover_path="$path"
    else
        last=$(cat "$CACHE/last.path" 2>/dev/null || true)
        if [ -n "$last" ] && [ -f "$last" ]; then
            cover_for "$last"
            cover_path="$last"
            data=$(lookup "$last")
            title="${data#*$'\t'}"; artist="${data%%$'\t'*}"
            msg="<b>$(esc "$title")</b>&#10;$(esc "$artist")&#10;&#10;⏹  Detenido"
        else
            msg="Sin reproducción&#10;$total canciones en tu música"
        fi
    fi
    mode_opt "message" "$msg"

    # Portada grande fija: solo la de la canción en reproducción (o la última).
    # background-image se evalúa en cada dibujado, así que llega por `theme`;
    # la ruta es única por álbum para no chocar con la caché de rofi.
    # El cursor del teclado se tiñe con el tono dominante de esa carátula
    # (propiedad directa: redefinir `* { selected: }` rompe el estilo en rofi).
    # Solo se emite cuando cambia para no reaplicar estilo en cada tecla.
    _sel="$DEFAULT_SELECTED"
    _theme_sig="$_sel|"
    if cover_url=$(cover_url_for "$cover_path"); then
        _sel=$(dominant_color "$cover_url")
        case "$_sel" in \#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
            *) _sel="$DEFAULT_SELECTED" ;; esac
        _theme_sig="$_sel|$cover_url"
        _theme="element selected { background-color: ${_sel}FF; } prompt { text-color: ${_sel}FF; } icon-cover { background-image: url(\"$cover_url\", width); }"
        if [ "$_theme_sig" != "$(cat "$CACHE/last.theme" 2>/dev/null)" ]; then
            mode_opt "theme" "$_theme"
            printf '%s' "$_theme_sig" > "$CACHE/last.theme" 2>/dev/null
        fi
    fi

    # Si la playlist quedó vacía (arranque sordo), recargarla sin bloquear.
    maybe_topup_playlist "$qstatus"

    # resaltado → pista objetivo (absoluto: 0 = 🎲, canción = índice + 1)
    local target="" row_idx prev
    if [ "$alive" = "1" ] && [ -n "$path" ]; then
        target=$(index_of "$path")
    elif [ -n "${last:-}" ]; then
        target=$(index_of "$last")
    fi
    if [ -n "$target" ]; then
        row_idx=$((target + 1))
        printf '%s' "$row_idx" > "$CACHE/last.idx"
        prev=$(cat "$CACHE/last.target" 2>/dev/null || true)
        if [ "$prev" != "$row_idx" ] && [ -z "${ROFI_INPUT:-}" ]; then
            mode_opt "new-selection" "$row_idx"
        fi
        printf '%s' "$row_idx" > "$CACHE/last.target"
    else
        rm -f "$CACHE/last.idx" "$CACHE/last.target"
    fi

    row "Reproducir todo (aleatorio)" "icon${SEP}media-playlist-shuffle" "info${SEP}cmd:shuffle"

    local n=0 artist_i title_i album_i path_i key_i thumb t
    while IFS=$'\t' read -r n artist_i title_i album_i path_i key_i; do
        [ -z "$path_i" ] && continue
        thumb="$ICON_MUSIC"
        if [ -n "$key_i" ]; then
            t="$THUMBS/$key_i.jpg"
            [ -f "$t" ] && thumb="$t"
        fi
        row "$artist_i — $title_i" "icon${SEP}$thumb" "info${SEP}path:$path_i"
    done < "$SONGS"
}

retv="${ROFI_RETV:-0}"
sel="${1:-}"
info="${ROFI_INFO:-}"

if [ "$retv" = "0" ]; then
    print_rows
    exit 0
fi

if [ -z "$info" ] && [ -z "$sel" ]; then
    print_rows
    exit 0
fi

case "$info" in
    cmd:shuffle)
        play_shuffled ;;
    cmd:*)
        ;;
    path:*)
        select_track "${info#path:}" ;;
    *)
        ;;
esac

sleep 0.2
print_rows
