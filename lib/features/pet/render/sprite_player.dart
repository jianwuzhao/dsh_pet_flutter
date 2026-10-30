/// 逐帧播放动画 WebP。
///
/// 为什么自己解码而不是用 Image 组件：桌宠需要精确控制“播完停住 / 循环 / 交叉淡入 / 镜像”，
/// 还要按需解码控制内存。Flutter 引擎（Skia）原生支持带 alpha 的动画 WebP 解码，
/// 我们只持有“当前帧 + 预解码的下一帧”，画完就 dispose，RSS 不随动画长度增长。
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SpritePlayer extends ChangeNotifier {
  SpritePlayer({required this.assetPath, this.loop = true});

  final String assetPath;
  bool loop;

  ui.Codec? _codec;
  Uint8List _bytes = Uint8List(0);

  ui.Image? _front;
  ui.Image? _back;
  int _frameCount = 0;
  int _cursor = 0;
  Duration _frameDuration = const Duration(milliseconds: 83);
  Duration _accumulated = Duration.zero;
  Duration _played = Duration.zero;

  bool _loading = false;
  bool _disposed = false;
  bool _preparingNext = false;
  bool _finished = false;

  /// 当前可绘制的帧（可能为 null：仍在解码首帧）。
  ui.Image? get image => _front;
  bool get finished => _finished;

  /// 已播总帧数：漫游按进度算位移时要用。
  int get frameCount => _frameCount;

  /// 本段动画已播时间（暂停在最后一帧后不再累加）。
  Duration get played => _played;

  Future<void> start() async {
    if (_loading || _codec != null) return;
    _loading = true;
    try {
      final data = await rootBundle.load(assetPath);
      _bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final codec = await ui.instantiateImageCodec(_bytes);
      if (_disposed) {
        codec.dispose();
        return;
      }
      _codec = codec;
      _frameCount = codec.frameCount;
      await _decodeNext();
    } on Object catch (error, stack) {
      // 素材缺失不能静默：把路径与原因抛给上层气泡提示（沿用上游“不静默兜底”的约定）。
      debugPrint('SpritePlayer 解码失败 $assetPath: $error\n$stack');
      rethrow;
    } finally {
      _loading = false;
    }
  }

  /// 按累计时间推进；60Hz 由外部 Ticker 调用。
  void advance(Duration elapsed) {
    if (_codec == null || _front == null || _finished) return;
    _played += elapsed;
    _accumulated += elapsed;
    if (_accumulated < _frameDuration) return;
    _accumulated -= _frameDuration;
    if (_back == null) {
      _prefetch();
      return;
    }
    // 双缓冲交换：渲染线程仍可能在使用旧帧，dispose 放到帧后再释放。
    final retired = _front;
    _front = _back;
    _back = null;
    retired?.dispose();
    _cursor++;
    if (_cursor >= _frameCount) {
      if (!loop) {
        // 停在最后一帧而不是清空：清空会在切换动画前露出一拍空白。
        _finished = true;
        notifyListeners();
        return;
      }
      _restartLoop();
    }
    notifyListeners();
    _prefetch();
  }

  Future<void> _prefetch() => _decodeNext();

  Future<void> _decodeNext() async {
    final codec = _codec;
    if (codec == null || _preparingNext || _disposed) return;
    _preparingNext = true;
    try {
      final info = await codec.getNextFrame();
      if (_disposed) {
        info.image.dispose();
        return;
      }
      _frameDuration = info.duration;
      if (_front == null) {
        _front = info.image;
        notifyListeners();
        // 立刻预取下一帧，避免首帧播完出现空档
        _preparingNext = false;
        unawaited(_decodeNext());
        return;
      }
      _back = info.image;
    } finally {
      _preparingNext = false;
    }
  }

  void _restartLoop() {
    // 手动回卷：不同平台 Codec 的自动循环行为不完全一致，统一自己重开更可控。
    final bytes = _bytes;
    _codec?.dispose();
    _codec = null;
    _cursor = 0;
    unawaited(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      if (_disposed) {
        codec.dispose();
        return;
      }
      _codec = codec;
      _frameCount = codec.frameCount;
      await _decodeNext();
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    _codec?.dispose();
    _codec = null;
    _front?.dispose();
    _back?.dispose();
    _front = null;
    _back = null;
    super.dispose();
  }
}
