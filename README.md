# 大肥鱼助手

[简体中文](README.md) | [English](README.en.md)（英文版内容更新滞后）

桌面 AI 宠物助手：以桌宠形态常驻桌面，具备**人格表达、长期记忆、反馈学习**，并能把任务联动到本机 AI 软件。

> 仓库包名仍为 `dsh_pet_flutter`，这是历史标识；产品名统一为「大肥鱼助手」。

## 功能概览

| 模块 | 能力 |
|---|---|
| 人格与表达 | 人格 DNA（称呼/语气/底线）、情绪三维（效价·唤醒·亲密度）、五态状态机、主动关心与打扰预算、动画与气泡表达 |
| 记忆 | 偏好/事实/待办/事件四类；LLM 抽取的记忆先进入待确认队列，用户**接受**才生效、**拒绝**即丢弃；支持查看/纠正/遗忘/导出 |
| 学习治理 | 反馈只走**接受/拒绝**语义（含附纠正），无 👍/👎 评分；样本门禁、策略提案、版本快照与回滚、自动回滚；身份/价值观/隐私/打扰上限/人格底线为保护字段，永不被自动改写 |
| 能力探测与联动 | Trae CN（桌面桥）、ChatGPT（官方 API）的只读可用性探测；输入可投递到当前关联软件并接收状态回显 |
| 模型编排 | OpenAI 兼容 / DeepSeek 官方 API / 本地 Ollama / Trae 转发桥，固定降级链；三档思考深度（fast / balanced / deep）映射到各后端的原生参数 |
| 桌宠本体 | 透明置顶窗口、帧动画、物理漫游与拖拽、命中区外点击穿透、macOS 托盘、全局快捷键 |

## 架构分层

| 层 | 目录 | 职责 | 状态 |
|---|---|---|---|
| 应用装配 | `lib/app` | 组装各层、舞台渲染、运行时内核 | 已落地 |
| 自主运行内核 | `lib/autonomy` | 目标/计划、调度、预算、断点恢复、可中断 | 规划中 |
| 模型编排 | `lib/orchestration` | 多 provider 选路、思考档位、用量计量 | 部分落地（档位定义在 `lib/ai/thinking_tier.dart`） |
| AI 能力 | `lib/ai` | provider 实现、降级路由、会话上下文组装 | 已落地 |
| 人格与表达 | `lib/persona` | 人格 DNA、情绪状态机、记忆库、表达层、本地档案仓库 | 已落地 |
| 学习治理 | `lib/learning` | 反馈采集、评估门禁、策略版本与回滚 | 已落地 |
| 互操作 | `lib/interop` | 能力契约、注册表与探测、运行进度事件 | 已落地（只探测，不发起任务） |
| 交互网关 | `lib/gateway` | 统一输入入口、隐私门禁、全局热键 | 已落地 |

依赖方向：`app → autonomy → orchestration → ai`，`autonomy → interop → gateway`；`persona` 与 `learning` 只被上层单向依赖，下层不反向引用上层。

## 目录结构

```
lib/
  app/            装配、舞台、运行时内核（AssistantKernel）
  ai/             LLM provider（OpenAI 兼容 / DeepSeek / Ollama / Trae 桥）、路由、会话服务
  autonomy/       自主运行内核（规划中）
  orchestration/  模型编排（规划中，思考档位暂在 ai/thinking_tier.dart）
  gateway/        统一输入入口、隐私权限中心、全局快捷键
  interop/        能力适配契约、注册表、探测适配器、run.progress 事件
  learning/       反馈采集、评估门禁、策略版本治理
  persona/        人格 DNA、情绪状态机、记忆库、表达层、档案仓库
  core/           jsonc 配置、路径、单实例、Result 类型
  platform/       原生通道：窗口穿透/光标/前台应用/正文读取/输入注入/托盘/热键
  features/
    pet/          物理、漫游、姿态机、精灵渲染、命中测试
    linkage/      适配器注册表、BridgeHub、Dispatcher、事件服务、状态聚合
    chat/         输入面板（外部软件转发 / 内置对话两种模式）
    bubble/       气泡与主动关心的关闭入口
    menu/         右键菜单与动作选择器
    settings/     设置页（联动 / 大脑 / 隐私 / 情绪 / 记忆 / 学习）
tools/            petctl.sh、资源抓取与转换、manifest 生成、Trae skill 安装
trae-extension/   Trae CN 桥扩展
vendor/           上游 dsh-pet 动画源文件（含原始许可）
assets/           动画、表情包、字体、默认配置
```

## 快速开始

环境：Flutter（含 macOS 桌面支持）、Xcode 命令行工具；macOS 12+。

```bash
flutter pub get
flutter run -d macos            # 开发运行
flutter build macos --release   # 发布构建
```

**配置位置**

- 默认配置：`assets/config.default.jsonc`（随包分发，只读参考）
- 用户配置：`~/.dsh_pet_flutter/config.jsonc`（整段覆盖对应字段，可只写需要改的部分）
- 运行期数据：`~/.dsh_pet_flutter/`（`token`、`logs/`、`profile/`、`memory/`、`learning/`）

**填写 API Key**

右键宠物 → 设置 → 「大脑」：选择提供者（`OpenAI 兼容` / `DeepSeek 官方 API` / `本地 Ollama`）→ 填 Base URL 与模型 → 填 API Key → 保存。

