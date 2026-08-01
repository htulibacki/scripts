#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LANG=pl_PL.UTF-8
export LC_ALL=pl_PL.UTF-8

WHISPER="$HOME/.local/bin/whisper-cli"
MODEL="$HOME/Ai/Models/ggml-large-v3-turbo.bin"
VAD_MODEL="$HOME/Ai/Models/ggml-silero-v5.1.2.bin"
WAV=/tmp/speech-to-text.wav
PID=/tmp/speech-to-text.pid
LOG="$HOME/.local/state/speech-to-text.log"
PROMPT="Laravel, Filament, Livewire, Vue, Tailwind, Nginx, Hetzner, Forge, PostgreSQL, Proxmox, Claude Code, git commit, refactor, deploy."

mkdir -p "$(dirname "$LOG")"
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

case "${1:-}" in
  start)
    [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null && exit 0
    rm -f "$WAV"
    command -v rec >/dev/null || { log "BLAD: brak sox/rec w PATH"; exit 12; }
    # --buffer 256 zamiast 1024: mniejszy bufor = szybsze pierwsze probki
    # (zmierzone ~172ms -> ~141ms do momentu, gdy mikrofon realnie nagrywa).
    nohup rec -q --buffer 256 -c 1 -r 16000 -b 16 "$WAV" >/dev/null 2>&1 &
    echo $! > "$PID"
    # Odpytujemy co 5ms zamiast co 20ms - sama petla dokladala do 20ms
    # opoznienia po tym, jak strumien byl juz gotowy.
    for _ in $(seq 200); do
      [ -f "$WAV" ] && [ "$(stat -f%z "$WAV" 2>/dev/null || echo 0)" -gt 600 ] && break
      sleep 0.005
    done
    ;;

  stop)
    [ -f "$PID" ] || exit 0
    kill -INT "$(cat "$PID")" 2>/dev/null || true
    for _ in $(seq 100); do
      kill -0 "$(cat "$PID")" 2>/dev/null || break
      sleep 0.05
    done
    rm -f "$PID"

    [ -s "$WAV" ] || { log "BLAD: brak nagrania ($WAV pusty)"; exit 10; }

    # Whisper gada na stderr takze przy pelnym sukcesie, wiec buforujemy
    # jego wyjscie i przepisujemy do logu dopiero gdy naprawde zawiedzie.
    ERR=$(mktemp -t speech-to-text-err)
    trap 'rm -f "$ERR"' EXIT

    # VAD odsiewa fragmenty bez mowy, zanim trafia do dekodera. Bez tego
    # whisper na ciszy halucynuje frazy wyuczone z napisow telewizyjnych
    # ("WDR mediagroup GmbH...", "www.patreon.com/..." itp.). Gdy modelu
    # brakuje, dyktowanie ma dzialac dalej - tylko bez filtra.
    # -vt 0.2 (zamiast 0.5): domyslny prog gubil krotkie slowa wypowiadane
    # po dluzszej pauzie. -vp 200 dokleja 0.2s wokol kazdego segmentu, zeby
    # nie ucinac koncowek. Cisza i szum nadal daja pusta transkrypcje.
    VAD_ARGS=()
    if [ -f "$VAD_MODEL" ]; then
      VAD_ARGS=(--vad --vad-model "$VAD_MODEL" -vt 0.2 -vp 200)
    else
      log "UWAGA: brak modelu VAD ($VAD_MODEL) - transkrypcja bez filtra ciszy"
    fi

    set +e
    # -nth 0.8 (domyslnie 0.6): ostrzejszy prog "braku mowy" w samym
    # dekoderze - druga warstwa obrony, niezalezna od VAD.
    RAW=$("$WHISPER" -m "$MODEL" -l pl -nt -np -nth 0.8 "${VAD_ARGS[@]}" \
      --prompt "$PROMPT" -f "$WAV" 2>"$ERR")
    RC=$?
    set -e
    [ $RC -eq 0 ] || { cat "$ERR" >> "$LOG"; log "BLAD: whisper zwrocil $RC"; exit 13; }

    TEXT=$(printf '%s' "$RAW" | tr '\n' ' ' | sed 's/  */ /g;s/^ *//;s/ *$//')
    [ -n "$TEXT" ] || { cat "$ERR" >> "$LOG"; log "UWAGA: pusta transkrypcja"; exit 11; }

    # Whisper zapisuje kwestie mowione jak w napisach filmowych, wiec wtraca
    # na poczatku myslnik albo wielokropek. Przy dyktowaniu to zawsze artefakt.
    # Obcinamy wiodace myslniki (- – —), kropki, przecinki i cudzyslowy wraz
    # z odstepami; nawiasu nie ruszamy, by nie psuc "(nawiasem mowiac...)".
    TEXT=$(printf '%s' "$TEXT" | sed 's/^[[:space:]]*[-–—.,"„”«»…]*[[:space:]]*//')
    TEXT=$(printf '%s' "$TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Gdy przez VAD przecieknie oddech albo stukniecie, dekoder potrafi zwrocic
    # sama interpunkcje ("-", "...", "[?]"). Prawdziwa transkrypcja zawsze ma
    # litere lub cyfre; klasa [:alnum:] w pl_PL.UTF-8 obejmuje tez polskie
    # znaki diakrytyczne, wiec "ćma" czy "źle" przechodza normalnie.
    printf '%s' "$TEXT" | grep -q '[[:alnum:]]' || {
      log "UWAGA: odrzucono transkrypcje bez tresci: [$TEXT]"
      exit 11
    }

    # Spacja na koncu, zeby przy kolejnym dyktowaniu nie trzeba jej bylo
    # dopisywac recznie. Doklejamy dopiero tutaj - kontrole wyzej maja
    # dzialac na czystym tekscie.
    printf '%s ' "$TEXT" | pbcopy
    sleep 0.15
    osascript -e 'tell application "System Events" to keystroke "v" using command down' 2>"$ERR" \
      || { cat "$ERR" >> "$LOG"; log "BLAD: osascript - brak uprawnien Dostepnosci?"; exit 14; }

    # Nagranie kasujemy dopiero tutaj, po udanym wklejeniu. Przy kazdym
    # wczesniejszym bledzie skrypt konczy sie przez exit i WAV zostaje
    # na dysku do odsluchania przy diagnozie.
    rm -f "$WAV"
    ;;
esac
