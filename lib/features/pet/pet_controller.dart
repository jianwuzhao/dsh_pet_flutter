/// 宠物调度层：Ticker 驱动物理 / 漫游 / 动画链，并把命中区结果交给平台层翻转穿透。
///
/// UI 只读本文件的 ValueNotifier；姿态抽签、状态覆盖、命中判定等业务都在这里，
/// Widget 侧不承担逻辑（见 pet_stage.dart）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../core/config/animation_manifest.dart';
import '../../core/config/app_config.dart';
import '../../platform/pet_platform.dart';
import '../linkage/status/assistant_event.dart';
import 'behavior/physics.dart';
import 'behavior/pose_machine.dart';
import 'behavior/roaming.dart';
import 'hit_test.dart';
import 'render/sprite_player.dart';

enum PetPanel { menu, chat, settings, actions }

class BubbleState {
  const BubbleState({
    required this.text,
    this.thinking = false,
    this.source = '',
    this.meme,
  });

  final String text;
  final bool thinking;
  final String source;

  /// 可选表情包资源（assets/memes/xxx.png）；碎碎念时随机配一张。
  final String? meme;
}

enum _Mode { pose, drag, status }

class PetController {
  PetController({
    required this.pet,
    required this.physics,
    required this.manifest,
    required this.platform,
    this.initialPosition,
  }) : _poses = PoseMachine(manifest),
       petSize = Size(pet.size, pet.size * manifest.height / manifest.width),
       position = ValueNotifier<Offset>(Offset.zero) {
    _body = PetBody(position: Offset.zero, size: petSize, params: physics);
    _ticker = Ticker(_onTick);
  }

  final PetConfig pet;
  final PhysicsParams physics;
  final AnimationManifest manifest;
  final PetPlatform platform;
  final Size petSize;

  /// 上次退出时的落点（窗口本地坐标）；为 null 时出生在当前屏底部中央。
  final Offset? initialPosition;

  /// 宠物左上角（窗口逻辑坐标）。
  final ValueNotifier<Offset> position;
  final ValueNotifier<BubbleState?> bubble = ValueNotifier<BubbleState?>(null);
  final ValueNotifier<PetPanel?> panel = ValueNotifier<PetPanel?>(null);

  /// 每帧自增，供 CustomPainter 标记重绘。
  final ValueNotifier<int> repaint = ValueNotifier<int>(0);

  /// 是否正在按住拖动：UI 用它切换抓手光标，命中逻辑用它在拖动期间保持可交互。
  final ValueNotifier<bool> dragging = ValueNotifier<bool>(false);

  /// Q 弹挤压比例（x 横向、y 纵向），以脚底为锚点缩放。
  /// 上游点击/落地都有“压扁 55% → easeOutBack 回弹”，这是桌宠手感的一半。
  final ValueNotifier<Offset> squash = ValueNotifier<Offset>(
    const Offset(1, 1),
  );

  final PoseMachine _poses;
  final math.Random _random = math.Random();
  late final PetBody _body;
  late final Ticker _ticker;

  Size? _viewport;
  Duration? _lastElapsed;
  bool _poseFinishedHandled = false;

  SpritePlayer? _player;
  String? _currentAnimation;
  _Mode _mode = _Mode.pose;

  MovePlan? _movePlan;
  double _moveStartX = 0;

  ui.Image? _fadeFrom;
  double _fadeElapsed = 1;

  Offset? _menuAnchor;

  /// 拖拽期间的活动屏幕：以指针所在屏幕为准，而不是以身体中心为准。
  /// 否则身体中心还没越过屏幕边缘时就会被旧屏幕钳住，永远拖不到另一块屏。
  Rect? _dragDomain;
  bool _interactive = false;
  Offset? _lastCursor;
  bool _cursorLogged = false;

  StatusSnapshot? _statusSnapshot;

  Timer? _poseTimer;
  Timer? _bubbleTimer;
  StreamSubscription<PetPointer>? _cursorSubscription;
  Offset _grabOffset = Offset.zero;
  Stopwatch? _dragWatch;
  final ThrowSampler _sampler = ThrowSampler();

  /// 快速甩出后、落地前的状态：物理继续跑，姿态保持“被拖拽悬空反馈”，
  /// 直到落地才恢复基础动画。慢速松手不会进入这里（直接钉住）。
  bool _thrown = false;

  /// 换屏滞回：越过屏幕边缘不足这么多逻辑像素时保持当前屏。
  /// 没有它，窗口刚换到新屏时 1px 的坐标抖动就会判回旧屏，来回切窗，
  /// 宠物在边缘看起来就是“闪一下就消失”。
  static const double _screenSwitchMargin = 28;

