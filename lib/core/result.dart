/// 结构化结果：失败必须带原因码与可读原因，上层据此决定气泡文案。
///
/// 上游全程贯彻“不伪造成功”，这里用同一套约定，避免异常被吞掉后宠物装作没事。
library;

sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;
  Failure<T>? get failureOrNull =>
      this is Failure<T> ? this as Failure<T> : null;
  T? get valueOrNull => this is Success<T> ? (this as Success<T>).value : null;
}

class Success<T> extends Result<T> {
  const Success(this.value);

  final T value;
}

class Failure<T> extends Result<T> {
  const Failure(this.code, this.reason);

  /// 机器可读的原因码，例如 `linkage.clipboard-denied`。
  final String code;
  final String reason;

  @override
  String toString() => '[$code] $reason';
}
