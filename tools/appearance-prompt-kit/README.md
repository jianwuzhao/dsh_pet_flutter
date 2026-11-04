# 形象素材包提示词工具（appearance-prompt-kit）

本项目形象演化的视觉落地遵循上游 [dsh-pet 的 MAKE-YOUR-OWN-PET.md](https://github.com/PC2005-cloud/dsh-pet/blob/main/MAKE-YOUR-OWN-PET.md)
路线：**用提示词重新生成整套动画素材，运行时零滤镜**。本目录提供变体
提示词的组合工具；App 侧的装载机制见 `assets/appearance/registry.json`
与 `lib/features/pet/render/wardrobe.dart`。

## 目录

- `prefix.md` —— 通用前缀，逐字移植自上游
  `prompts/桌面宠物 10 秒动作提示词.md` 的「通用前缀」一节（内容版权归
  上游仓库；画幅/绿幕/首尾帧约束是素材链能跑通的前提，勿改）
- `variants.json` —— 变体角色修饰表：配色（人格演化）与装扮（情境换装），
  变体 id 必须与 `AppearancePalette.name` / 装扮名完全一致
- `compose.dart` —— 组合器：上游动作提示词 + 变体修饰 → 每动作一段完整提示词
- `refs/` —— 变体角色参考图目录（自建）：参考图需自行用生图工具按
  variants.json 的角色描述产出后放入，喂给视频生成工具保证跨动作一致性

## 全流程

1. **下载动作提示词**：上游仓库 `prompts/桌面宠物 10 秒动作提示词.md`
   （本仓库不搬运全文），存到任意本地路径。
2. **组合变体提示词**（仓库根目录执行）：
   ```sh
   dart tools/appearance-prompt-kit/compose.dart \
     --variant rain \
     --actions "/path/to/桌面宠物 10 秒动作提示词.md"
   # 产物：build/appearance-prompts/rain/<动作名>.md + INDEX.md 检查单
   ```
   `--all` 一次产出 variants.json 里的全部变体。趋势装扮（`trend-` 前缀）
   接受提案后，在 variants.json 照模板加一档再组合即可。
3. **生成视频**：用豆包 / 可灵 / Runway 等按提示词逐段生成 10 秒 16:9
   绿幕视频（参考图用 `refs/<变体>.png`；生成要求以上游
   MAKE-YOUR-OWN-PET.md 为准）。逐段过 INDEX.md 检查单。
4. **素材链转码**：按上游流程抠绿幕 → 归一化 → 出透明 webm，再按本项目
   `tools/convert_assets.sh` 的帧抽取 + img2webp 转成 320×180 动画 webp。
5. **落位**：产物放 `assets/appearance/<变体>/<动作名>.webp`（动作名与
   默认包 `assets/animations/` 完全一致，含生僻名如「点击回应-开心跃动」），
   并在 `pubspec.yaml` 增加一行 `- assets/appearance/<变体>/`。
6. **登记**：`assets/appearance/registry.json` 加
   `"<变体>": {"names": ["待机呼吸休闲", ...]}`，重启 App。

## 回退语义（设计约束）

- 衣橱不认识的变体、包里缺的动作 → 自动回退默认动画包（原版立绘）。
  宁可暂时「没换装」，也不用滤镜假装换装——这是本机制的底线。
- 只生成部分动作即可先登记上线（部分包），缺失动作自然回退。
- 装扮包优先于配色包：穿雨衣时优先显示雨衣素材，雨天没有雨衣包则
  显示当前配色时代的立绘。
