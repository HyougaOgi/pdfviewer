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
zoom_percent=100

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

render_page() {
  local page=$1
  local png_file
  local encoded_path
  local cols
  local rows
  local viewport_rows
  local target_cols

  png_file=$(render_page_png "$page")
  cols=$(tput cols 2>/dev/null || printf '120')
  rows=$(tput lines 2>/dev/null || printf '40')
  viewport_rows=$((rows - 1))
  target_cols=$(( cols * zoom_percent / 100 ))
  if (( target_cols < 1 )); then
    target_cols=1
  fi
  encoded_path=$(printf '%s' "$png_file" | base64_noline)

  printf '\033[2J\033[H'
  printf '\033_Ga=d,d=A,q=2\033\\'
  printf '\033[1;1H'
  printf '\033_Ga=T,t=f,f=100,q=2,C=1,c=%s;%s\033\\' "$target_cols" "$encoded_path"
  printf '\033[%s;1H' "$rows"
  printf '\033[2K'
  printf 'Page %s/%s  zoom %s%%  n next  p prev  z zoom-in  x zoom-out  g jump  r rerender  q quit' "$page" "$page_count" "$zoom_percent"
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
    z)
      ((zoom_percent += 10))
      render_page "$current_page"
      ;;
    x)
      if (( zoom_percent > 20 )); then
        ((zoom_percent -= 10))
      fi
      render_page "$current_page"
      ;;
    q)
      break
      ;;
  esac
done
