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
| データ保存 | JSONファイル (`App_Data/chouseisan/`) |
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

イベントデータは `App_Data/chouseisan/{eventId}.json` として保存されます。

```json
{
  "id": "evt0123456789abcdef0123456789abcdef",
  "title": "第3回DX推進会議",
  "locked": false,
  "dates": ["5/20 10:00", "5/20 13:00", "5/21 10:00"],
  "participants": [
    {
      "loginId": "DOMAIN\\yamada",
      "name": "山田 太郎",
      "answers": [2, 1, 0],
      "comment": "午後は外出予定"
    }
  ]
}
```

回答値の意味: `2` = ○（参加可）、`1` = △（未定）、`0` = ×（参加不可）

> **注意: 既存データとの互換性**  
> バージョンアップ前に作成されたイベントの参加者データには `loginId` フィールドがありません。  
> 旧参加者エントリは表示のみで、再回答時は常に新しいエントリが作成されます（自動紐付けは行いません）。  
> 確実に移行するには、対象イベントを削除して再作成することを推奨します。

## ファイル構成

```
chouseisan/
├── default.aspx            # アプリ本体（サーバーサイドC# + HTML/CSS/JS）
├── web.config              # ASP.NET設定（.NET 4.7、AD参照設定）
└── App_Data/
    ├── chouseisan/         # イベントデータ保存ディレクトリ（自動生成）
    │   └── evt*.json
    └── chouseisan_error.log  # EventLog/Trace失敗時のフォールバックログ（自動生成）
```

## セットアップ

### 前提条件
- IIS (Internet Information Services)
- .NET Framework 4.7 以上
- **Windows認証が有効なActive Directory環境（必須）**  
  Windows認証なしではイベントの作成・管理ができません。IISの認証設定で「Windows 認証」を有効化してください。

### 手順
1. IISのサイトディレクトリにファイルを配置
2. `App_Data/` ディレクトリへの書き込み権限をIISアプリプールユーザーに付与
3. `web.config` の設定を環境に合わせて調整
4. IIS の認証設定で「Windows 認証」を有効化し、「匿名認証」を無効化

### 既存環境からのアップグレード

このバージョンからイベントデータの保存先が変更されました。

| | パス |
|---|---|
| 旧 | `chouseisan\data\` |
| 新 | `chouseisan\App_Data\chouseisan\` |

既存データを移行せずにアップグレードすると、全イベントが404（見つかりません）になります。  
IISを停止した状態で以下のPowerShellスクリプトを実行してください。

```powershell
$site    = "C:\inetpub\wwwroot\chouseisan"   # 実際のパスに変更してください
$oldPath = "$site\data"
$newPath = "$site\App_Data\chouseisan"

New-Item -ItemType Directory -Force -Path $newPath
Get-ChildItem "$oldPath\evt*.json" | Copy-Item -Destination $newPath
```

移行後の確認事項:

1. `$newPath` 内のJSONファイル数が `$oldPath` と一致すること
2. IISアプリプールユーザーに `App_Data\` への読み書き権限があること
3. IIS起動後、既存の共有URLでイベントを読み込めること
4. 確認後、旧 `data\` ディレクトリを削除すること（Webから直接取得できる状態を解消するため）

### jQuery
`./common/jquery-3.6.0.min.js` を別途配置してください（`default.aspx` からの相対パスで参照しています）。

## 文字コード

リポジトリおよびIIS動作環境ともに **UTF-8** で統一されています。`web.config` に以下の設定が含まれているため、デプロイ時の文字コード変換は不要です。

```xml
<globalization fileEncoding="utf-8" requestEncoding="utf-8" responseEncoding="utf-8" />
```

## 注意事項

- `customErrors mode="RemoteOnly"` が設定済みです。本番環境でも詳細なエラー情報がリモートクライアントに表示されることはありません
- データファイルは `App_Data/chouseisan/` に保存されます。ASP.NET の `App_Data` はフレームワークレベルでHTTPアクセスが拒否されるため、JSONに含まれるWindowsログインIDが直接取得されることはありません
- **IIS Web Gardenは無効（ワーカープロセス数=1）にしてください。** ファイルベースのデータ保存を採用しているため、複数ワーカープロセスによる同時書き込みで更新が失われる場合があります
- アプリ内のロックオブジェクトはイベント削除時に解放されます。削除せずに大量のイベントを作成し続ける場合は、定期的にIISアプリケーションプールをリサイクルしてメモリを解放してください
- 作成イベント数・JSONファイル数に上限はありません。長期運用ではデータディレクトリのディスク使用量を定期的に監視してください。古いイベントは手動または定期バッチで削除することを推奨します
