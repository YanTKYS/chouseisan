# 調整さん - 日程調整ツール

社内向けの日程調整Webアプリケーションです。イベントの候補日を作成して参加者に共有し、各自の出欠を○△×で回答してもらうことができます。

## 特徴

- **ActiveDirectory連携**: Windowsログインユーザー名を自動取得し、参加者名フィールドに初期表示
- **URLシェア**: イベント作成後にURLを参加者へ共有するだけで利用可能
- **シンプルなUI**: ブラウザのみで動作、インストール不要
- **単一ファイル構成**: `default.aspx` 1ファイルでフロントエンドとAPIを兼務

## 技術スタック

| 項目 | 内容 |
|------|------|
| サーバーサイド | ASP.NET Web Forms (C#) / .NET Framework 4.7 |
| フロントエンド | HTML / CSS / jQuery 3.6.0 |
| データ保存 | JSONファイル (`../chouseisan/data/`) |
| 認証 | Windows認証 + Active Directory (`System.DirectoryServices.AccountManagement`) |

## 機能

### イベント作成
- イベント名と候補日（1行1件）を入力してイベントページを生成
- 作成後のURLを参加者へ共有

### 回答
- 候補日ごとに ○（参加可）・△（未定）・×（参加不可）を選択して登録
- 同名で再送信すると回答を上書き更新

### 管理機能
- **確定して締め切る**: これ以上の回答受付を停止（ロック）
- **削除**: イベントデータを完全削除

## APIエンドポイント

すべて `default.aspx` へのリクエストで処理されます（クエリパラメータ `mode` で動作を切り替え）。

| mode | メソッド | 説明 |
|------|----------|------|
| `create` | POST | イベント新規作成 |
| `load` | GET | イベントデータ取得 |
| `update` | POST | 参加者の回答登録・更新 |
| `lock` | POST | イベントを締め切る |
| `delete` | POST | イベント削除 |

## データ構造

イベントデータは `data/{eventId}.json` として保存されます。

```json
{
  "id": "evt0f3c1a2b4d5e6f708192a3b4c5d6e7f8",
  "title": "第3回DX推進会議",
  "locked": false,
  "dates": ["5/20 10:00", "5/20 13:00", "5/21 10:00"],
  "participants": [
    {
      "name": "山田 太郎",
      "answers": [2, 1, 0],
      "comment": "午後は外出予定"
    }
  ],
  "creatorLoginId": "DOMAIN\\yamada"
}
```

- イベントIDは `evt` + GUID（32桁の小文字16進）形式で、サーバー側でこの形式のみを受け付けます
- 回答値の意味: `2` = ○（参加可）、`1` = △（未定）、`0` = ×（参加不可）
- `creatorLoginId` は作成者のWindowsログインIDです。締め切り・削除はこのユーザーのみ実行できます（大文字小文字は区別しません）。この項目が無い旧データは全員が管理操作可能として扱われます

### APIレスポンス

処理結果は常にJSONで返されます。

| 内容 | レスポンス例 |
|------|--------------|
| 成功 | `{"status":"ok"}` / `{"status":"ok","id":"evt..."}` |
| 失敗 | `{"status":"error","msg":"エラー内容"}` |

`mode=load` の成功時のみ、イベント情報（`id` / `title` / `locked` / `dates` / `participants` / `isOwner`）を返します。想定外の内部エラーの詳細はクライアントへ返さず、汎用メッセージに置き換えられます。

## ファイル構成

```
chouseisan/
├── default.aspx       # アプリ本体（サーバーサイドC# + HTML/CSS/JS）
├── web.config         # ASP.NET設定（.NET 4.7、AD参照設定）
└── data/              # イベントデータ保存ディレクトリ（自動生成）
    └── evt*.json
```

## セットアップ

### 前提条件
- IIS (Internet Information Services)
- .NET Framework 4.7 以上
- Windows認証が有効なActive Directory環境（任意）

### 手順
1. IISのサイトディレクトリにファイルを配置
2. `data/` ディレクトリへの書き込み権限をIISアプリプールユーザーに付与
3. `web.config` の設定を環境に合わせて調整
4. Windows認証を使用する場合は IIS の認証設定で「Windows 認証」を有効化

### jQuery
`./common/jquery-3.6.0.min.js` を別途配置してください（`default.aspx` からの相対パスで参照しています）。

## 文字コードに関する運用注意事項

### リポジトリと動作環境の文字コード

| 場所 | 文字コード |
|------|-----------|
| このリポジトリ | UTF-8 |
| IIS動作環境 | Shift-JIS |

リポジトリ上のファイルはUTF-8で管理されています。IIS環境ではShift-JISが必要なため、**デプロイ前に管理者がファイルをShift-JISに変換**してください。

### 変換手順（PowerShell）

```powershell
$src  = "default.aspx"        # UTF-8のファイル
$dest = "default_sjis.aspx"   # 変換後ファイル（IISに配置するもの）

$content = Get-Content $src -Encoding UTF8 -Raw
[System.IO.File]::WriteAllText(
    (Resolve-Path $dest).Path,
    $content,
    [System.Text.Encoding]::GetEncoding("shift_jis")
)
```

または `web.config` を変更して対応する方法もあります（後述）。

### web.config でUTF-8のまま動作させる場合（代替案）

`web.config` の `<system.web>` に以下を追加するとIISがUTF-8として処理します。ただし動作確認が必要です。

```xml
<globalization fileEncoding="utf-8" requestEncoding="utf-8" responseEncoding="utf-8" />
```

## 注意事項

- `web.config` の `customErrors` は `RemoteOnly`（サーバー上のブラウザでのみ詳細を表示）に設定しています。デバッグ時に外部端末からエラー詳細を確認したい場合のみ一時的に `Off` に変更してください
- `web.config` の `debug="true"` は開発用の設定です。本番運用では `false` を推奨します
- データファイルはWebルートの親ディレクトリ (`../chouseisan/data/`) に保存されます。IISの設定でWebから直接アクセスできないパスにすることを確認してください
- データファイルの読み書きはアプリケーション内で直列化していますが、複数のワーカープロセス（Webガーデン／複数サーバー構成）では同時更新の保護が効きません。単一ワーカープロセスで運用してください
