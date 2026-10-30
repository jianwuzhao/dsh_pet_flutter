#!/usr/bin/env bash
# 从 dsh-pet 发布包（MIT）一次性拷贝桌宠素材到本地工程。
# 为什么用 vendor 目录：素材是上游产物，保留原始文件与出处，便于重新转码而不污染 assets/。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${DSH_PET_SRC:-$HOME/Library/pnpm/store/v11/links/@/dsh-pet/0.3.8/3b9335191a533b572172557de7c18dc895e5a2cd3d9ced00c12c7ea2aeee56d7/node_modules/dsh-pet}"

if [ ! -d "$SRC/assets" ]; then
  echo "找不到 dsh-pet 素材目录: $SRC" >&2
  echo "请用 DSH_PET_SRC 指定包根目录" >&2
  exit 1
fi

mkdir -p "$ROOT/vendor" "$ROOT/assets/fonts" "$ROOT/assets/memes" "$ROOT/assets/pic"

echo "→ vendor/webm（转码源，不在 flutter assets 里）"
cp -R "$SRC/assets/webm" "$ROOT/vendor/webm"

echo "→ assets/fonts assets/memes assets/pic"
cp "$SRC/assets/fonts/"* "$ROOT/assets/fonts/" 2>/dev/null || true
cp "$SRC/assets/memes/"* "$ROOT/assets/memes/" 2>/dev/null || true
cp "$SRC/assets/pic/"* "$ROOT/assets/pic/" 2>/dev/null || true

echo "→ vendor/config.jsonc（动画池与权重来源）"
cp "$SRC/assets/config.jsonc" "$ROOT/vendor/config.jsonc"
cp "$SRC/LICENSE" "$ROOT/vendor/LICENSE-dsh-pet.txt"

echo "完成：$(ls "$ROOT/vendor/webm" | wc -l | tr -d ' ') 个 webm 源文件"
