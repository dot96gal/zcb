# zcb

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zcb/)
[![CI](https://github.com/dot96gal/zcb/actions/workflows/ci.yml/badge.svg)](https://github.com/dot96gal/zcb/actions/workflows/ci.yml)
[![Release](https://github.com/dot96gal/zcb/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zcb/actions/workflows/release.yml)

Zig のサーキットブレーカーライブラリ。

> **注意:** このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でフォークし、独自に管理されることをおすすめします。

## 要件

- Zig 0.16.0 以上

---

## 利用者向け

### インストール

#### 1. `build.zig.zon` に zcb を追加する

最新のタグは [GitHub Releases](https://github.com/dot96gal/zcb/releases) で確認できる。

以下のコマンドを実行すると、`build.zig.zon` の `.dependencies` に自動的に追加される。

```sh
zig fetch --save https://github.com/dot96gal/zcb/archive/refs/tags/<version>.tar.gz
```

```zig
// build.zig.zon（自動追加される内容の例）
.dependencies = .{
    .zcb = .{
        .url = "https://github.com/dot96gal/zcb/archive/refs/tags/<version>.tar.gz",
        .hash = "<hash>",
    },
},
```

#### 2. `build.zig` で zcb モジュールをインポートする

```zig
const zcb_dep = b.dependency("zcb", .{ .target = target, .optimize = optimize });
const zcb_mod = zcb_dep.module("zcb");

exe.root_module.addImport("zcb", zcb_mod);
```

### 使い方

#### 基本的な使い方（execute）

`execute` は外部サービス呼び出しをラップする最もシンプルな方法。`pub fn call(self: *@This()) anyerror!T` を持つ構造体へのポインタを渡す。

```zig
const std = @import("std");
const zcb = @import("zcb");

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
        .timeout_ns = 30 * std.time.ns_per_s,
        .ready_to_trip = struct {
            fn call(counts: zcb.Counts) bool {
                return counts.consecutive_failures > 3;
            }
        }.call,
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

フィールドを持つリクエスト型も同様に使える。

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

#### Two-Step パターン（allow / done）

HTTP ミドルウェアなど、リクエスト開始と応答受信が分離している場合に使用する。

> **注意:** `token.done()` の呼び忘れはカウント更新漏れを招く。リクエスト開始と完了の分離が不要な場合は `execute` を優先すること。

```zig
const token = cb.allow(io) catch |err| switch (err) {
    error.OpenState => return sendError(503, "circuit open"),
    error.TooManyRequests => return sendError(429, "too many requests"),
    else => |e| return e,
};

const resp = sendRequest(req);
token.done(io, resp.status < 500);
```

`token.done()` は必ず呼ぶこと。呼び忘れた場合はカウントが更新されない。二重呼び出しは generation 不一致でスキップされる（べき等）。

#### サンプルの実行

```sh
mise run example:basic       # execute を使った基本例
mise run example:allow-done  # Two-Step パターンの例
```

### API リファレンス

#### Config

| フィールド | 型 | デフォルト | 説明 |
|-----------|-----|-----------|------|
| `name` | `[]const u8` | `""` | ブレーカーの識別名 |
| `max_requests` | `u32` | `1` | Half-Open 状態で通過を許可する最大リクエスト数。`0` 指定時は `1` に正規化される |
| `interval_ns` | `u64` | `0` | Closed 状態でカウンターをリセットするサイクル間隔（ナノ秒）。`0` で無効 |
| `timeout_ns` | `u64` | `60s` | Open 状態の持続時間（ナノ秒）。経過後に Half-Open へ遷移する |
| `ready_to_trip` | `?*const fn(Counts) bool` | `null` | Open への遷移条件。`null` の場合は連続失敗数 > `default_consecutive_failures_threshold`（5）をデフォルト条件とする |
| `is_successful` | `?*const fn(anyerror) bool` | `null` | エラーを成功と見なすかどうかの判定。`null` の場合はすべてのエラーを失敗と判定する |
| `on_state_change` | `?StateChangeCallback` | `null` | 状態変化時のコールバック。`null` の場合は何もしない。詳細は `StateChangeCallback` を参照 |
| `clock` | `Clock` | `Clock.system` | 時刻取得の実装。テスト時は `TestClock.clock()` を渡す |

#### StateChangeCallback

`Config.on_state_change` に渡すコンテキスト付きコールバックの型。`Clock` と同様の設計で、任意のコンテキストポインタを一緒に渡せる。

| フィールド | 型 | 説明 |
|-----------|-----|------|
| `context` | `?*anyopaque` | コールバック実行時に `call_fn` へ渡すコンテキストポインタ。不要な場合は `null` |
| `call_fn` | `*const fn(?*anyopaque, []const u8, State, State) void` | 状態変化時に呼ばれる関数。引数は `(context, name, from, to)` の順 |

```zig
const MyCtx = struct { count: u32 = 0 };
var ctx = MyCtx{};

var cb = zcb.CircuitBreaker.init(.{
    .on_state_change = .{
        .context = &ctx,
        .call_fn = struct {
            fn f(context: ?*anyopaque, _: []const u8, _: zcb.State, _: zcb.State) void {
                const c: *MyCtx = @ptrCast(@alignCast(context.?));
                c.count += 1;
            }
        }.f,
    },
});
```

#### Error

| エラー | 発生条件 | 対処法 |
|--------|---------|--------|
| `error.OpenState` | Open 状態でリクエストが拒否された | フォールバック処理または `503 Service Unavailable` を返す |
| `error.TooManyRequests` | Half-Open 状態で `max_requests` を超えた | リトライ待機または `429 Too Many Requests` を返す |

---

## 開発者向け

### 必要なツール

| ツール | 説明 |
|-------|------|
| [mise](https://mise.jdx.dev/) | ツールバージョン管理（Zig・zls を自動インストール） |
| `zig-lint` | Zig 簡易リントスクリプト（`~/.local/bin/` にインストール済み） |
| `zig-release` | バージョン更新・タグ付けスクリプト（`~/.local/bin/` にインストール済み） |

### セットアップ

```sh
git clone https://github.com/dot96gal/zcb
cd zcb
mise install
```

### タスク一覧

| コマンド | 説明 |
|---------|------|
| `mise run fmt` | フォーマット |
| `mise run fmt-check` | フォーマットチェック |
| `mise run lint` | 命名規則チェック（camelCase / PascalCase / SCREAMING_SNAKE_CASE） |
| `mise run build` | ビルド |
| `mise run test` | テスト（20 件） |
| `mise run example:basic` | execute を使った基本例を実行 |
| `mise run example:allow-done` | Two-Step パターンの例を実行 |
| `mise run build-docs` | API ドキュメントを生成 |
| `mise run serve-docs` | ドキュメントをローカルサーバーで配信（Ctrl+C で停止） |
| `mise run release X.Y.Z` | バージョン更新・コミット・タグ・プッシュを一括実行（例: 1.0.0） |

### ファイル構成

```
zcb/
├── src/
│   ├── root.zig              # 公開 API の再エクスポート
│   └── circuit_breaker.zig   # CircuitBreaker 実装本体
├── example/
│   ├── basic.zig             # execute を使った基本例
│   └── allow_done.zig        # Two-Step パターン（allow / done）の例
├── build.zig                 # ビルドスクリプト
├── build.zig.zon             # 依存パッケージ定義
└── mise.toml                 # ツールバージョンとタスク定義
```

### 状態遷移

```
[Closed] ──失敗 + ready_to_trip(counts)==true──▶ [Open]
   │                                               │
   │ interval_ns 経過でカウンターリセット            │ timeout_ns 経過
   ▼                                               ▼
[Closed]                                      [Half-Open]
                                                   │
                            連続成功 >= max_requests ──▶ [Closed]
                            1回でも失敗            ──▶ [Open]
```

### 世代管理（generation）

リクエスト実行中に別スレッドが状態遷移を起こした場合、古い世代の結果はカウントしない。`execute` / `allow` 呼び出し時に generation を記録し、結果処理時に現在の generation と照合する。不一致の場合はスキップされる。

```
スレッド A: beforeRequest() → _generation=5
スレッド B: 失敗 → Open 遷移 → _generation=6
スレッド A: afterRequest(_generation=5) → _generation(6) != 5 → スキップ
```

### コーディング規約

[Zig スタイルガイド](https://ziglang.org/documentation/master/#Style-Guide) に従う。

### テスト

```sh
mise run test
```

---

## ライセンス

[MIT](LICENSE)
