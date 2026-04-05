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

# ターミナルのサイズ（文字数・ピクセル数）と PNG の寸法を取得して
# 画面中央に収まる c= r= とオフセットを計算する
calc_layout() {
    local png_file=$1
    python3 - "$png_file" "$zoom_percent" <<'EOF'
import fcntl, termios, struct, sys

png_file  = sys.argv[1]
zoom      = int(sys.argv[2]) / 100.0

# ── ターミナルサイズ取得 ──────────────────────────────────────────
try:
    buf = fcntl.ioctl(1, termios.TIOCGWINSZ, b'\x00' * 8)
    t_rows, t_cols, px_w, px_h = struct.unpack('HHHH', buf)
except Exception:
    t_rows, t_cols, px_w, px_h = 40, 120, 0, 0

t_rows = t_rows or 40
t_cols = t_cols or 120

# ステータスバー 1 行分を除いた表示領域
display_rows = max(1, t_rows - 1)

# ── セルのアスペクト比（pixel/cell）──────────────────────────────
if px_w > 0 and px_h > 0:
    cell_w = px_w / t_cols      # 横方向: pixel / cell
    cell_h = px_h / t_rows      # 縦方向: pixel / cell
else:
    # フォールバック: 一般的な端末の比率 (2:1 高さ:幅)
    cell_w = 1.0
    cell_h = 2.0

# ── PNG の画像サイズ取得 ─────────────────────────────────────────
try:
    with open(png_file, 'rb') as f:
        f.read(8); f.read(4); f.read(4)
        img_w, img_h = struct.unpack('>II', f.read(8))
except Exception:
    img_w, img_h = 0, 0

if img_w <= 0 or img_h <= 0:
    # 寸法不明時はシンプルにフォールバック
    tc = max(1, int(t_cols * zoom))
    tr = display_rows
    co = (t_cols - tc) // 2 + 1
    ro = (display_rows - tr) // 2 + 1
    print(tc, tr, max(1, co), max(1, ro))
    sys.exit(0)

# ── 画像をセル座標に変換したアスペクト比 ─────────────────────────
# 画像を cell_w × cell_h のグリッドに置くとき
# cols_needed = img_w / cell_w
# rows_needed = img_h / cell_h
# アスペクト比 (cols per row) = (img_w / cell_w) / (img_h / cell_h)
aspect = (img_w / cell_w) / (img_h / cell_h)   # cols / rows

# ── ズーム後の最大サイズ ─────────────────────────────────────────
max_cols = t_cols * zoom
max_rows = display_rows * zoom

# アスペクト比を保ちつつ最大サイズに収める
if max_cols / aspect <= max_rows:
    tc = max_cols
    tr = tc / aspect
else:
    tr = max_rows
    tc = tr * aspect

tc = max(1, round(tc))
tr = max(1, round(tr))

# ── 画面中央へのオフセット（1-based）────────────────────────────
col_offset = (t_cols - tc) // 2 + 1
row_offset  = (display_rows - tr) // 2 + 1

col_offset = max(1, col_offset)
row_offset  = max(1, row_offset)

print(tc, tr, col_offset, row_offset)
EOF
}

render_page() {
    local page=$1
    local png_file
    local encoded_path
    local tc tr co ro
    local rows cols

    png_file=$(render_page_png "$page")

    # レイアウト計算
    read -r tc tr co ro < <(calc_layout "$png_file")

    rows=$(tput lines 2>/dev/null || printf '40')
    cols=$(tput cols 2>/dev/null || printf '120')

    encoded_path=$(printf '%s' "$png_file" | base64_noline)

    # 画面クリア → 既存画像削除 → 中央にカーソル移動 → 描画
    printf '\033[2J\033[H'
    printf '\033_Ga=d,d=A,q=2\033\\'
    printf '\033[%s;%sH' "$ro" "$co"
    printf '\033_Ga=T,t=f,f=100,q=2,C=1,c=%s,r=%s;%s\033\\' \
        "$tc" "$tr" "$encoded_path"

    # ステータスバー（最終行）
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
    local input
    local rows
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
        if ((zoom_percent > 20)); then
            ((zoom_percent -= 10))
        fi
        render_page "$current_page"
        ;;
    q)
        break
        ;;
    esac
done
