/// 记忆向量库（P1-4 语义召回）：sqlite3 + sqlite_vector 扩展。
///
/// 存储每条 chat 记忆的 embedding，供 Recall 层做语义近邻检索。
/// json 记忆文件仍是唯一主存储，向量库只是可丢弃的检索索引——
/// 扩展加载失败或库损坏时全部操作静默降级为 no-op，Recall 回落
/// 关键词命中，向量层故障不拖垮对话主路径（计划 5.5 的回滚要求）。
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_vector/sqlite_vector.dart';

import '../../core/paths/app_paths.dart';
import 'memory_entry.dart';

/// 语义近邻结果：记忆 id + 余弦距离（越小越相似）。
typedef VectorHit = ({String id, double distance});

class MemoryVectorStore {
  /// 进程内只加载一次扩展：重复加载同一个 dylib 是浪费且行为未定义。
  static bool _extensionLoaded = false;

  MemoryVectorStore._(this._db) {
    _openSchema();
  }

  MemoryVectorStore.disabled() : _db = null;

  Database? _db;

  /// 当前库的向量维度；0 = 还没有过向量（尚未确定维度）。
  int _dimension = 0;

  bool get isAvailable => _db != null;

  /// 打开数据目录里的向量库；任何一步失败返回禁用实例。
  factory MemoryVectorStore.openFile() {
    try {
      // 顺序关键：扩展经 sqlite3 auto-extension 注册，只对之后打开的
      // 连接生效——必须先加载扩展再 open，已有连接补不了。
      _loadExtensionOnce();
      final file = AppPaths.memoryVectorFile;
      file.parent.createSync(recursive: true);
      return MemoryVectorStore._(sqlite3.open(file.path));
    } on Object {
      return MemoryVectorStore.disabled();
    }
  }

  /// 内存库（测试用）：同样先加载扩展再开连接。
  factory MemoryVectorStore.openInMemory() {
    try {
      _loadExtensionOnce();
      return MemoryVectorStore._(sqlite3.openInMemory());
    } on Object {
      return MemoryVectorStore.disabled();
    }
  }

  static void _loadExtensionOnce() {
    if (_extensionLoaded) return;
    sqlite3.loadSqliteVectorExtension();
    _extensionLoaded = true;
  }

