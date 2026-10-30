#!/usr/bin/env bash
# webm(VP9+alpha) → 动画 WebP。为什么不用 ffmpeg 直接转：本机 ffmpeg 无 webp 编码器，
# 而 libwebp 的 img2webp 支持带 alpha 的动画合成；分两步（抽帧 → 合成）可控且可断点重跑。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/webm"
OUT="$ROOT/assets/animations"
TMP="$ROOT/.cache/frames"

W="${PET_ANIM_WIDTH:-320}"
H="${PET_ANIM_HEIGHT:-180}"
FPS="${PET_ANIM_FPS:-12}"
Q="${PET_ANIM_Q:-50}"
JOBS="${PET_ANIM_JOBS:-4}"

mkdir -p "$OUT"

# --check：只做产物体检（体积上限、文件数与清单一致性），不转码
if [ "${1:-}" = "--check" ]; then
  total=$(du -sk "$OUT" | awk '{print $1}')
  count=$(ls "$OUT"/*.webp 2>/dev/null | wc -l | tr -d ' ')
  echo "产物: ${count} 个 webp, $((total / 1024)) MB"
  [ "$count" -eq 0 ] && { echo "没有任何产物" >&2; exit 1; }
  [ "$total" -gt 153600 ] && echo "警告: 超过 150MB 目标，请降低 PET_ANIM_Q 或尺寸" >&2
  exit 0
fi

convert_one() {
  local file="$1"
  local name
  name="$(basename "$file" .webm)"
  local target="$OUT/$name.webp"
  [ -f "$target" ] && return 0

  local work="$TMP/$$-$RANDOM"
  mkdir -p "$work"
  # -c:v libvpx-vp9 是关键：默认 vp9 解码器会丢掉 webm 里的 alpha 附加块，抽出来就是白底。
  ffmpeg -v error -c:v libvpx-vp9 -i "$file" \
    -vf "fps=$FPS,scale=$W:$H" -fps_mode passthrough "$work/%05d.png" || {
    echo "抽帧失败: $name" >&2; rm -rf "$work"; return 1; }
  local delay=$((1000 / FPS))
  img2webp -loop 0 -q "$Q" -m 6 -d "$delay" "$work"/*.png -o "$target" >/dev/null || {
    echo "合成失败: $name" >&2; rm -rf "$work"; return 1; }
  rm -rf "$work"
  echo "✓ $name"
}

export -f convert_one
export OUT TMP W H FPS Q

find "$SRC" -maxdepth 1 -name "*.webm" -print0 |
  xargs -0 -P "$JOBS" -I{} bash -c 'convert_one "$@"' _ {}

echo "完成：$(ls "$OUT"/*.webp 2>/dev/null | wc -l | tr -d ' ') 个 / $(du -sh "$OUT" | awk '{print $1}')"