  /// 换屏进行中左键先松了：等换屏结果回来再收尾，避免半拖拽态卡死。
  bool _pendingRelease = false;

  static const double _squashDuration = 0.46;
  double _squashElapsed = 1;
  double _squashIntensity = 0;
  bool _wasOnGround = true;

  /// 单屏窗口当前所在的屏幕下标（原生 NSScreen.screens 顺序）。
  int _activeScreenIndex = 0;

  /// 全局指针左键状态：跨屏换窗后 pan 可能被取消，靠它继续拖动/收尾。
  bool _pointerDown = false;

  /// pan 被系统打断后，是否已改由全局指针流驱动拖动。
  bool _pointerDrivenDrag = false;

  /// 正在请求原生换屏；期间忽略旧的本地坐标事件。
  bool _screenSwitching = false;

  /// 换屏后屏幕列表尚未重新拉取：这期间只能用新窗口尺寸做本地判定，
  /// 否则旧列表里“原活动屏”的矩形会和新窗口矩形重叠，判定会来回跳屏。
  bool _screensDirty = false;

  SpritePlayer? get player => _player;
  ui.Image? get fadeFrom => _fadeFrom;
  int get facing => _poses.facing;
  double get fadeProgress =>
      _fadeFrom == null ? 1 : math.min(1, _fadeElapsed / 0.16);
  Offset? get menuAnchor => _menuAnchor;

  /// 宠物绘制矩形（窗口本地坐标）：气泡 / 菜单 / 面板都按它定位。
  Rect get petRect => _body.rect;

  /// 宠物当前所在屏幕（窗口本地坐标）；未知视口时退化为整个视口。
  Rect get activeScreen => _screensDirty
      ? (_dragDomain ?? _fallbackScreen)
      : (_screenNear(petRect.center) ?? _fallbackScreen);

  /// 屏幕列表（主屏在前）：并集窗口里有“两屏之间”没有显示器的死区，
  /// 宠物必须始终被钳制在最近的真实屏幕内，否则会消失在屏缝里。
  List<Rect>? _screens;

  void setScreens(List<Rect> screens) {
    if (screens.isEmpty) return;
    _screens = screens;
    _screensDirty = false;
    _syncActiveScreenIndex();
    if (_viewport != null) {
      if (_body.dragging) {
        _clampDragBody();
      } else {
        _clampBody();
      }
      _syncInteractive();
    }
  }

  /// 活动屏 = 当前窗口本身，在本地坐标里恒为 (0,0,viewport)。
  /// 换屏 / 热插拔后用它把下标校正回来，避免下一次换屏算错方向。
  void _syncActiveScreenIndex() {
    final viewport = _viewport;
    final screens = _screens;
    if (viewport == null || screens == null) return;
    for (var i = 0; i < screens.length; i++) {
      final screen = screens[i];
      if (screen.left.abs() < 2 &&
          screen.top.abs() < 2 &&
          (screen.width - viewport.width).abs() < 2 &&
          (screen.height - viewport.height).abs() < 2) {
        _activeScreenIndex = i;
        return;
      }
    }
  }

  Rect get _fallbackScreen =>
      _viewport == null ? Rect.zero : Offset.zero & _viewport!;

  /// 指针所在屏幕；落在两屏之间的死区时返回 null（调用方沿用上一次）。
  Rect? _screenAt(Offset point) {
    final screens = _screens;
    if (screens == null || screens.isEmpty) return null;
    for (final screen in screens) {
      if (screen.contains(point)) return screen;
    }
    return null;
  }

  /// 离给定点最近的屏幕：拖动/落屏时用来处理无屏幕的死区。
  Rect? _screenNear(Offset point) {
    final screens = _screens;
    if (screens == null || screens.isEmpty) return null;
    Rect? nearest;
    var best = double.infinity;
    for (final screen in screens) {
      final distance = (screen.center - point).distanceSquared;
      if (distance < best) {
        best = distance;
        nearest = screen;
      }
    }
    return nearest;
  }

  /// 宠物当前的活动域：离身体中心最近的真实屏幕（未知时退化为整个视口）。
  Rect get _domain => _screensDirty
      ? (_dragDomain ?? _fallbackScreen)
      : (_screenNear(petRect.center) ?? _fallbackScreen);

  /// 拖拽/落地期间以指针屏幕为准，静止姿态以身体所在屏幕为准。
  Rect get _activeDomain => _dragDomain ?? _domain;

  double _maxXIn(Rect domain) =>
      math.max(domain.left, domain.right - petSize.width);
  double _maxYIn(Rect domain) =>
      math.max(domain.top, domain.bottom - petSize.height);

  double get _maxX => _maxXIn(_domain);

