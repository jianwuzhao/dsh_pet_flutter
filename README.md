# dsh_pet_flutter

[简体中文](README.md) | [English](README.en.md)

## 项目说明

dsh-pet 的 Flutter 跨平台桌宠：透明置顶窗口 + 帧动画 + 本地事件服务，可与 Trae CN / ChatGPT / WorkBuddy 等 AI 软件联动。目标是升级为"有自己大脑的本地优先个人助手"（交互网关 → AI 能力 → 个性化 → 学习治理，四层核心架构）。

核心特性：

- **桌宠本体**：透明无边框置顶窗口、100+ 帧动画、物理漫游与拖拽、命中区域外点击穿透，不影响桌面操作
- **交互**：双击弹出输入面板、右键菜单、气泡提示（状态/思考/表情包）
- **联动**：本地事件服务（HTTP 7341 端口 + token 鉴权）接收 AI 软件状态推送；输入可投递到当前关联软件（Trae 扩展桥）
- **macOS 托盘**：常驻菜单栏，显示/隐藏、穿透开关、退出；辅助功能授权检测
- **工具链**：petctl CLI、资源抓取/转换脚本、Trae skill 安装器

本地数据目录：`~/.dsh_pet_flutter/`（config.jsonc、token、logs/）。

## 安装使用说明

### macOS（已支持）

```bash
flutter pub get
flutter run -d macos          # 开发运行
flutter test                  # 全量测试
flutter build macos --release # 发布构建
```

已在 `DebugProfile.entitlements` / `Release.entitlements` 关闭 App Sandbox；需在系统设置中授予"辅助功能"权限以支持跨应用联动。

### Windows（待支持）

> 原生窗口穿透/托盘/输入注入尚未实现，安装说明待补充。

### Web（待支持）

> 平台降级验证尚未完成，安装说明待补充。

### Android（待支持）

> 平台降级验证尚未完成，安装说明待补充。

### petctl CLI

桌宠启动后，用 `tools/petctl.sh` 推送状态或投递文本：

```bash
tools/petctl.sh health                  # 桌宠是否在跑
tools/petctl.sh status thinking 正在思考  # thinking|working|result|waiting|success|error
tools/petctl.sh say 你好                 # 只冒泡，不改状态
tools/petctl.sh dispatch 帮我写个函数     # 投递到当前关联软件
tools/petctl.sh bridge                  # Trae 扩展桥诊断
```

### Trae CN 扩展

将 `trae-extension/` 作为扩展目录加载到 Trae CN（或用 `tools/install_trae_skill.sh` 安装 pet-broadcast skill），重载窗口后即可接收桌宠投递。

## 目录结构

```
lib/
  app/          # 装配与舞台（pet_app / pet_stage / flyout_layout）
  core/         # 基础设施：jsonc 配置、路径、单实例、Result
  platform/     # 原生能力通道：穿透/光标/前台应用/正文读取/输入注入/托盘
  features/
    pet/        # 物理/漫游/姿态机/精灵渲染/命中穿透
    linkage/    # 适配器注册表、BridgeHub、Dispatcher、事件服务、状态聚合
    ai/         # 现有 LLM 配置（四层架构 M2 将扩展为 ai/ 能力层）
    chat/       # 输入面板（当前为纯转发）
    bubble/     # 气泡
    menu/       # 右键菜单与动作选择器
    settings/   # 设置页
tools/          # petctl.sh、资源脚本、gen_manifest.dart、install_trae_skill.sh
trae-extension/ # Trae CN 桥扩展（dsh-pet-bridge）
vendor/         # 上游 dsh-pet 动画源文件（webm + config，含 LICENSE）
assets/         # 转换后的 webp 动画、表情包、字体、默认配置
docs/           # 文档资源（赞助二维码等）
```

## 剩余工作

| 功能项 | 状态 | 更新时间 | 贡献者 |
|---|---|---|---|
| Windows 平台（穿透/托盘/输入注入） | 待支持 | 2026-10-30 | zhaodaye2022 |
| Web 平台降级验证 | 待支持 | 2026-10-30 | zhaodaye2022 |
| Android 平台降级验证 | 待支持 | 2026-10-30 | zhaodaye2022 |
| M1 基础设施与配置扩展（本地档案仓库） | 未开始 | 2026-10-30 | zhaodaye2022 |
| M2 AI 能力层（三路 LLM 提供者与降级链） | 未开始 | 2026-10-30 | zhaodaye2022 |
| M3 交互网关层（统一入口/隐私中心/全局热键） | 未开始 | 2026-10-30 | zhaodaye2022 |
| M4 个性化层·情绪闭环与打扰预算 | 未开始 | 2026-10-30 | zhaodaye2022 |
| M5 个性化层·记忆库与会话服务 | 未开始 | 2026-10-30 | zhaodaye2022 |
| M6 学习治理层（反馈闭环/策略版本治理） | 未开始 | 2026-10-30 | zhaodaye2022 |
| M7 收尾验证（集成回归/内存回归） | 未开始 | 2026-10-30 | zhaodaye2022 |

明确暂缓：ASR/TTS（仅留接口）、检索/知识学习（仅留接口）、参数学习、流式回复、专注模式自动检测。

## 赞助

如果这个项目对你有帮助，欢迎请作者喝杯咖啡～

| 支付宝 | 微信 |
|:---:|:---:|
| ![支付宝](docs/sponsor/zfb.jpg) | ![微信](docs/sponsor/wx.png) |

## 许可证

个人使用免费，**禁止商业使用**，商业授权请联系作者，详见 [LICENSE](LICENSE)。

动画与配置素材来自上游 dsh-pet 项目（PC2005-cloud，MIT），遵循其原始许可，见 [vendor/LICENSE-dsh-pet.txt](vendor/LICENSE-dsh-pet.txt)。
