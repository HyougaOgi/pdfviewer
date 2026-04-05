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

# ターミナルサイズ・セルピクセルサイズ・PNG 寸法からレイアウトを計算する。
# 出力: tc tr_est col_offset row_offset
calc_layout() {
    local png_file=$1
    python3 - "$png_file" "$zoom_percent" <<'PYEOF'
import fcntl, termios, struct, sys

png_file = sys.argv[1]
zoom     = int(sys.argv[2]) / 100.0

# ── ターミナルサイズ取得 (文字数 + ピクセル数) ─────────────────────
try:
    raw = fcntl.ioctl(1, termios.TIOCGWINSZ, b'\x00' * 8)
    t_rows, t_cols, px_w, px_h = struct.unpack('HHHH', raw)
    if not (t_rows and t_cols and px_w and px_h):
        raise ValueError("no pixel info")
    cell_pw = px_w / t_cols
    cell_ph = px_h / t_rows
except Exception:
    try:
        raw4 = fcntl.ioctl(1, termios.TIOCGWINSZ, b'\x00' * 4)
        t_rows, t_cols = struct.unpack('HH', raw4)
    except Exception:
        t_rows, t_cols = 40, 120
    t_rows = t_rows or 40
    t_cols = t_cols or 120
    cell_pw = 8.0
    cell_ph = 16.0
    px_w = t_cols * cell_pw
    px_h = t_rows * cell_ph

display_rows = max(1, t_rows - 1)
avail_pw = px_w
avail_ph = cell_ph * display_rows

# ── PNG 寸法取得 ────────────────────────────────────────────────────
try:
    with open(png_file, 'rb') as f:
        f.read(8); f.read(4); f.read(4)
        img_w, img_h = struct.unpack('>II', f.read(8))
except Exception:
    img_w, img_h = 0, 0

if img_w <= 0 or img_h <= 0:
    print(max(1, t_cols), display_rows, 1, 1)
    sys.exit(0)

# ── スケール計算 ────────────────────────────────────────────────────
# zoom=100% の基準: 幅いっぱい (ポートレート PDF でも端末幅を最大活用)
base_scale = avail_pw / img_w
scale      = base_scale * zoom

# ズームアウトして画面内に収まる場合 → 上下左右均等に余白を取る
fit_scale = min(avail_pw / img_w, avail_ph / img_h)
if scale < fit_scale:
    scale = fit_scale * zoom

tpw = img_w * scale
tph = img_h * scale

# ── セル単位に変換 ──────────────────────────────────────────────────
tc     = max(1, round(tpw / cell_pw))   # Kitty c= に渡す列数
tr_est = max(1, round(tph / cell_ph))   # 垂直センタリング用の推定行数

# ── センタリングオフセット (1-based) ───────────────────────────────
col_offset = max(1, (t_cols - tc) // 2 + 1)

if tr_est <= display_rows:
    row_offset = max(1, (display_rows - tr_est) // 2 + 1)
else:
    row_offset = 1

print(tc, tr_est, col_offset, row_offset)
PYEOF
}

render_page() {
    local page=$1
    local png_file tc tr_est co ro
    local rows encoded_path

    png_file=$(render_page_png "$page")
    read -r tc tr_est co ro < <(calc_layout "$png_file")

    rows=$(tput lines 2>/dev/null || printf '40')

    encoded_path=$(printf '%s' "$png_file" | base64_noline)

    # 画面クリア → 既存画像削除 → センタリング位置へ移動 → 描画
    # r= は指定しない: Kitty が自然なアスペクト比で高さを決定する
    printf '\033[2J\033[H'
    printf '\033_Ga=d,d=A,q=2\033\\'
    printf '\033[%s;%sH' "$ro" "$co"
    printf '\033_Ga=T,t=f,f=100,q=2,C=1,c=%s;%s\033\\' \
        "$tc" "$encoded_path"

    printf '\033[%s;1H' "$rows"
    printf '\033[2K'
    printf 'Page %s/%s  zoom %s%%  [n]ext [p]rev [z]oom-in [x]zoom-out [g]jump [r]erender [q]uit' \
        "$page" "$page_count" "$zoom_percent"
}

rerender_current_page() {
    rm -f "$cache_dir/page-${current_page}.png"
    render_page "$current_page"
}
jump_to_page() {
    local input rows
    rows=$(tput lines 2>/dev/null || printf '40')
    printf '\033[%s;1H' "$rows"
    printf '\033[2K'
    printf 'Page number: '
    stty echo icanon
    IFS= read -r input
    stty -echo -icanon min 1 time 0
    if [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= page_count)); then
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
        if ((current_page < page_count)); then
            ((current_page += 1))
        fi
        render_page "$current_page"
        ;;
    p)
        if ((current_page > 1)); then
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
        if ((zoom_percent > 10)); then
            ((zoom_percent -= 10))
        fi
        render_page "$current_page"
        ;;
    q)
        break
        ;;
    esac
done