  // ---------------------------------------------------------------------------
  // 生命周期与视口
  // ---------------------------------------------------------------------------

  void start() {
    _cursorSubscription = platform.cursor.listen(
      _onPointer,
      onError: (Object error) => debugPrint('[pet] cursor 通道错误：$error'),
      onDone: () => debugPrint('[pet] cursor 通道结束'),
    );
    debugPrint('[pet] 已订阅光标通道');
    _ticker.start();
  }

  /// 桌面端窗口是整块工作区，宠物在窗口内按物理移动。
  void updateViewport(Size size) {
    if (_viewport == size) return;
    final first = _viewport == null;
    _viewport = size;
    _syncActiveScreenIndex();
    if (first) {
      // 出生在主屏（原生侧保证 NSScreen.screens.first 是系统主屏）中央底部。
      // 之前用 NSScreen.main，它会跟着“当前焦点窗口”漂移到外接屏，用户在主屏
      // 上就完全看不到宠物——这是“桌宠不显示”的根因之一。
      final screens = _screens;
      final home = screens != null && _activeScreenIndex < screens.length
          ? screens[_activeScreenIndex]
          : _fallbackScreen;
      final saved = initialPosition;
      _body.position = saved == null
          ? Offset(
              home.left + (home.width - petSize.width) / 2,
              home.bottom - petSize.height,
            )
          : _clampPlacement(saved, home);
      // 自由摆放：出生后也不被重力拉走；拖动会临时取消 pinned，松手再钉住。
      _body.pinned = true;
      _wasOnGround = true;
      position.value = _body.position;
      _rollNext();
      _syncInteractive();
      return;
    }
    if (_body.dragging) {
      _clampDragBody();
    } else {
      _clampBody();
    }
    _syncInteractive();
  }

  void _clampBody([Rect? domain]) {
    final target = domain ?? _activeDomain;
    _body.position = Offset(
      _body.position.dx.clamp(target.left, _maxXIn(target)).toDouble(),
      _body.position.dy.clamp(target.top, _maxYIn(target)).toDouble(),
    );
    position.value = _body.position;
  }

  /// 拖拽定位：左右最多允许半个身体探出屏幕（可以放到屏幕侧边），
  /// 上下仍完整留在屏幕内。比“整只必须完整在屏内”自由，又不会整只丢出屏外。
  Offset _clampPlacement(Offset target, Rect screen) {
    final slack = petSize.width / 2;
    final minX = screen.left - slack;
    final maxX = math.max(minX, screen.right - petSize.width + slack);
    final minY = screen.top;
    final maxY = math.max(minY, screen.bottom - petSize.height);
    return Offset(
      target.dx.clamp(minX, maxX).toDouble(),
      target.dy.clamp(minY, maxY).toDouble(),
    );
  }

  /// 拖拽期间只做摆放钳制，不能按“整只入屏”把宠物从指针下面拽回来。
  void _clampDragBody() {
    _body.position = _clampPlacement(_body.position, _activeDomain);
    position.value = _body.position;
  }

  // ---------------------------------------------------------------------------
  // 每帧推进
  // ---------------------------------------------------------------------------

  void _onTick(Duration elapsed) {
    final previous = _lastElapsed;
    _lastElapsed = elapsed;
    if (previous == null) return;
    final dt = math.min((elapsed - previous).inMicroseconds / 1e6, 0.05);
    if (dt <= 0) return;
    final viewport = _viewport;
    if (viewport == null) return;

    _body.step(dt, _activeDomain);
    if (_body.dragging) _clampDragBody();

    // 落地 Q 弹：从空中第一次触地时按冲击速度压扁，轻落 0.45 ~ 重砸 1.0。
    final domain = _activeDomain;
    final onGround = _body.position.dy >= _maxYIn(domain) - 0.5;
    if (onGround && !_wasOnGround && !_body.dragging && !_body.pinned) {
      final impact = _body.velocity.dy.abs() / 1200;
      _triggerSquash(impact.clamp(0.45, 1.0));
    }
    _wasOnGround = onGround;
    _advanceSquash(dt);

    _applyRoaming();

    final player = _player;
    player?.advance(Duration(microseconds: (dt * 1e6).round()));
    if (player != null &&
        player.finished &&
        !player.loop &&
        !_poseFinishedHandled) {
      _poseFinishedHandled = true;
      _movePlan = null;
      _scheduleNext(Duration(milliseconds: 250 + _random.nextInt(650)));
    }
    _advanceFade(dt);
    _checkLanding();

    position.value = _body.position;
    repaint.value++;
    // 命中区必须跟着宠物走：光标静止而宠物漫游到它脚下时，原生窗口仍
    // 处于穿透状态，点击会落到桌面上，看起来像“点不到宠物”。
    _syncInteractive();
  }