  void _openSchema() {
    final db = _db;
    if (db == null) return;
    db.execute('''
      CREATE TABLE IF NOT EXISTS vector_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    final dim = db.select(
      "SELECT value FROM vector_meta WHERE key = 'dimension'",
    );
    _dimension = dim.isEmpty
        ? 0
        : int.tryParse(dim.first['value'] as String) ?? 0;
  }

  /// 每个维度一张表（memory_vectors_{dim}）：vector_init 的维度在初始化
  /// 后不可变更，与其删表重嵌，不如让不同 embedding 模型各占一张表——
  /// 换模型零重建成本，切回旧模型还能复用历史向量。
  /// 维度值来自 vector.length，表名只可能是数字后缀，无注入面。
  String _tableFor(int dimension) => 'memory_vectors_$dimension';

  String get _table => _tableFor(_dimension);

  /// 维度守卫：首次见到某维度时建表 + 初始化该表的向量索引；
  /// 重复初始化（重开进程后）同表同参是幂等的，失败也不致命——
  /// 后续 upsert/nearest 各自再兜底。
  bool _ensureDimension(int dimension) {
    final db = _db;
    if (db == null || dimension <= 0) return false;
    if (_dimension == dimension) return true;
    final table = _tableFor(dimension);
    try {
      db.execute('''
        CREATE TABLE IF NOT EXISTS $table (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          content_hash TEXT NOT NULL,
          embedding BLOB NOT NULL
        )
      ''');
      db.execute(
        "SELECT vector_init('$table', 'embedding', "
        "'type=FLOAT32,dimension=$dimension,distance=COSINE')",
      );
      db.execute(
        "INSERT INTO vector_meta (key, value) VALUES ('dimension', '$dimension') "
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      );
    } on Object {
      return false;
    }
    _dimension = dimension;
    return true;
  }

  /// 写入/更新一条记忆的向量。content_hash 用于后续判断记忆正文
  /// 是否变更（变更则需重嵌），避免每轮全量重算。
  void upsert(MemoryEntry entry, List<double> vector) {
    final db = _db;
    if (db == null || vector.isEmpty) return;
    try {
      if (!_ensureDimension(vector.length)) return;
      final table = _table;
      final stmt = db.prepare('''
        INSERT INTO $table (id, kind, content_hash, embedding)
        VALUES (?, ?, ?, vector_as_f32(?))
        ON CONFLICT(id) DO UPDATE SET
          kind = excluded.kind,
          content_hash = excluded.content_hash,
          embedding = excluded.embedding
      ''');
      stmt.execute([
        entry.id,
        entry.kind.name,
        contentHash(entry.content),
        jsonEncode(vector),
      ]);
      stmt.close();
    } on Object {
      // 索引层故障不影响主存储：静默放弃本条向量。
    }
  }

  /// 语义近邻检索：余弦距离升序，≤ limit 条。
  /// top-k 扫描不做相关性过滤（正交也算“最近”），必须配距离阈值——
  /// 阈值取 0.45（对应 cosine 相似度 ≥0.55，bge 系模型经验上相关对的
  /// 下沿附近），再远的命中属于噪音，宁缺勿滥地回落关键词召回。
  /// 查询维度与库不一致（模型切换窗口期）返回空，由调用方回落关键词。
  static const double maxRecallDistance = 0.45;

  List<VectorHit> nearest(
    List<double> query, {
    int limit = 6,
    double maxDistance = maxRecallDistance,
  }) {
    final db = _db;
    if (db == null || query.isEmpty || _dimension != query.length) {
      return const [];
    }
    try {
      final table = _table;
      final rows = db.select('''
        SELECT m.id AS id, s.distance AS distance
        FROM vector_full_scan(
          '$table', 'embedding', vector_as_f32(?), ?
        ) AS s
        JOIN $table AS m ON m.rowid = s.rowid
        WHERE s.distance <= ?
      ''', [jsonEncode(query), limit, maxDistance]);
      return [
        for (final row in rows)
          (
            id: row['id'] as String,
            distance: (row['distance'] as num).toDouble(),
          ),
      ];
    } on Object {
      return const [];
    }
  }

  /// 库里所有维度表：删除类操作要遍历全部——记忆删除后若只清当前
  /// 维度表，切回旧 embedding 模型时已删记忆会从旧表“复活”成命中。
  /// LIKE 里的 `_` 是单字符通配符，用 ESCAPE 转义成字面量。
  List<String> _allTables(Database db) {
    final rows = db.select(
      "SELECT name FROM sqlite_master "
      r"WHERE type = 'table' AND name LIKE 'memory_vectors\_%' ESCAPE '\'",
    );
    return [for (final row in rows) row['name'] as String];
  }

  void remove(String id) {
    final db = _db;
    if (db == null) return;
    try {
      for (final table in _allTables(db)) {
        db.execute('DELETE FROM $table WHERE id = ?', [id]);
      }
    } on Object {
      // 同 upsert：索引层失败静默。
    }
  }

  void removeKind(MemoryKind kind) {
    final db = _db;
    if (db == null) return;
    try {
      for (final table in _allTables(db)) {
        db.execute('DELETE FROM $table WHERE kind = ?', [kind.name]);
      }
    } on Object {
      // 同 upsert：索引层失败静默。
    }
  }

  /// 清掉主存储里已不存在的记忆残留向量（所有维度表）：已删/归档的
  /// 记忆不该继续占用 top-k 名额，更不能在换回旧模型时“复活”。
  /// validIds 为空 = 全清（记忆库整体清空的形态）。
  void prune(Set<String> validIds) {
    final db = _db;
    if (db == null) return;
    try {
      for (final table in _allTables(db)) {
        if (validIds.isEmpty) {
          db.execute('DELETE FROM $table');
          continue;
        }
        final placeholders = List.filled(validIds.length, '?').join(', ');
        db.execute(
          'DELETE FROM $table WHERE id NOT IN ($placeholders)',
          validIds.toList(),
        );
      }
    } on Object {
      // 同 upsert：索引层失败静默。
    }
  }

  /// 找需要（重新）嵌向量的条目：库里没有对应向量，或正文已变更。
  /// 向量同步任务据此做增量补嵌，避免每轮全量调用 embedding 接口。
  List<MemoryEntry> stale(Iterable<MemoryEntry> entries) {
    final db = _db;
    if (db == null) return const [];
    // 维度未定 = 库里从没嵌过任何向量：所有条目都待嵌。
    // 若走 SELECT 会因表不存在进 catch，误报“无待嵌”，首次同步就漏掉。
    if (_dimension == 0) return entries.toList();
    try {
      final table = _table;
      final known = {
        for (final row in db.select(
          'SELECT id, content_hash FROM $table',
        ))
          row['id'] as String: row['content_hash'] as String,
      };
      return [
        for (final entry in entries)
          if (known[entry.id] != contentHash(entry.content)) entry,
      ];
    } on Object {
      return const [];
    }
  }

  /// 稳定内容指纹（FNV-1a 64 位）：String.hashCode 每次运行都可能不同，
  /// 不能落盘比对；不引 crypto 依赖，碰撞概率对本场景（变更检测）足够低。
  static String contentHash(String content) {
    var hash = 0xcbf29ce484222325;
    for (final unit in content.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  void dispose() {
    _db?.close();
    _db = null;
  }
}
