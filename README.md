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
  "creatorLoginId": "DOMAIN\\organizer",
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
> バージョンアップ前に作成されたイベントデータには、以下のフィールドが存在しない場合があります。  
>
> | フィールド | 影響 |
> |---|---|
> | 参加者の `loginId` | 表示のみ可。再回答時は新しいエントリを作成（自動紐付けなし） |
> | イベントの `creatorLoginId` | 管理者メニューが誰にも表示されず、締め切り・削除が不可 |
>
> `creatorLoginId` がない旧イベントは**閲覧・回答のみ可能で、締め切り・削除はできません**。  
> これらを管理する必要がある場合は、アップグレード前に対象イベントの締め切り・削除を完了してください。  
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
IISを停止した状態で以下の手順を実施してください。

**ステップ1: バックアップと移行**

```powershell
$ErrorActionPreference = "Stop"

$site       = "C:\inetpub\wwwroot\chouseisan"   # 実際のパスに変更してください
$oldPath    = "$site\data"
$newPath    = "$site\App_Data\chouseisan"
# バックアップはApp_Data配下へ保存（最低限Webからの直接取得を防止）
# 推奨: サイトディレクトリ外・別ディスクへ保存し、IISアプリプールユーザーの書き込みを禁止する
# 例: $backupPath = "D:\chouseisan-backups\data_backup_$(Get-Date -Format yyyyMMddHHmmss)"
$backupPath = "$site\App_Data\data_backup_$(Get-Date -Format yyyyMMddHHmmss)"

# 旧データをバックアップ
New-Item -ItemType Directory -Force -Path "$site\App_Data"
Copy-Item $oldPath $backupPath -Recurse -ErrorAction Stop

# 新保存先へコピー
New-Item -ItemType Directory -Force -Path $newPath
Get-ChildItem "$oldPath\evt*.json" | Copy-Item -Destination $newPath -ErrorAction Stop
```

**ステップ2: ハッシュ検証**

```powershell
$ErrorActionPreference = "Stop"

$oldFiles = Get-ChildItem "$oldPath\evt*.json" | Sort-Object Name
$newFiles = Get-ChildItem "$newPath\evt*.json" | Sort-Object Name

if ($oldFiles.Count -ne $newFiles.Count) {
    throw "ファイル数不一致: 旧=$($oldFiles.Count) 新=$($newFiles.Count)"
}

for ($i = 0; $i -lt $oldFiles.Count; $i++) {
    if ($oldFiles[$i].Name -ne $newFiles[$i].Name) {
        throw "ファイル名不一致: 旧=$($oldFiles[$i].Name) 新=$($newFiles[$i].Name)"
    }
    $h1 = (Get-FileHash $oldFiles[$i].FullName).Hash
    $h2 = (Get-FileHash $newFiles[$i].FullName).Hash
    if ($h1 -ne $h2) {
        throw "ハッシュ不一致: $($oldFiles[$i].Name)"
    }
}
Write-Host "検証OK: 全ファイル一致"
```

**ステップ3: IIS起動後の確認**

1. IISアプリプールユーザーに `App_Data\` への読み書き権限があること
2. 既存の共有URLでイベントを読み込めること

**ステップ4: 旧ディレクトリの処置**

ハッシュ検証・動作確認後も、旧 `data\` ディレクトリはすぐに削除せず、一定期間バックアップとして保持することを推奨します。  
当面の間はIISの認可設定でアクセスを拒否してWebからの直接取得を防いでください。

**ロールバック手順**: 問題が発生した場合は、IISを停止して `$newPath` の内容を削除し、`$backupPath` の内容を `$oldPath` へコピーしてから旧バージョンを再デプロイしてください。

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
- フォールバックログ (`App_Data/chouseisan_error.log`) には、WindowsログインID・内部例外メッセージ・スタックトレース・内部ファイルパスが記録されます。ログを収集・転送する場合は機密情報として取り扱い、アクセス権限を最小化してください