  void _applyRoaming() {
    final plan = _movePlan;
    final player = _player;
    if (plan == null ||
        player == null ||
        _body.dragging ||
        player.frameCount == 0) {
      return;
    }
    final total = Duration(
      microseconds: (player.frameCount / manifest.fps * 1e6).round(),
    );
    final offset = plan.offsetAt(player.played, total);
    _body.position = Offset(
      (_moveStartX + offset).clamp(_domain.left, _maxX).toDouble(),
      _body.position.dy,
    );
  }

  void _advanceFade(double dt) {
    if (_fadeFrom == null) return;
    _fadeElapsed += dt;
    if (_fadeElapsed >= 0.16) {
      _fadeFrom?.dispose();
      _fadeFrom = null;
      _fadeElapsed = 1;
    }
  }

  /// 甩出后的落地收尾：物理跑到地面且速度足够低时，才把“被拖拽悬空”动画
  /// 换回基础姿态。慢速摆放不会经过这里（松手即钉住、立即恢复）。
  void _checkLanding() {
    if (!_thrown || _body.dragging || _mode != _Mode.drag) return;
    final domain = _activeDomain;
    final onGround = _body.position.dy >= _maxYIn(domain) - 0.5;
    if (!onGround || _body.velocity.distance >= 40) return;
    _thrown = false;
    _body.velocity = Offset.zero;
    _body.pinned = true;
    _dragDomain = null;
    _mode = _Mode.pose;
    _restoreBase();
  }

  // ---------------------------------------------------------------------------
  // 姿态链
  // ---------------------------------------------------------------------------

  void _rollNext() {
    if (_viewport == null) return;
    _poseTimer?.cancel();
    final pick = _poses.rollNext();
    if (pick == null) return;
    _mode = _Mode.pose;
    _beginPose(pick);
  }

  void _beginPose(PosePick pick) {
    _movePlan = null;

    if (pick.kind == PetPoseKind.turn) {
      _poses.facing = -_poses.facing;
    }

    if (pick.kind == PetPoseKind.move) {
      final params = pick.moveParams ?? manifest.moveDefault;
      var direction = _poses.facing;
      if (_body.position.dx <= _domain.left + 2) {
        direction = 1;
      } else if (_body.position.dx >= _maxX - 2) {
        direction = -1;
      }
      _poses.facing = direction;
      _movePlan = planMove(params, petSize: pet.size, facing: direction);
      _moveStartX = _body.position.dx;
    }

    _play(pick.animation, loop: false);
  }

  void _scheduleNext(Duration delay) {
    _poseTimer?.cancel();
    _poseTimer = Timer(delay, () {
      if (_mode == _Mode.drag) return;
      if (_statusSnapshot != null) {
        _playStatus();
      } else {
        _rollNext();
      }
    });
  }

  void _restoreBase() {
    if (_statusSnapshot != null) {
      _playStatus();
    } else {
      _rollNext();
    }
  }

  // ---------------------------------------------------------------------------
  // 状态联动
  // ---------------------------------------------------------------------------

  /// 聚合器只给“最终赢家”，这里负责换成动画档位与气泡。
  void applyStatus(StatusSnapshot? snapshot) {
    _statusSnapshot = snapshot;
    if (!pet.workStatusEnabled) return;

    if (snapshot == null) {
      if (_mode == _Mode.status) {
        _mode = _Mode.pose;
        _rollNext();
      }
      return;
    }

    showBubble(
      snapshot.text,
      thinking: snapshot.state == AssistantStatus.thinking,
      source: snapshot.source,
    );
    if (_mode == _Mode.drag) return;
    _playStatus();
  }

  void _playStatus() {
    final snapshot = _statusSnapshot;
    if (snapshot == null) return;
    final animation = _poses.workStatusAnimation(snapshot.state.index);
    if (animation == null) return;
    _mode = _Mode.status;
    _movePlan = null;
    _play(animation, loop: true);
  }

  // ---------------------------------------------------------------------------
  // 气泡
  // ---------------------------------------------------------------------------