- Key 优先写入系统安全存储（Keychain）；不可用时回退到 `~/.dsh_pet_flutter/ai_key`（权限 0600）
- DeepSeek 的 Base URL 填 `https://api.deepseek.com`，模型按官方当前型号填写
- 选择「关闭」时不会调用任何大模型，输入只转发到关联软件

**辅助功能授权**：macOS 需在「系统设置 › 隐私与安全性 › 辅助功能」中勾选本应用，否则无法跨应用投递与读取前台应用。

## 本地接口

事件服务只监听 `127.0.0.1:7341`（端口见配置 `linkage.eventServer.port`），除 `/health` 外都需要 `Authorization: Bearer <token>`；token 在 `~/.dsh_pet_flutter/token`。

### `GET /health`

```bash
curl http://127.0.0.1:7341/health
# {"ok":true,"port":7341}
```

### `POST /v2/chat`

```bash
TOKEN=$(cat ~/.dsh_pet_flutter/token)
curl -s -X POST http://127.0.0.1:7341/v2/chat \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"text":"今天适合写点什么？"}'
# 成功：{"ok":true,"reply":"...","reason":"","degraded":false,"sentiment":"positive"}
# 失败：{"ok":false,"reply":"","reason":"[ai.timeout] ...","degraded":false}
```

### `POST /event`

沿用统一事件信封（`source / type / state / text / ts`）。普通状态事件：

```bash
curl -s -X POST http://127.0.0.1:7341/event \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{"source":"generic","type":"status","state":"success","text":"任务完成"}'
```

运行进度事件 `type=run.progress` 额外带 `runId / phase / step / totalSteps`：

```bash
curl -s -X POST http://127.0.0.1:7341/event \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{"source":"dafishu","type":"run.progress","runId":"r-1","phase":"act","step":2,"totalSteps":5,"text":"正在修改文件"}'
# {"ok":true,"accepted":true}    # 被节流丢弃时为 accepted:false
```

- `phase` ∈ `plan / act / observe / wait_approval / done / failed / cancelled`
- 节流：同一 `runId` 同一 `phase` 至少间隔 5 秒；阶段变更与结局（`done` / `failed` / `cancelled` / `wait_approval`）必发；单次运行最多 40 条进度，超出后只保留阶段变更
- 缺少 `runId` 或非法 `phase` 返回 400

### `GET /bridge/state`

```bash
curl -s "http://127.0.0.1:7341/bridge/state" -H "Authorization: Bearer $TOKEN"
# {"ok":true,"adapters":{},"pendingAcks":0}
```

### petctl CLI

```bash
tools/petctl.sh health                  # 是否在跑
tools/petctl.sh status thinking 正在思考  # thinking|working|result|waiting|success|error
tools/petctl.sh say 你好                 # 只冒泡，不改状态
tools/petctl.sh dispatch 帮我写个函数     # 投递到当前关联软件（会真的外发，需人工验证）
tools/petctl.sh bridge                  # 桥接诊断
```

## 开发约定

```bash
flutter analyze
flutter test --concurrency=1   # 必须串行：部分拖拽用例并发时会抖动
```

- 小步提交：每次改动保持 analyze 0 警告、全量测试全绿
- 文件内上半部分 UI 布局、下半部分业务逻辑；命名用描述性英文 snake_case，注释说明「为什么」
- 本地数据原子写（临时文件 + rename），失败返回结构化 `Result`，不静默回退
- 反馈一律采用「接受/拒绝」语义，不新增评分式按钮

**命名兼容（有意保留旧值，不要改）**

| 标识 | 保留值 | 原因 |
|---|---|---|
| Dart 包名 | `dsh_pet_flutter` | 全部 import 与测试依赖；改名无用户收益 |
| macOS bundle id | `com.dshpet.dsh_pet_flutter` | 改了会被系统当成新应用，授权与设置全部重置 |
| 数据目录 | `~/.dsh_pet_flutter` | 改名等于丢失用户配置、记忆与反馈流水 |
| 原生通道 | `dsh_pet/*` | 与原生实现和外部脚本的既有契约 |
| Key 存储键 | `dsh_pet_flutter.ai.key` | 改则已存 API Key 失效 |

## 已知限制

1. macOS「关于本应用」菜单仍显示 `dsh_pet_flutter`（系统取可执行名，改 `PRODUCT_NAME` 会让构建产物改名，暂未处理）
2. Android 触摸端的气泡关闭钮点不到：原生命中区只覆盖宠物本体，桌面端不受影响
3. `dispatch` 会真的向外部软件发送消息，自动化回归未覆盖，需人工验证
4. 三级（知识检索）与四级（参数微调）学习未开放，门禁会直接拒绝
5. 自主运行内核与多模型编排仍处于规划阶段，当前只有能力探测与思考档位定义

## 平台

| 平台 | 状态 |
|---|---|
| macOS | 主要支持平台，功能完整 |
| Windows | 已有原生通道实现（窗口/托盘/光标），尚未完整验收 |
| Android | 已有悬浮窗与引导页，触摸端存在上述已知限制 |

## 许可证

个人使用免费，**禁止商业使用**，商业授权请联系作者，详见 [LICENSE](LICENSE)。

动画与配置素材来自上游 dsh-pet 项目（PC2005-cloud，MIT），遵循其原始许可，见 [vendor/LICENSE-dsh-pet.txt](vendor/LICENSE-dsh-pet.txt)。

## 赞助

如果这个项目对你有帮助，欢迎请作者喝杯咖啡～

| 支付宝 | 微信 |
|:---:|:---:|
| ![支付宝](docs/sponsor/zfb.jpg) | ![微信](docs/sponsor/wx.png) |
