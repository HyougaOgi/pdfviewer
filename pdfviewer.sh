#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 path/to/file.pdf" >&2
  exit 1
fi

pdf_path=$1
if [[ ! -f "$pdf_path" ]]; then
  echo "file not found: $pdf_path" >&2
  exit 1
fi

if ! command -v pdftoppm >/dev/null 2>&1; then
  echo "pdftoppm is required" >&2
  exit 1
fi

if ! command -v pdfinfo >/dev/null 2>&1; then
  echo "pdfinfo is required" >&2
  exit 1
fi

term_name=${TERM:-}
if [[ "$term_name" != *ghostty* && "$term_name" != *kitty* ]]; then
  echo "this viewer currently supports ghostty/kitty terminals" >&2
  exit 1
fi

abs_pdf_path=$(cd "$(dirname "$pdf_path")" && pwd)/"$(basename "$pdf_path")"
pdf_hash=$(printf '%s' "$abs_pdf_path" | shasum | awk '{print $1}')
cache_dir="${TMPDIR:-/tmp}/pdfviewer/${pdf_hash}"
mkdir -p "$cache_dir"

page_count=$(
  pdfinfo "$abs_pdf_path" | awk -F': *' '/^Pages:/ { print $2; exit }'
)

if [[ -z "${page_count:-}" ]]; then
  echo "failed to read page count: $abs_pdf_path" >&2
  exit 1
fi

current_page=1

cleanup() {
  printf '\033[?1049l'
  printf '\033_Ga=d,d=A,q=2\033\\'
  stty echo icanon 2>/dev/null || true
}

trap cleanup EXIT INT TERM

render_page_png() {
  local page=$1
  local out_prefix="$cache_dir/page-${page}"
  local out_file="${out_prefix}.png"

  if [[ ! -f "$out_file" ]]; then
    pdftoppm -png -f "$page" -singlefile "$abs_pdf_path" "$out_prefix" >/dev/null 2>&1
  fi

  printf '%s\n' "$out_file"
}

base64_noline() {
  base64 | tr -d '\n'
}

get_image_size() {
  local png_file=$1
  local width
  local height

  width=$(sips -g pixelWidth "$png_file" 2>/dev/null | awk '/pixelWidth:/ { print $2; exit }')
  height=$(sips -g pixelHeight "$png_file" 2>/dev/null | awk '/pixelHeight:/ { print $2; exit }')

  if [[ -z "${width:-}" || -z "${height:-}" ]]; then
    echo "failed to read image size: $png_file" >&2
    exit 1
  fi

  printf '%s %s\n' "$width" "$height"
}

fit_to_terminal() {
  local image_width=$1
  local image_height=$2
  local term_cols=$3
  local term_rows=$4
  local term_width_px=$5
  local term_height_px=$6

  python3 - "$image_width" "$image_height" "$term_cols" "$term_rows" "$term_width_px" "$term_height_px" <<'PY'
import math
import sys

image_width = int(sys.argv[1])
image_height = int(sys.argv[2])
term_cols = max(1, int(sys.argv[3]))
term_rows = max(1, int(sys.argv[4]))
term_width_px = max(1, int(sys.argv[5]))
term_height_px = max(1, int(sys.argv[6]))

cell_width = term_width_px / term_cols
cell_height = term_height_px / term_rows

scale = min(term_width_px / image_width, term_height_px / image_height)
target_width_px = max(1, int(image_width * scale))
target_height_px = max(1, int(image_height * scale))

target_cols = max(1, min(term_cols, math.ceil(target_width_px / cell_width)))
target_rows = max(1, min(term_rows, math.ceil(target_height_px / cell_height)))

print(f"{target_cols} {target_rows}")
PY
}

get_terminal_pixels() {
  python3 <<'PY'
import fcntl
import os
import struct
import sys
import termios

try:
    size = os.get_terminal_size(sys.stdout.fileno())
    cols = size.columns
    rows = size.lines
except OSError:
    cols = 120
    rows = 40

ws_xpixel = cols * 8
ws_ypixel = rows * 16

try:
    buf = struct.pack("HHHH", 0, 0, 0, 0)
    res = fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, buf)
    ws_row, ws_col, xpixel, ypixel = struct.unpack("HHHH", res)
    if xpixel > 0 and ypixel > 0:
        ws_xpixel = xpixel
        ws_ypixel = ypixel
except OSError:
    pass

print(f"{ws_xpixel} {ws_ypixel}")
PY
}

render_page() {
  local page=$1
  local png_file
  local encoded_path
  local cols
  local rows
  local image_width
  local image_height
  local target_cols
  local target_rows
  local start_col
  local start_row
  local viewport_rows
  local term_width_px
  local term_height_px

  png_file=$(render_page_png "$page")
  encoded_path=$(printf '%s' "$png_file" | base64_noline)
  cols=$(tput cols 2>/dev/null || printf '120')
  rows=$(tput lines 2>/dev/null || printf '40')
  viewport_rows=$((rows - 1))
  read -r term_width_px term_height_px < <(get_terminal_pixels)
  read -r image_width image_height < <(get_image_size "$png_file")
  read -r target_cols target_rows < <(fit_to_terminal "$image_width" "$image_height" "$cols" "$viewport_rows" "$term_width_px" "$(( term_height_px * viewport_rows / rows ))")
  start_col=$(( ((cols - target_cols) / 2) + 1 ))
  start_row=$(( ((viewport_rows - target_rows) / 2) + 1 ))
  if (( start_col < 1 )); then
    start_col=1
  fi
  if (( start_row < 1 )); then
    start_row=1
  fi

  printf '\033[2J\033[H'
  printf '\033_Ga=d,d=A,q=2\033\\'
  printf '\033[%s;%sH' "$start_row" "$start_col"
  printf '\033_Ga=T,t=f,f=100,q=2,c=%s,r=%s;%s\033\\' "$target_cols" "$target_rows" "$encoded_path"
  printf '\033[%s;1H' "$rows"
  printf '\033[2K'
  printf 'Page %s/%s  n next  p prev  g jump  r rerender  q quit' "$page" "$page_count"
}

rerender_current_page() {
  rm -f "$cache_dir/page-${current_page}.png"
  render_page "$current_page"
}

jump_to_page() {
  local input
  local rows

  rows=$(tput lines 2>/dev/null || printf '40')
  printf '\033[%s;1H' "$rows"
  printf '\033[2K'
  printf 'Page number: '
  stty echo icanon
  IFS= read -r input
  stty -echo -icanon min 1 time 0

  if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= page_count )); then
    current_page=$input
  fi

  render_page "$current_page"
}

printf '\033[?1049h'
stty -echo -icanon min 1 time 0
render_page "$current_page"

while true; do
  IFS= read -rsn1 key || break
  case "$key" in
    n)
      if (( current_page < page_count )); then
        ((current_page += 1))
      fi
      render_page "$current_page"
      ;;
    p)
      if (( current_page > 1 )); then
        ((current_page -= 1))
      fi
      render_page "$current_page"
      ;;
    g)
      jump_to_page
      ;;
    r)
      rerender_current_page
      ;;
    q)
      break
      ;;
  esac
done