  void showBubble(
    String text, {
    bool thinking = false,
    String source = '',
    String? meme,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    bubble.value = BubbleState(
      text: trimmed,
      thinking: thinking,
      source: source,
      meme: meme,
    );
    _bubbleTimer?.cancel();
    _bubbleTimer = Timer(const Duration(seconds: 7), hideBubble);
  }

  void hideBubble() {
    _bubbleTimer?.cancel();
    _bubbleTimer = null;
    bubble.value = null;
  }

  // ---------------------------------------------------------------------------
  // 交互：点击 / 拖拽 / 菜单 / 面板
  // ---------------------------------------------------------------------------

  void onTapPet() {
    if (panel.value != null) return;
    _triggerSquash(0.85);
    // 甩出途中点一下：放弃“落地恢复拖拽动画”的等待，交给点击动画/物理继续。
    if (_thrown) {
      _thrown = false;
      _dragDomain = null;
      if (_mode == _Mode.drag) {
        _mode = _Mode.pose;
        _restoreBase();
      }
    }
    final name = _poses.pickClick();
    if (name == null) return;
    _mode = _Mode.pose;
    _movePlan = null;
    _play(name, loop: false);
  }

  void onDragStart(Offset pointer) {
    _poseTimer?.cancel();
    _movePlan = null;
    _mode = _Mode.drag;
    _dragDomain = _screenAt(pointer) ?? _screenNear(pointer) ?? _domain;
    _grabOffset = pointer - _body.position;
    _body.beginDrag(_clampPlacement(pointer - _grabOffset, _dragDomain!));
    _pointerDrivenDrag = false;
    _screenSwitching = false;
    _pendingRelease = false;
    _thrown = false;
    _dragWatch = Stopwatch()..start();
    _sampler.clear();
    _sampler.add(Duration.zero, pointer);
    dragging.value = true;
    debugPrint('[pet] 拖拽开始 指针=$pointer 抓取偏移=$_grabOffset');
    // 拖动期间窗口必须持续可交互：指针一定先离开宠物身体再拖动，
    // 如果这时按命中区翻回穿透，macOS 会直接丢掉 mouseDragged，宠物卡住。
    _applyInteractive(true);
    final dragAnimation = manifest.drag.firstOrNull;
    if (dragAnimation != null) _play(dragAnimation, loop: true);
  }

  void onDragUpdate(Offset pointer) {
    // 换屏中或已由全局指针接管时，这帧的本地坐标可能是旧窗口的，直接丢弃。
    if (_screenSwitching || _pointerDrivenDrag) return;
    _body.updateDragTarget(pointer - _grabOffset);
    _sampler.add(_dragWatch?.elapsed ?? Duration.zero, pointer);
  }

  void onDragEnd() {
    debugPrint(
      '[pet] 手势结束 dragging=${_body.dragging} down=$_pointerDown '
      '切换中=$_screenSwitching 指针驱动=$_pointerDrivenDrag',
    );
    if (!_body.dragging) return;
    // 换屏会把 pan 打断成 end；等换屏结果/松手事件来收尾，别在换屏途中结束。
    if (_screenSwitching) return;
    // 左键仍按着（pan 被系统取消但按钮没松）：转全局指针继续拖。
    if (PetPlatform.hasGlobalCursor && _pointerDown) {
      _pointerDrivenDrag = true;
      return;
    }
    _endDrag();
  }

  /// 手势被系统取消（窗口移动、失去跟踪、Esc 等）时也必须收尾，
  /// 但如果左键仍按着且能收到全局指针，就转成指针驱动继续拖，别半路松手。
  void onDragCancel() {
    debugPrint(
      '[pet] 手势取消 dragging=${_body.dragging} down=$_pointerDown '
      '切换中=$_screenSwitching 指针驱动=$_pointerDrivenDrag',
    );
    if (!_body.dragging) return;
    if (_screenSwitching) {
      _pointerDrivenDrag = true;
      if (!_pointerDown) _pendingRelease = true;
      return;
    }
    if (PetPlatform.hasGlobalCursor && _pointerDown) {
      _pointerDrivenDrag = true;
      return;
    }
    _endDrag();
  }

  void _endDrag() {
    if (!_body.dragging) {
      dragging.value = false;
      _pointerDrivenDrag = false;
      _pendingRelease = false;
      return;
    }
    final domain = _activeDomain;
    // 松手前停顿超过 120ms 视为“摆放”，即使上一段移动很快也不甩出。
    final dragNow = _dragWatch?.elapsed ?? Duration.zero;
    final lastSample = _sampler.lastAt;
    final releasedWhileMoving =
        lastSample != null &&
        dragNow - lastSample <= const Duration(milliseconds: 120);
    final velocity = releasedWhileMoving
        ? _sampler.velocity(physics.throwPower)
        : Offset.zero;
    _dragWatch?.stop();
    _dragWatch = null;
    _sampler.clear();
    _pointerDrivenDrag = false;
    _pendingRelease = false;
    dragging.value = false;

    // 快甩：保留“被鼠标拖拽悬空反馈”动画 + 物理抛掷，落地后才恢复基础姿态。
    // 慢放：直接钉在指针最终位置（顶部/任意高度都停得住），立即恢复基础姿态。
    if (velocity.distance >= physics.throwThreshold) {
      _body.endDrag(velocity);
      _thrown = true;
      debugPrint('[pet] 甩出 速度=$velocity');
      position.value = _body.position;
      _refreshInteractive();
      return;
    }

    _thrown = false;
    // 对齐指针的最终位置（弹簧跟手会略微滞后），再钉住：松手后不再掉回地面。
    _body.position = _clampPlacement(_body.dragTarget, domain);
    _body.pin();
    position.value = _body.position;
    debugPrint('[pet] 拖拽结束并钉住 位置=$_body.position');
    _dragDomain = null;
    _mode = _Mode.pose;
    _restoreBase();
    // 松手后穿透立刻回到“跟宠物走”，不再整窗拦截鼠标。
    _refreshInteractive();
  }

  /// 指针落在哪块屏上（包含窗口当前覆盖屏之外的其他屏）。
  ///
  /// 两条防抖：光标还在当前屏内时绝不换屏；越过当前屏边缘不足
  /// [_screenSwitchMargin] 时视为手抖。否则换屏瞬间光标贴在边界上，
  /// 旧屏坐标会把窗口立刻判回去，表现就是宠物在屏边缘反复闪烁/消失。
  int? _screenIndexAt(Offset point) {
    final screens = _screens;
    if (screens == null || screens.isEmpty) return null;
    final active = _activeScreenIndex;
    if (active < 0 || active >= screens.length) return null;
    final activeRect = screens[active];
    if (activeRect.contains(point)) return active;
    // 换屏后新屏幕列表还没回来：旧坐标不可靠，先保持不动，等 setScreens。
    if (_screensDirty) return null;

    final dx = point.dx < activeRect.left
        ? activeRect.left - point.dx
        : (point.dx > activeRect.right ? point.dx - activeRect.right : 0.0);
    final dy = point.dy < activeRect.top
        ? activeRect.top - point.dy
        : (point.dy > activeRect.bottom ? point.dy - activeRect.bottom : 0.0);
    if (math.max(dx, dy) < _screenSwitchMargin) return null;

    for (var i = 0; i < screens.length; i++) {
      if (i != active && screens[i].contains(point)) return i;
    }
    return null;
  }

  /// 把窗口搬到目标屏，并把宠物重新摆到指针下方。
  /// 单屏窗口是“不显示”问题的修复：跨屏用换窗口实现，而不是跨屏铺一个大窗。
  Future<void> _switchToScreen(int index) async {
    if (_screenSwitching || index == _activeScreenIndex) return;
    debugPrint('[pet] 请求换屏 -> $index');
    _screenSwitching = true;
    try {
      final move = await platform
          .moveToScreen(index)
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (move == null) {
        debugPrint('[pet] 换屏失败：无返回');
        return;
      }
      debugPrint(
        '[pet] 换屏完成 index=${move.index} 尺寸=${move.size} 指针=${move.pointer}',
      );
      _activeScreenIndex = move.index;
      final domain = Rect.fromLTWH(0, 0, move.size.width, move.size.height);
      // 新窗口的屏幕本地坐标从 (0,0) 开始；在 setScreens 回来之前先用它钳制。
      _dragDomain = domain;
      _screensDirty = true;
      final target = _clampPlacement(move.pointer - _grabOffset, domain);
      _body.position = target;
      _body.updateDragTarget(target);
      position.value = target;
      // 窗口移动造成的坐标跳变不能计入甩出速度。
      _sampler.clear();
      _sampler.add(_dragWatch?.elapsed ?? Duration.zero, move.pointer);
      if (_body.dragging) {
        _pointerDrivenDrag = true;
      } else {
        // 换屏进行中已经松手：窗口已搬过去，把宠物放到新窗口里即可，不再续拖。
        _dragDomain = null;
      }
    } on Object catch (error) {
      debugPrint('[pet] 换屏失败：$error');
    } finally {
      _screenSwitching = false;
      if (_pendingRelease) {
        _pendingRelease = false;
        if (_body.dragging) _endDrag();
      }
    }
  }

  /// 点击 / 落地 Q 弹：以脚底为锚点先压扁再回弹，强度 0..1。
  void _triggerSquash(double intensity) {
    _squashIntensity = intensity.clamp(0.0, 1.0);
    _squashElapsed = 0;
    _advanceSquash(0);
  }

  void _advanceSquash(double dt) {
    if (_squashElapsed >= _squashDuration) {
      if (squash.value != const Offset(1, 1)) {
        squash.value = const Offset(1, 1);
      }
      return;
    }
    _squashElapsed = math.min(_squashDuration, _squashElapsed + dt);
    final t = (_squashElapsed / _squashDuration).clamp(0.0, 1.0);
    // 阻尼余弦：t=0 立刻压到 55%，随后回弹过冲一次，再收敛到 1。
    final wave = math.cos(t * math.pi * 2.5) * (1 - t);
    squash.value = Offset(
      1 + 0.22 * _squashIntensity * wave,
      1 - 0.45 * _squashIntensity * wave,
    );
  }

  /// 右键“动作”点播：分类里的任意动画（含移动分类的真实行走）。
  /// 与随机链不同，点播不重新抽签、不覆盖当前联动状态；播完自然回到随机链。
  void playAnimation(String name) {
    if (!manifest.names.contains(name)) return;
    _poseTimer?.cancel();
    _movePlan = null;
    _mode = _Mode.pose;
    _thrown = false;
    _dragDomain = null;

    final move = manifest.moves.where((m) => m.name == name).firstOrNull;
    if (move != null) {
      var direction = _poses.facing;
      if (_body.position.dx <= _domain.left + 2) {
        direction = 1;
      } else if (_body.position.dx >= _maxX - 2) {
        direction = -1;
      }
      _poses.facing = direction;
      _movePlan = planMove(move.params, petSize: pet.size, facing: direction);
      _moveStartX = _body.position.dx;
    }

    // 带文字的 noMirror 动画不能镜像播放；朝左时强制转正。
    final noMirror = manifest.categories.any(
      (c) => c.noMirror && c.actions.contains(name),
    );
    if (noMirror) _poses.facing = 1;

    _play(name, loop: false, restart: true);
    closePanel();
  }

  /// 右键“回到初始位置”：回到当前屏幕底部中央，并清掉甩出/拖拽残留状态。
  void resetPosition() {
    final screen = activeScreen;
    _poseTimer?.cancel();
    _movePlan = null;
    _thrown = false;
    _dragDomain = null;
    _body.position = Offset(
      screen.left + (screen.width - petSize.width) / 2,
      screen.bottom - petSize.height,
    );
    _body.pin();
    _wasOnGround = true;
    position.value = _body.position;
    _mode = _Mode.pose;
    _rollNext();
    _triggerSquash(0.9);
    if (panel.value == PetPanel.menu) {
      closeMenu();
    } else {
      closePanel();
    }
    _refreshInteractive();
  }

  void openMenu(Offset anchor) {
    _menuAnchor = anchor;
    panel.value = PetPanel.menu;
    // 菜单打开后整窗都可交互：点击空白处要能收起，而不是把点击透传给桌面。
    _applyInteractive(true);
  }

  void closeMenu() {
    _menuAnchor = null;
    if (panel.value == PetPanel.menu) panel.value = null;
    _refreshInteractive();
  }

  /// 打开需要键盘输入的浮层时，窗口必须临时接管焦点，否则输入框拿不到按键。
  /// 托盘在宠物隐藏时也能唤起面板，所以先把窗口拉上屏再抢焦点。
  void openPanel(PetPanel value) {
    closeMenu();
    panel.value = value;
    unawaited(_presentPanel());
  }

  Future<void> _presentPanel() async {
    try {
      await platform.showWindow();
    } on Object catch (error) {
      debugPrint('[pet] 显示窗口失败：$error');
    }
    _applyInteractive(true);
    try {
      await platform.setFocusable(true);
    } on Object catch (error) {
      debugPrint('[pet] 聚焦窗口失败：$error');
    }
  }

  void closePanel() {
    panel.value = null;
    unawaited(platform.setFocusable(false));
    _refreshInteractive();
  }

  void _onPointer(PetPointer pointer) {
    _pointerDown = pointer.down;
    final cursor = pointer.position;
    _lastCursor = cursor;
    // 只打印一次首个事件，但每个事件都要做命中判定：穿透翻转依赖持续刷新。
    if (!_cursorLogged) {
      _cursorLogged = true;
      debugPrint('[pet] 收到首个光标 $cursor，宠物区=${_body.rect}');
    }

    if (panel.value == null) {
      if (_body.dragging) {
        _applyInteractive(true);
      } else {
        _applyInteractive(_hitTest(cursor));
      }
    }

    if (!_body.dragging) return;

    // 左键已松开：换屏中先记下，等换屏结果回来再收尾；否则立即结束。
    // 这是 pan 被窗口移动打断后唯一的松手信号，不能因为 _screenSwitching 丢掉。
    if (!pointer.down) {
      if (_screenSwitching) {
        _pendingRelease = true;
      } else {
        _endDrag();
      }
      return;
    }

    if (_screenSwitching) return;

    // 指针进入另一块屏：请求原生把窗口搬过去，Dart 侧立即重新落点。
    final screenIndex = _screenIndexAt(cursor);
    if (screenIndex != null && screenIndex != _activeScreenIndex) {
      unawaited(_switchToScreen(screenIndex));
      return;
    }

    if (_pointerDrivenDrag) {
      // 换屏后新屏幕列表还没回来：这时的本地坐标可能还是旧窗口的，
      // 先用换屏结果里的指针位置，等 setScreens 后再跟手。
      if (_screensDirty) return;
      _body.updateDragTarget(cursor - _grabOffset);
      _sampler.add(_dragWatch?.elapsed ?? Duration.zero, cursor);
    }
  }

  /// 关闭浮层、拖动结束、宠物移动后都按“当前光标”重算穿透。
  void _syncInteractive() => _refreshInteractive();

  void _refreshInteractive() {
    if (panel.value != null) return;
    if (_body.dragging) {
      _applyInteractive(true);
      return;
    }
    final cursor = _lastCursor;
    if (cursor == null) {
      _applyInteractive(false);
      return;
    }
    _applyInteractive(_hitTest(cursor));
  }

  void _applyInteractive(bool over) {
    if (over == _interactive) return;
    _interactive = over;
    debugPrint('[pet] interactive=$over 光标=$_lastCursor');
    unawaited(
      platform.setInteractive(over).catchError((Object error) {
        debugPrint('[pet] setInteractive 调用失败：$error');
      }),
    );
  }

  /// 命中区只算“真正可交互”的东西：宠物身体。菜单/面板打开期间整窗交互由
  /// openMenu / openPanel 显式接管，关闭后再回到这里的细粒度判定。
  /// 气泡不可点击，把大片区域设为命中只会挡住底下的桌面操作。
  bool _hitTest(Offset cursor) => hitsPetBody(cursor, _body.rect.inflate(4));

  // ---------------------------------------------------------------------------
  // 动画切换
  // ---------------------------------------------------------------------------

  void _play(String? name, {bool loop = false, bool restart = false}) {
    if (name == null || name.isEmpty) return;
    final current = _player;
    if (!restart &&
        _currentAnimation == name &&
        current != null &&
        !current.finished) {
      current.loop = loop;
      return;
    }

    final next = SpritePlayer(
      assetPath: 'assets/animations/$name.webp',
      loop: loop,
    );
    // 旧帧 clone 一份给淡出用：直接持有旧 player 的 image 会被它的 dispose 提前释放。
    final outgoingImage = current?.image?.clone();
    current?.dispose();

    _fadeFrom?.dispose();
    _fadeFrom = outgoingImage;
    _fadeElapsed = outgoingImage == null ? 1 : 0;

    _player = next;
    _currentAnimation = name;
    _poseFinishedHandled = false;
    unawaited(
      next.start().catchError((Object error) {
        showBubble('动画加载失败：$name（$error）');
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // 诊断
  // ---------------------------------------------------------------------------

  /// `/pet/state` 用：多屏错位、拖不动时直接把内部坐标摊开对账。
  Map<String, Object?> state() {
    Map<String, Object?>? rectMap(Rect? rect) => rect == null
        ? null
        : {
            'x': rect.left,
            'y': rect.top,
            'width': rect.width,
            'height': rect.height,
          };
    return {
      'position': rectMap(petRect),
      'viewport': rectMap(_viewport == null ? null : Offset.zero & _viewport!),
      'activeScreen': rectMap(activeScreen),
      'dragScreen': rectMap(_dragDomain),
      'screens': [
        for (final screen in _screens ?? const <Rect>[]) rectMap(screen),
      ],
      'dragging': _body.dragging,
      'pinned': _body.pinned,
      'thrown': _thrown,
      'pointerDown': _pointerDown,
      'pendingRelease': _pendingRelease,
      'pointerDriven': _pointerDrivenDrag,
      'screenSwitching': _screenSwitching,
      'screensDirty': _screensDirty,
      'activeScreenIndex': _activeScreenIndex,
      'interactive': _interactive,
      'mode': _mode.name,
      'panel': panel.value?.name,
      'squash': {'x': squash.value.dx, 'y': squash.value.dy},
    };
  }

  // ---------------------------------------------------------------------------
  // 释放
  // ---------------------------------------------------------------------------

  void dispose() {
    _timersAndStreamsCleanup();
    _player?.dispose();
    _player = null;
    _fadeFrom?.dispose();
    _fadeFrom = null;
    position.dispose();
    bubble.dispose();
    panel.dispose();
    repaint.dispose();
    dragging.dispose();
    squash.dispose();
  }

  void _timersAndStreamsCleanup() {
    _ticker.stop();
    _ticker.dispose();
    _poseTimer?.cancel();
    _bubbleTimer?.cancel();
    _cursorSubscription?.cancel();
    _cursorSubscription = null;
  }
}
