/// 形象档案仓库：原子写 + 版本历史 + 回滚。
///
/// 与其它画像档案不同，形象损坏**不静默回退**：返回 Failure，由内核决定
/// 是提示用户还是使用默认值——形象直接决定渲染，静默替换会让人以为"宠物变异了"。
library;

import 'dart:convert';
import 'dart:io';

import '../../core/paths/app_paths.dart';
import '../../core/result.dart';
import 'appearance_proposal.dart';
import 'appearance_state.dart';

/// 历史最多保留的版本数（够回滚与追责，不无限膨胀）。
const int appearanceHistoryLimit = 10;

class AppearanceStore {
  AppearanceStore({Directory? directory})
    : _directory = directory ?? AppPaths.profileDir;

  final Directory _directory;

  File get _file =>
      File('${_directory.path}${Platform.pathSeparator}appearance.json');

  File get _historyFile => File(
    '${_directory.path}${Platform.pathSeparator}appearance_history.json',
  );

  /// 待确认的形态提案（与当前形象分开存：拒绝即删，不污染历史）。
  File get _proposalFile => File(
    '${_directory.path}${Platform.pathSeparator}appearance_proposal.json',
  );

  /// 读取当前形象；文件不存在返回默认值（首次运行不是错误）。
  Result<AppearanceState> load() {
    try {
      final file = _file;
      if (!file.existsSync()) {
        return Success(const AppearanceState());
      }
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return Failure('appearance.malformed', '形象档案不是 JSON 对象：${file.path}');
      }
      return Success(AppearanceState.fromJson(raw));
    } on FormatException catch (error) {
      return Failure(
        'appearance.malformed',
        '形象档案损坏（${_file.path}）：${error.message}',
      );
    } on Object catch (error) {
      return Failure('appearance.read-failed', '形象档案读取失败：$error');
    }
  }

  /// 保存：先追加历史，再原子写当前档案。
  /// [recordHistory] = false 用于"回滚"——回滚时把目标版写回当前，但不再重复追加。
  Result<void> save(AppearanceState state, {bool recordHistory = true}) {
    if (recordHistory) {
      final history = _loadHistory();
      history.add(state);
      while (history.length > appearanceHistoryLimit) {
        history.removeAt(0);
      }
      final historyResult = _writeJson(
        _historyFile,
        {'entries': [for (final item in history) item.toJson()]},
      );
      if (historyResult is Failure<void>) return historyResult;
    }
    return _writeJson(_file, state.toJson());
  }

  /// 回滚到上一版：历史末条是当前版本，取它前面那条写回并记为一次新修订。
  Result<AppearanceState> rollback() {
    final history = _loadHistory();
    if (history.length < 2) {
      return const Failure('appearance.no-history', '还没有可回滚的历史版本');
    }
    history.removeLast(); // 当前版本
    final target = history.last;
    final currentResult = load();
    final current = switch (currentResult) {
      Success(value: final value) => value,
      Failure() => const AppearanceState(),
    };
    final restored = target.copyWith(
      revision: current.revision + 1,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    // 回滚后的版本本身成为历史末条，保证连续回滚不会拿到同一条。
    history[history.length - 1] = restored;
    final historyResult = _writeJson(
      _historyFile,
      {'entries': [for (final item in history) item.toJson()]},
    );
    if (historyResult is Failure<void>) {
      return failureAs<AppearanceState>(historyResult);
    }
    final saveResult = save(restored, recordHistory: false);
    if (saveResult is Failure<void>) {
      return failureAs<AppearanceState>(saveResult);
    }
    return Success(restored);
  }

  /// 历史版本（旧 → 新）。
  List<AppearanceState> history() => _loadHistory();

  /// 读取待确认的形态提案；不存在返回 null（不是错误）。
  Result<AppearanceProposal?> loadProposal() {
    try {
      final file = _proposalFile;
      if (!file.existsSync()) return const Success(null);
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        return Failure(
          'appearance.proposal-malformed',
          '形态提案不是 JSON 对象：${file.path}',
        );
      }
      return Success(AppearanceProposal.fromJson(raw));
    } on FormatException catch (error) {
      return Failure('appearance.proposal-malformed', '形态提案损坏：${error.message}');
    } on Object catch (error) {
      return Failure('appearance.proposal-read-failed', '形态提案读取失败：$error');
    }
  }

  Result<void> saveProposal(AppearanceProposal proposal) =>
      _writeJson(_proposalFile, proposal.toJson());

  /// 拒绝或已采纳后清除提案；文件本来就不存在也算成功。
  Result<void> clearProposal() {
    try {
      final file = _proposalFile;
      if (file.existsSync()) file.deleteSync();
      return const Success(null);
    } on Object catch (error) {
      return Failure('appearance.proposal-write-failed', '形态提案清除失败：$error');
    }
  }

  List<AppearanceState> _loadHistory() {
    try {
      final file = _historyFile;
      if (!file.existsSync()) return [];
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map) return [];
      final entries = raw['entries'];
      if (entries is! List) return [];
      return [
        for (final item in entries)
          if (item is Map<String, dynamic>) AppearanceState.fromJson(item),
      ];
    } on Object {
      // 历史是审计副本：损坏时按空历史继续，不影响当前形象。
      return [];
    }
  }

  /// 原子写：先写 .tmp 再 rename，失败不破坏旧文件。
  Result<void> _writeJson(File file, Map<String, dynamic> payload) {
    try {
      if (!_directory.existsSync()) _directory.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(payload), flush: true);
      tmp.renameSync(file.path);
      return const Success(null);
    } on Object catch (error) {
      return Failure('appearance.write-failed', '形象档案写入失败：$error');
    }
  }

  /// Result 的失败值类型转换：保持错误码与原因不变。
  static Result<T> failureAs<T>(Failure<void> failure) =>
      Failure(failure.code, failure.reason);
}
