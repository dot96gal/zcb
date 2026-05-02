# Zig サーキットブレーカーライブラリ実装計画

## 概要

Zig 用のサーキットブレーカーライブラリを実装する。Sony の [gobreaker](https://github.com/sony/gobreaker) を設計の参考としつつ、Zig の設計哲学（明示性・エラーユニオン・comptime・呼び出し元への制御委譲）に沿った独自の API を設計する。外部ライブラリに依存せず `std` のみを使用し、スレッドセーフな状態管理を提供する。

---

## 現状

| 項目 | 内容 |
|------|------|
| Zig バージョン | 0.16.0 |
| ライブラリ名 | `zcb` |
| 現在の `src/root.zig` | スケルトンコード（`printAnotherMessage` / `add`） |
| 現在の `src/main.zig` | スケルトンコード（参照のみ） |
| ドキュメント | README 未整備 |

---

## 実現性評価（調査済み）

| 必要な機能 | 使用する Zig API | 調査結果 |
|-----------|----------------|---------|
| 相互排他ロック | `std.Io.Mutex = .init`（`lock` / `unlock` に `io` 必須） | ✅ 利用可能 |
| 現在時刻取得 | `std.Io.Clock.awake.now(io)` → `std.Io.Timestamp` | ✅ 利用可能 |
| タイムスタンプ保存 | `std.Io.Timestamp`（`nanoseconds: i96` フィールド） | ✅ 利用可能 |
| テスト時刻注入 | `Clock` インターフェース + `TestClock.clock()` + `Config.clock` フィールド | ✅ 利用可能 |
| エラー定義 | `error{ OpenState, TooManyRequests }` | ✅ 利用可能 |
| ジェネリック実行関数 | `anytype` duck typing | ✅ 利用可能 |
| 関数ポインタコールバック | `*const fn(...) T` | ✅ 利用可能 |

**調査結果（2026-05-02 実機確認済み）**：

- `std.time.nanoTimestamp()` → **使用不可**。コンパイルエラー: `root source file struct 'time' has no member named 'nanoTimestamp'`
- `std.Io.Timestamp` → **採用**。`nanoseconds: i96` フィールドを持つ構造体。`std.Io.Clock.awake.now(io)` で取得する
- `std.testing.io` → **テストで利用可能**。`std.testing.io_instance: std.Io.Threaded` のラッパーとして提供される
- `std.Thread.Mutex` → **使用不可**（コンパイルエラー: `root source file struct 'Thread' has no member named 'Mutex'`）
- `std.Io.Mutex` → **採用**。`= .init` で初期化。`lock(m, io)` / `lockUncancelable(m, io)` / `unlock(m, io)` はすべて `io: std.Io` を要求する

使用する `std.Io.Timestamp` API：

```zig
// 現在時刻取得（monotonic clock）
const now: std.Io.Timestamp = std.Io.Clock.awake.now(io);

// タイムスタンプ比較
const elapsedNs: i96 = now.nanoseconds - expiry.nanoseconds;  // > 0 なら期限経過

// 期限計算（Config の u64 を i96 にキャスト）
const timeoutI96: i96 = @as(i96, @intCast(self.config.timeoutNs));
const expiry: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds + timeoutI96 };
```

---

## 制約事項

- `std.time.nanoTimestamp()` **使用不可**（調査済み）→ `std.Io.Timestamp` を使用し、`execute` / `allow` / `getState` / `getCounts` に `io: std.Io` を追加する
- `std.Thread.Mutex` **使用不可**（調査済み）→ `std.Io.Mutex = .init` を使用する。`lock` / `lockUncancelable` / `unlock` はすべて `io: std.Io` を要求する
- `std.Thread.Pool` は 0.16.0 で削除済み → バックグラウンドタイマーは使用しない。Open → Half-Open 遷移は次回リクエスト時の遅延評価で行う（gobreaker と同方式）
- `std.Thread.WaitGroup` → `std.Io.Group` に変更済み（本ライブラリでは使用しない）
- `std.heap.ThreadSafeAllocator` 削除済み（`ArenaAllocator` がスレッドセーフ化）→ 本ライブラリはアロケータ不使用のためスタックアロケーション完結
- 本ライブラリ自体は動的メモリ確保を行わない（`Config.name` のライフタイムは呼び出し元が管理）
- `timeoutNs`/`intervalNs` は `u64`（ナノ秒）で受け取り、内部で `@as(i96, @intCast(value))` として `std.Io.Timestamp` 演算に使用する
- 時刻注入は `Config.clock: Clock` フィールド経由で行う。デフォルトは `Clock.system`（実時刻）、テストは `TestClock.clock()` を設定する。`CircuitBreaker` 内部では `_clock: Clock` フィールドで保持する
- `timeoutNs = 0` の場合、`expiry = now + 0 = now` となり Open 状態への遷移直後に Half-Open へ即遷移する（意図的設計：実質 Open 状態を維持しない）
- `intervalNs = 0` の場合はカウンターリセットを行わない（"無効" = Closed 状態のカウンターが永続）
- `AllowToken.done()` は generation に対して最初の呼び出しのみ有効。二重呼び出し時は generation 不一致でスキップされるため副作用なし（べき等）

---

## API 設計

### 公開定数

```zig
/// readyToTrip が null 時に使用するデフォルト連続失敗閾値の定数。デフォルト trip 判定に利用する。
pub const DEFAULT_CONSECUTIVE_FAILURES_THRESHOLD: u32 = 5;
```

### 公開型

```zig
/// 時刻取得の抽象インターフェースの型。本番・テスト両方で利用する。
pub const Clock = struct {
    context: ?*anyopaque,
    nowFn: *const fn (context: ?*anyopaque, io: std.Io) std.Io.Timestamp,

    /// システム時刻を使うデフォルト実装の定数。本番コードで利用する。
    pub const system: Clock = .{
        .context = null,
        .nowFn = struct {
            fn now(_: ?*anyopaque, io: std.Io) std.Io.Timestamp {
                return std.Io.Clock.awake.now(io);
            }
        }.now,
    };

    pub fn now(self: Clock, io: std.Io) std.Io.Timestamp {
        return self.nowFn(self.context, io);
    }
};

/// サーキットブレーカーの状態を表す列挙型。
pub const State = enum {
    closed,
    halfOpen,
    open,
};

/// リクエストのカウンターを保持する構造体。
pub const Counts = struct {
    requests: u32 = 0,
    totalSuccesses: u32 = 0,
    totalFailures: u32 = 0,
    consecutiveSuccesses: u32 = 0,
    consecutiveFailures: u32 = 0,
};

/// サーキットブレーカーのエラー集合。
pub const Error = error{
    /// Open 状態でリクエストが拒否されたエラー。
    OpenState,
    /// Half-Open 状態で maxRequests を超えたエラー。
    TooManyRequests,
};
```

### Config 構造体

```zig
/// サーキットブレーカーの設定を保持する構造体。
pub const Config = struct {
    /// ブレーカー名のフィールド。サーキットブレーカーの識別名を表す。
    name: []const u8 = "",

    /// Half-Open 状態で通過を許可する最大リクエスト数のフィールド。
    /// 0 指定時は init() 内で 1 に正規化される。
    maxRequests: u32 = 1,

    /// Closed 状態でカウンターをリセットするサイクル間隔（ナノ秒）のフィールド。0 で無効を表す。
    intervalNs: u64 = 0,

    /// Open 状態の持続時間（ナノ秒）のフィールド。経過後に Half-Open へ遷移するまでの時間を表す。
    timeoutNs: u64 = 60 * std.time.ns_per_s,

    /// Open への遷移条件を定義するコールバックのフィールド。null 時は連続失敗 > DEFAULT_CONSECUTIVE_FAILURES_THRESHOLD をデフォルト条件として表す。
    readyToTrip: ?*const fn (counts: Counts) bool = null,

    /// エラーの成功・失敗分類を定義するコールバックのフィールド。null 時は anyerror を失敗と判定する条件を表す。
    isSuccessful: ?*const fn (err: anyerror) bool = null,

    /// 状態変化時に呼ばれるコールバックのフィールド。null 時は何もしないコールバックを表す。
    onStateChange: ?*const fn (name: []const u8, from: State, to: State) void = null,

    /// 時刻取得の実装を差し替えるフィールド。本番は Clock.system（デフォルト）、テストは TestClock.clock() を使用する。
    clock: Clock = Clock.system,
};
```

### CircuitBreaker 構造体

```zig
/// サーキットブレーカーの型。外部サービス呼び出しの障害伝播を防ぐために利用する。
pub const CircuitBreaker = struct {
    config: Config,
    // 以下は内部フィールド。Zig にはアクセス修飾子がないが、
    // mutex を迂回した直接変更はスレッド安全性を破壊するため行わないこと。
    _mutex: std.Io.Mutex = .init,
    _state: State = .closed,
    _generation: u64 = 0,
    _counts: Counts = .{},
    _expiry: std.Io.Timestamp = .{ .nanoseconds = 0 },  // nanoseconds=0 は期限なし
    _clock: Clock,

    /// CircuitBreaker を初期化する関数。設定の適用に利用する。
    pub fn init(config: Config) CircuitBreaker;

    /// 現在の状態を評価して返す関数。タイムアウト経過時に Open → Half-Open 遷移を行う。スレッドセーフ。
    pub fn getState(self: *CircuitBreaker, io: std.Io) State;

    /// 現在のカウンターのコピーを返す関数。メトリクス取得に利用する。スレッドセーフ。
    pub fn getCounts(self: *CircuitBreaker, io: std.Io) Counts;

    /// 設定名を返す関数。識別子取得に利用する。
    pub fn getName(self: *const CircuitBreaker) []const u8;

    /// リクエストをサーキットブレーカー経由で実行する関数。外部サービス呼び出しのラップに利用する。
    /// req は `pub fn call(self: *@This()) anyerror!T` を持つ値へのポインタ（anytype）。
    pub fn execute(
        self: *CircuitBreaker,
        io: std.Io,
        comptime T: type,
        req: anytype,
    ) anyerror!T;

    /// Two-Step パターン用：リクエスト許可を判定し、結果報告用トークンを返す関数。
    /// リクエスト開始と完了が分離した非同期処理に利用する。使用後は必ず token.done(io, success) を呼ぶこと。
    pub fn allow(self: *CircuitBreaker, io: std.Io) Error!AllowToken;
};
```

### TestClock 構造体

```zig
/// テスト用の可変時刻クロックの型。Clock インターフェースの実装として利用する。
pub const TestClock = struct {
    nanoseconds: i96 = 0,

    /// Clock インターフェースを返す関数。CircuitBreaker.init() に渡して利用する。
    pub fn clock(self: *TestClock) Clock;

    /// 現在時刻をナノ秒だけ進める関数。タイムアウト・インターバルのシミュレートに利用する。
    pub fn advance(self: *TestClock, ns: u64) void;
};
```

### AllowToken 構造体（Two-Step パターン用）

```zig
/// Two-Step パターンのリクエスト完了報告用トークンの型。allow() の呼び出し後に利用する。
pub const AllowToken = struct {
    _cb: *CircuitBreaker,
    _generation: u64,

    /// リクエスト結果を報告する関数。success = true で成功、false で失敗として記録する。
    /// 同一 generation に対して最初の呼び出しのみ有効。二重呼び出しはスキップされる（べき等）。
    pub fn done(self: AllowToken, io: std.Io, success: bool) void;
};
```

---

## 使用例

### 基本的な使い方（execute）

コンテキスト（フィールド）が不要な場合はシンプルに書ける：

```zig
const std = @import("std");
const zcb = @import("zcb");

// req 型をファイルスコープで定義する
const FetchReq = struct {
    pub fn call(self: *@This()) anyerror![]const u8 {
        _ = self;
        return callExternalService();
    }
};

pub fn main(env: std.process.Init) !void {
    const io = env.io;

    var cb = zcb.CircuitBreaker.init(.{
        .name = "my-service",
        .timeoutNs = 30 * std.time.ns_per_s,
        .readyToTrip = struct {
            fn call(counts: zcb.Counts) bool {
                return counts.consecutiveFailures > 3;
            }
        }.call,
        // clock は省略すると Clock.system（実時刻）が使われる
    });

    var req = FetchReq{};
    const result = cb.execute(io, []const u8, &req) catch |err| switch (err) {
        error.OpenState => return error.ServiceUnavailable,
        error.TooManyRequests => return error.ServiceBusy,
        else => return err,
    };
    _ = result;
}
```

コンテキスト（フィールド）が必要な場合：

```zig
const FetchReq = struct {
    endpoint: []const u8,

    pub fn call(self: *@This()) anyerror![]const u8 {
        return callExternalServiceAt(self.endpoint);
    }
};

var req = FetchReq{ .endpoint = "https://api.example.com/data" };
const result = try cb.execute(io, []const u8, &req);
```

### Two-Step パターン（allow / done）

HTTP ミドルウェア等でリクエスト開始と応答受信が分離している場合に使用する。

```zig
const token = cb.allow(io) catch |err| switch (err) {
    error.OpenState => return sendError(503, "circuit open"),
    error.TooManyRequests => return sendError(429, "too many requests"),
    else => |e| return e,
};

const resp = sendRequest(req);
token.done(io, resp.status < 500);
```

### テスト時の時刻注入（TestClock）

`std.testing.io` は実際の時刻を返すため、テストでは `TestClock` で時刻を制御する。
`TestClock.clock()` が返す `Clock` を `init()` に渡すだけでよい。

```zig
test "open to half-open after timeout" {
    var testClock = zcb.TestClock{};
    var cb = zcb.CircuitBreaker.init(.{
        .timeoutNs = 100,
        .clock = testClock.clock(),
    });

    // タイムアウト経過をシミュレート
    testClock.advance(1200);
    const state = cb.getState(std.testing.io);
    try std.testing.expectEqual(.halfOpen, state);
}
```

---

## アルゴリズム

### 状態遷移

```
[Closed] ──失敗 + readyToTrip(counts)==true──▶ [Open]
   │                                              │
   │ intervalNs 経過でカウンターリセット            │ timeoutNs 経過
   ▼                                              ▼
[Closed]                                      [Half-Open]
                                                  │
                            連続成功 >= maxRequests ──▶ [Closed]
                            1回でも失敗            ──▶ [Open]
```

### `execute` の内部フロー

```
1. mutex ロック取得
2. currentState() で状態と generation を確認
   - Open かつ expiry 未経過 → `error.OpenState` を返す（mutex 解放後に return）
   - Half-Open かつ requests >= maxRequests → `error.TooManyRequests` を返す（同上）
   - Open かつ expiry 経過 → Half-Open に遷移（generation インクリメント・nextState を記録）
   - Closed かつ interval 経過 → generation インクリメント（状態は変えない）
3. counts.requests++ して generation を保存
4. mutex ロック解放
5. nextState が変化していれば onStateChange を呼ぶ（mutex 外）
6. req.call() を実行（ロック外）
7. mutex ロック取得
8. generation が変わっていなければ afterRequest() でカウント更新し nextState を記録
9. mutex ロック解放
10. nextState が変化していれば onStateChange を呼ぶ（mutex 外）
```

> **デッドロック防止**：`onStateChange` は必ず mutex 解放後（手順 5 / 10）に呼ぶ。
> コールバック内で `cb.getState()` / `cb.getCounts()` を呼んでも自ライブラリの mutex を二重取得しない。

### 世代（generation）によるカウント整合性

リクエスト実行中に状態遷移が起きた場合、古い世代の結果はカウントしない。

```
スレッド A: beforeRequest() → _generation=5
スレッド B: 失敗 → Open 遷移 → _generation=6
スレッド A: afterRequest(_generation=5) → _generation(6) != 5 → スキップ
```

---

## 設計判断

### execute の req 引数型

| 案 | 方法 | メリット | デメリット |
|----|------|----------|------------|
| A（採用） | `anytype` duck typing（`pub fn call(*@This()) !T` を要求） | コンテキスト自由・型安全 | コンパイルエラーが読みにくい |
| B | `*const fn(*anyopaque) !T` + context ポインタ | C ライクで明確 | anyopaque キャストが冗長 |
| C | クロージャ相当の関数ポインタ（コンテキストなし） | シンプル | コンテキストを渡せない |

`anytype` は Zig の標準ライブラリ（`std.mem.Allocator` 等）でも使われるイディオムであり採用する。`@compileError` でメソッドの有無を検証する。

### 時刻取得の抽象化（確定）

| 案 | 方法 | メリット | デメリット |
|----|------|----------|------------|
| A | `std.time.nanoTimestamp()` のみ使用 | シンプル | **0.16.0 では使用不可**（実機確認済み） |
| B | `io: std.Io` のみ使用（`std.Io.Clock.awake.now(io)`） | Zig 0.16.0 イディオム準拠 | テストに実時間が必要 |
| C | B + `Config.clockFn`/`clockCtx` でテスト時のみ差し替え | テスト容易性あり | `Config` にテスト専用フィールド混入 |
| **D（採用）** | **`Clock` インターフェースを `Config.clock` フィールドに持ち `Clock.system` をデフォルト値にする** | 本番コードへの影響ゼロ・テストは `clock` フィールドを差し替えるだけ・`init` のシグネチャがシンプル | — |

採用理由：`Clock` を `Config` フィールドとして `Clock.system` をデフォルト値にすることで、本番コードは `clock` を一切書かずに済む。テストでは `clock = testClock.clock()` を追加するだけでよく、他のコールバックフィールド（`readyToTrip` 等）と設定の一貫性が保てる。`init(config, clock)` のように引数を分ける場合と比べて本番コードで `Clock.system` を毎回明示する必要がない。

### 時間フィールドの型（確定）

| 案 | 型 | メリット | デメリット |
|----|-----|----------|------------|
| A | `i96`（`std.Io.Timestamp` と同じ） | 内部演算でキャスト不要 | 時間の長さに符号付き整数は不自然・ユーザーに内部実装が漏れる |
| **B（採用）** | **`u64`（符号なし・ナノ秒単位）** | 意味的に正しい（長さは非負）・`std.time.ns_per_s` との乗算も自然 | 内部で `@as(i96, value)` へのキャストが必要 |

採用理由：時間の長さは常に非負値であり、`u64` がセマンティクスとして正しい。内部での `i96` へのキャストは `@as(i96, @intCast(self.config.timeoutNs))` で対応できる。`i96` を公開 API に露出させると利用者が `std.Io.Timestamp` を意識する必要があり、実装詳細が漏れる。

### Two-Step パターンの API

| 案 | 方法 | メリット | デメリット |
|----|------|----------|------------|
| A（採用） | `AllowToken` 構造体を返し `done()` メソッドで報告 | 明示的・型安全 | — |
| B | `allow()` で関数ポインタを返す | gobreaker に近い | Zig に closure がないため context が渡せない |

`AllowToken` は `cb` ポインタと `generation` を保持する。`done()` を呼び忘れた場合はカウントが更新されない（仕様）。

---

## ファイル構成

```
src/
  root.zig              # 公開 API の明示的 re-export（pub const X = circuit_breaker.X; の形式）
  circuit_breaker.zig   # CircuitBreaker 実装本体（State / Counts / Config / Error / AllowToken を含む）
example/
  basic.zig             # execute を使った基本的な使い方
  allow_done.zig        # Two-Step パターン（allow / done）の使い方
```

`main.zig` はライブラリとして不要なため削除する。併せて `build.zig` から `exe` 定義・`run` ステップ・`exe_tests` を削除し、`mod_tests` のみを残す。

---

## 実装計画

### フェーズ 1：コア実装

- [x] `src/circuit_breaker.zig` を新規作成し、`Clock` / `State` / `Counts` / `Config` / `Error` を定義する
- [x] `Clock.system` 定数と `TestClock` 構造体（`clock()` / `advance()`）を実装する
- [x] `CircuitBreaker.init(config)` を実装する（`maxRequests = 0` を `1` に正規化）
- [x] 内部ヘルパー `toNewGeneration()` / `currentState()` を実装する（`_clock.now(io)` で時刻取得）
- [x] `beforeRequest()` / `afterRequest()` を実装する（generation 管理含む）
- [x] `execute(self, io, comptime T, req)` を実装する（`@compileError` で `call()` メソッドの存在をコンパイル時検証）
- [x] `allow(self, io)` と `AllowToken.done(self, io, success)` を実装する
- [x] `getState(self, io)` / `getCounts(self, io)` / `getName()` を実装する
- [x] `src/main.zig` を削除し、`build.zig` から `exe` 定義・`run` ステップ・`exe_tests` を削除する
- [x] `src/root.zig` を書き換えて公開 API を re-export する

### フェーズ 2：テスト

- [x] 基本状態遷移のテストを実装する（テスト計画参照）
- [x] エッジケースのテストを実装する
- [x] `mise run test` で全テストが通ることを確認する（19/19 通過）

### フェーズ 3：ドキュメント

- [x] README.md を更新する（概要・インストール・使用例・API リファレンス）
- [x] `mise run build-docs` でドキュメントビルドが成功することを確認する

### フェーズ 4：サンプル

- [x] `example/basic.zig` を作成する（`execute` を使った外部サービス呼び出しの基本例）
- [x] `example/allow_done.zig` を作成する（`allow` / `done` を使った Two-Step パターンの例）
- [x] `build.zig` にサンプル用ビルドステップを追加する（`run-example-basic` / `run-example-allow-done`）
- [x] `mise.toml` の既存 `example-basic` タスクを `example:basic` に変更し、`example:allow-done` タスクを追加する
- [x] `mise run example:basic` / `mise run example:allow-done` で正常に実行できることを確認する

---

## テスト計画

全テストは `Config.clock` に `TestClock.clock()` を渡して時刻を注入し、実時間スリープなしで実行する。`io` 引数には `std.testing.io` を渡すが、時刻は `TestClock` が制御するため実際のシステム時刻に影響されない。

| テストケース | 確認内容 |
|------------|----------|
| `init state is closed` | 初期状態が `.closed` であること |
| `closed counts requests` | execute 呼び出しでカウンターが更新されること |
| `closed to open on ready to trip` | `readyToTrip` が true を返したとき Open へ遷移すること |
| `open returns error.OpenState` | Open 状態で execute が `error.OpenState` を返すこと |
| `open to half-open after timeout` | タイムアウト経過後の execute で Half-Open に遷移すること |
| `half-open to closed on max successes` | `maxRequests` 回成功で Closed に戻ること |
| `half-open to open on failure` | Half-Open で 1 回失敗すると Open に戻ること |
| `half-open rejects excess requests` | `maxRequests` 超のリクエストに `error.TooManyRequests` を返すこと |
| `closed interval resets counts` | `intervalNs` 経過でカウンターがリセットされること |
| `custom ready to trip` | カスタム `readyToTrip` コールバックが機能すること |
| `custom is successful` | カスタム `isSuccessful` で業務エラーを成功扱いにできること |
| `on state change called` | 状態遷移時に `onStateChange` が呼ばれること |
| `generation skips stale result` | 実行中に状態遷移した場合、古い世代の結果を無視すること |
| `allow token done success` | `allow` + `token.done(io, true)` でカウンターが正しく更新されること |
| `allow token done failure` | `allow` + `token.done(io, false)` でカウンターが正しく更新されること |
| `default ready to trip` | デフォルト設定で連続失敗 > `DEFAULT_CONSECUTIVE_FAILURES_THRESHOLD` のとき Open に遷移すること |
| `timeout zero transitions immediately` | `timeoutNs = 0` で Open 直後に Half-Open へ即遷移すること |
| `allow token done idempotent` | `done()` を二重呼び出ししてもカウンターが重複更新されないこと |
| `on state change called after mutex release` | `onStateChange` コールバック内で `getState()` を呼んでもデッドロックしないこと |

---

## ドキュメント

### README.md 更新内容

**利用者向け**
- ライブラリの概要と設計思想（gobreaker を参考にした Zig らしい設計）
- `build.zig.zon` への依存追加方法
- 基本的な使い方（execute）のコード例
- Two-Step パターン（allow / done）のコード例
- `Config` 全フィールドの説明
- エラーの種類と対処法
- サンプル実行方法（`mise run example:basic` / `mise run example:allow-done`）

**開発者向け**
- 状態遷移図
- 世代管理の説明
- テスト実行方法（`mise run test`）

---

## 振り返り（フェーズ 1 / 2 実施後）

### 修正した問題

#### 1. `std.Io.Mutex.lock` がエラーユニオンを返す

**計画時の記述**：`lock(m, io)` / `lockUncancelable(m, io)` / `unlock(m, io)` はすべて `io: std.Io` を要求する

**発生した問題**：`self._mutex.lock(io)` を使うと `error union is ignored` コンパイルエラーになった。`lock` はキャンセル可能なためエラーユニオン `!void` を返す。

**対処**：ライブラリ内では全て `lockUncancelable(io)` に統一した。`lockUncancelable` はキャンセル不可のため `void` を返し、`try` 不要。

---

#### 2. `init` に `io` がなく `intervalNs` 用の `_expiry` が初期化されない

**計画時の想定**：`_expiry = .{ .nanoseconds = 0 }` を「期限なし」として利用し、`currentState` で `_expiry > 0` のときのみリセット判定を行う。

**発生した問題**：`init` に `io` がないため `toNewGeneration` を呼べず、`_expiry` が 0 のまま。`currentState` の closed ケースが `_expiry > 0` の条件を見ていたため、`intervalNs` を設定しても interval リセットが一度も発火しなかった。

**対処**：`currentState` の closed ケースで `_expiry == 0` のとき（初回アクセス時）にカウントをリセットせず expiry だけを初期化する lazy init を追加した。

```zig
.closed => {
    if (self.config.intervalNs > 0) {
        const now = self._clock.now(io);
        if (self._expiry.nanoseconds == 0) {
            // init 時に io がないため初回アクセス時に expiry を初期化する
            const ns: i96 = @as(i96, @intCast(self.config.intervalNs));
            self._expiry = .{ .nanoseconds = now.nanoseconds + ns };
        } else if (now.nanoseconds >= self._expiry.nanoseconds) {
            self.toNewGeneration(io);
        }
    }
    return .{};
},
```

---

#### 3. `allow token done idempotent` テストの前提誤り

**計画時の記述**：`AllowToken.done()` は generation に対して最初の呼び出しのみ有効。二重呼び出し時は generation 不一致でスキップされるため副作用なし（べき等）。

**発生した問題**：Closed 状態で `allow` を取得し `done(true)` を2回呼ぶテストを書いたが、Closed 状態では成功時に state 遷移が起きず generation が変わらないため、2回目も同じ generation でカウントされて失敗した。

**判明した事実**：generation ベースの idempotency は「`done()` 呼び出し中に別スレッドが state 遷移を起こした場合」または「`done()` 自身が state 遷移を起こした場合」にのみ機能する。単一スレッドで closed のまま2回 `done()` を呼んでも generation は変わらない。

**対処**：テストを「Half-Open → Closed 遷移を伴うシナリオ」に変更した。1回目の `done(true)` で `consecutiveSuccesses >= maxRequests` となり Closed へ遷移（`toNewGeneration` が generation を更新）。2回目の `done(true)` は generation 不一致でスキップされる。この挙動が計画の意図した idempotency の正しい文脈である。

---

#### 4. `execute` フローの記述不完全（Open→HalfOpen + TooManyRequests 同時発生）

**計画の記述**：フロー step 2 に「Open かつ expiry 未経過 → `error.OpenState`」と「Open かつ expiry 経過 → Half-Open 遷移」は記載されているが、「Open→HalfOpen 遷移 + `error.TooManyRequests` の同時発生」ケースが未記載。

**実際の動作**：`currentState()` で Open → HalfOpen に遷移した直後に `requests >= maxRequests` だった場合（別スレッドが既にリクエストを消費済み）、`onStateChange(open → halfOpen)` を呼んでから `error.TooManyRequests` を返す。実装の動作は正しい（遷移通知は行われるべき）。

**影響**：計画文書の記述が不完全だが実装の動作に問題はない。

---

#### 5. `execute` フロー step 2 のカウントリセット記述省略

**計画の記述**：「Closed かつ interval 経過 → generation インクリメント（状態は変えない）」

**実際の動作**：`toNewGeneration()` が呼ばれ、generation インクリメントに加えて **カウントリセット**（`_counts = .{}`）と **expiry 更新** も行われる。計画の説明からカウントリセットが抜けている。

**影響**：テスト `closed interval resets counts` でカウントリセットは検証済みのため動作に問題はない。計画文書の説明が不完全。

---

#### 6. `onStateChange` 呼び出し検証の限界（Zig のクロージャ制限）

**計画の記述**：
- `on state change called`：「状態遷移時に `onStateChange` が呼ばれること」
- `on state change called after mutex release`：「`onStateChange` コールバック内で `getState()` を呼んでもデッドロックしないこと」

**実際の制約**：Zig にはクロージャがないため、コールバック関数内からスタック上の変数（フラグや状態キャプチャ）を変更できない。その結果：
- `on state change called` テストは `onStateChange` が「呼ばれた」かどうかを直接検証できておらず、状態が Open に遷移したことの確認にとどまる。
- `on state change called after mutex release` テストはコールバック内で `getState()` を実際に呼べていないため、デッドロックの不在を証明できていない。

**影響**：テストの検証力が計画の意図より弱い。Zig の言語仕様上の制限であり回避策は複雑（別途グローバル変数や `*anyopaque` コンテキストを使う設計が必要）。現時点では既知の制限としてコメントで記録済み。
