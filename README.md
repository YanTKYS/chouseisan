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
  "id": "evt0123456789abcdef0123456789abcdef",
  "title": "第3回DX推進会議",
  "locked": false,
  "dates": ["5/20 10:00", "5/20 13:00", "5/21 10:00"],
  "participants": [
    {
      "name": "山田 太郎",
      "answers": [2, 1, 0],
      "comment": "午後は外出予定"
    }
  ]
}
```

回答値の意味: `2` = ○（参加可）、`1` = △（未定）、`0` = ×（参加不可）

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
- **Windows認証が有効なActive Directory環境（必須）**  
  Windows認証なしではイベントの作成・管理ができません。IISの認証設定で「Windows 認証」を有効化してください。

### 手順
1. IISのサイトディレクトリにファイルを配置
2. `data/` ディレクトリへの書き込み権限をIISアプリプールユーザーに付与
3. `web.config` の設定を環境に合わせて調整
4. IIS の認証設定で「Windows 認証」を有効化し、「匿名認証」を無効化

### jQuery
`./common/jquery-3.6.0.min.js` を別途配置してください（`default.aspx` からの相対パスで参照しています）。

## 文字コード

リポジトリおよびIIS動作環境ともに **UTF-8** で統一されています。`web.config` に以下の設定が含まれているため、デプロイ時の文字コード変換は不要です。

```xml
<globalization fileEncoding="utf-8" requestEncoding="utf-8" responseEncoding="utf-8" />
```

## 注意事項

- `customErrors mode="RemoteOnly"` が設定済みです。本番環境でも詳細なエラー情報がリモートクライアントに表示されることはありません
- データファイルはWebルートの親ディレクトリ (`../chouseisan/data/`) に保存されます。IISの設定でWebから直接アクセスできないパスにすることを確認してください
- **IIS Web Gardenは無効（ワーカープロセス数=1）にしてください。** ファイルベースのデータ保存を採用しているため、複数ワーカープロセスによる同時書き込みで更新が失われる場合があります
