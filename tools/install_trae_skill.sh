#!/usr/bin/env bash
# 把「把工作状态推给桌宠」的 skill 装进 Trae CN：
# 装完后 Trae 在回答过程中会主动调用 petctl 推 thinking / 状态 / 终态，
# 桌宠因此能显示“正在想什么”，而不只是靠前台窗口猜测。
set -euo pipefail

SKILL_DIR="${TRAE_SKILLS_DIR:-$HOME/.trae-cn/skills}/pet-broadcast"
PETCTL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/petctl.sh"

controller() {
  mkdir -p "$SKILL_DIR"
  cat >"$SKILL_DIR/SKILL.md" <<EOF
---
name: pet-broadcast
description: 把当前工作状态与思考摘要推给桌面宠物 dsh_pet_flutter，让宠物显示正在做什么。开始动手、需要用户确认、完成或失败时使用。
---

# 桌宠广播

桌宠在本机 127.0.0.1 上监听事件端口，鉴权 token 存在 \`~/.dsh_pet_flutter/token\`。
统一用下面的 CLI 推送（脚本会自己读 token）：

\`$PETCTL\`

## 何时推什么

| 时机 | 命令 |
|---|---|
| 开始分析/规划 | \`petctl status thinking "正在读代码"\` |
| 正在改文件、跑命令 | \`petctl status working "修改 xxx.dart"\` |
| 需要用户确认 | \`petctl status waiting "等待确认：是否继续？"\` |
| 有中间结论 | \`petctl status result "已定位到 xxx"\` |
| 全部完成 | \`petctl status success "已完成"\` |
| 出错 | \`petctl status error "构建失败：... "\` |
| 只想说一句话 | \`petctl say "已经帮你保存好了"\` |

## 规则

- 只在状态真的变了才推，避免刷屏；同一状态不要重复推。
- 文本简短（<= 30 字），不要贴代码或长日志。
- 推送失败（返回非 0）说明桌宠没在跑，直接忽略，不要因此中断任务。
EOF
  chmod +x "$PETCTL" 2>/dev/null || true
  echo "已安装：$SKILL_DIR/SKILL.md"
  echo "CLI：$PETCTL"
}

controller
