#!/usr/bin/env bash
# 桌宠 CLI：把状态/思考推给宠物，或把一段话投递到当前关联的 AI 软件。
# token 与端口都从桌宠自己写的约定位置读，Trae skill 与自动化脚本共用同一入口。
set -euo pipefail

ROOT="${DSH_PET_HOME:-$HOME/.dsh_pet_flutter}"
PORT="${DSH_PET_PORT:-7341}"
TOKEN_FILE="$ROOT/token"
BASE="http://127.0.0.1:$PORT"

die() {
  echo "petctl: $*" >&2
  exit 1
}

[[ -f "$TOKEN_FILE" ]] || die "找不到 token：$TOKEN_FILE（桌宠启动过吗？）"
TOKEN="$(cat "$TOKEN_FILE")"
AUTH=(-H "Authorization: Bearer $TOKEN")

rest() {
  curl -fsS -m 8 "${AUTH[@]}" "$@"
}

post_json() {
  rest -X POST "$1" -H 'Content-Type: application/json' -d "$2" >/dev/null
}

usage() {
  cat <<'EOF'
用法：petctl <命令> [参数]

  health                      桌宠是否在跑
  event '<json>'              任意 AssistantEvent（见 lib/features/linkage/status/assistant_event.dart）
  status <state> [文本]       快捷状态：thinking|working|result|waiting|success|error
  say <文本>                  只冒泡提示，不改状态
  dispatch <文本>             把一段话投递到当前关联软件，stdout 打印原因
  bridge                      桥接诊断：Trae 扩展是否在轮询、队列与回执状态
EOF
}

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift

case "$cmd" in
  health)
    rest "$BASE/health"
    echo
    ;;
  event)
    [[ $# -ge 1 ]] || die "用法：petctl event '<json>'"
    post_json "$BASE/event" "$1"
    echo "已推送"
    ;;
  status)
    [[ $# -ge 1 ]] || die "用法：petctl status <state> [文本]"
    state="$1"
    text="${2:-}"
    payload=$(printf '{"source":"generic","type":"status","state":"%s","text":"%s"}' "$state" "$text")
    post_json "$BASE/event" "$payload"
    echo "已推送 $state"
    ;;
  say)
    [[ $# -ge 1 ]] || die "用法：petctl say <文本>"
    payload=$(printf '{"source":"generic","type":"notify","text":"%s"}' "$1")
    post_json "$BASE/event" "$payload"
    echo "已冒泡"
    ;;
  dispatch)
    [[ $# -ge 1 ]] || die "用法：petctl dispatch <文本>"
    payload=$(printf '{"text":"%s"}' "$1")
    rest -X POST "$BASE/dispatch" -H 'Content-Type: application/json' -d "$payload"
    echo
    ;;
  bridge)
    rest "$BASE/bridge/state"
    echo
    ;;
  help | -h | --help)
    usage
    ;;
  *)
    usage
    die "未知命令：$cmd"
    ;;
esac
