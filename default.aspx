<%@ Page Language="C#" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Collections.Generic" %>
<%@ Import Namespace="System.Web.Script.Serialization" %>
<%@ Import Namespace="System.Text" %>
<!-- AD連携用名前空間の追加 -->
<%@ Import Namespace="System.DirectoryServices.AccountManagement" %>
<%@ Import Namespace="System.Text.RegularExpressions" %>

<script runat="server">
    // =============================================================================
    // メンバ変数: HTML側で利用するため public で定義
    // =============================================================================
    public string UserDisplayName = "";
    public string CsrfToken = "";

    // =============================================================================
    // データクラス定義
    // =============================================================================
    public class EventData
    {
        public string id { get; set; }
        public string title { get; set; }
        public bool locked { get; set; } 
        public List<string> dates { get; set; }
        public List<Participant> participants { get; set; }
        public string creatorLoginId { get; set; }
    }

    public class Participant
    {
        public string loginId { get; set; }
        public string name { get; set; }
        public List<int> answers { get; set; }
        public string comment { get; set; }
    }

    public class AppException : Exception
    {
        public int HttpStatus { get; private set; }
        public AppException(string message, int httpStatus = 400) : base(message) { HttpStatus = httpStatus; }
    }

    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, object> _fileLocks =
        new System.Collections.Concurrent.ConcurrentDictionary<string, object>();

    // =============================================================================
    // バックエンド処理
    // =============================================================================
    protected void Page_Load(object sender, EventArgs e)
    {
        string mode = Request.QueryString["mode"];

        // ---------------------------------------------------------
        // 通常アクセス時 (HTML表示)
        // ---------------------------------------------------------
        if (string.IsNullOrEmpty(mode)) 
        {
            if (Session["CsrfToken"] == null)
                Session["CsrfToken"] = Guid.NewGuid().ToString("N");
            CsrfToken = (string)Session["CsrfToken"];

            string currentLoginId = User.Identity.Name;
            string cachedLoginId = Session["UserLoginId"] as string;
            if (!string.IsNullOrEmpty(cachedLoginId) &&
                !string.Equals(currentLoginId, cachedLoginId, StringComparison.OrdinalIgnoreCase))
            {
                Session["UserDisplayName"] = null;
                Session["CsrfToken"] = Guid.NewGuid().ToString("N");
                CsrfToken = (string)Session["CsrfToken"];
            }
            Session["UserLoginId"] = currentLoginId;

            if (Session["UserDisplayName"] != null)
            {
                UserDisplayName = (string)Session["UserDisplayName"];
            }
            else
            {
                if (!string.IsNullOrEmpty(currentLoginId))
                {
                    try
                    {
                        using (PrincipalContext ctx = new PrincipalContext(ContextType.Domain))
                        {
                            UserPrincipal user = UserPrincipal.FindByIdentity(ctx, currentLoginId);
                            UserDisplayName = (user != null && !string.IsNullOrEmpty(user.DisplayName))
                                ? user.DisplayName
                                : currentLoginId;
                        }
                    }
                    catch
                    {
                        UserDisplayName = currentLoginId;
                    }
                    Session["UserDisplayName"] = UserDisplayName;
                }
            }
            return;
        }

        // ---------------------------------------------------------
        // API処理 (AJAX)
        // ---------------------------------------------------------
        Response.ContentType = "application/json";
        Response.ContentEncoding = Encoding.UTF8;
        Response.Cache.SetCacheability(HttpCacheability.NoCache);

        var serializer = new JavaScriptSerializer();

        try
        {
            if (!User.Identity.IsAuthenticated || string.IsNullOrEmpty(User.Identity.Name))
                throw new AppException("認証が必要です。", 401);

            string apiLoginId = User.Identity.Name;
            string cachedApiLoginId = Session["UserLoginId"] as string;
            if (string.IsNullOrEmpty(cachedApiLoginId))
            {
                Session["UserLoginId"] = apiLoginId;
            }
            else if (!string.Equals(apiLoginId, cachedApiLoginId, StringComparison.OrdinalIgnoreCase))
            {
                Session["UserDisplayName"] = null;
                Session["CsrfToken"] = null;
                throw new AppException("ユーザーが変更されました。ページを再読み込みしてください。", 401);
            }

            if (mode == "create" || mode == "update" || mode == "lock" || mode == "delete")
            {
                if (Request.HttpMethod != "POST")
                {
                    Response.AddHeader("Allow", "POST");
                    throw new AppException("Method Not Allowed", 405);
                }
                string reqToken = Request.Headers["X-CSRF-Token"];
                if (string.IsNullOrEmpty(reqToken) || reqToken != (string)Session["CsrfToken"])
                {
                    throw new AppException("CSRFトークンが無効です。", 403);
                }
            }

            if (mode != "create" && mode != "load" && mode != "update" && mode != "lock" && mode != "delete")
                throw new AppException("Unknown mode.", 400);

            string dataDir = Server.MapPath("../chouseisan/data/");
            if (!Directory.Exists(dataDir)) Directory.CreateDirectory(dataDir);

            if (mode == "create")
            {
                string title = (Request.Form["title"] ?? "").Trim();
                if (string.IsNullOrEmpty(title) || title.Length > 100) throw new AppException("イベント名が無効です。");
                string rawDates = Request.Form["dates"];
                if (string.IsNullOrWhiteSpace(rawDates)) throw new AppException("入力不足");
                var rawDateLines = rawDates.Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries);
                var dateList = new List<string>();
                foreach (var dl in rawDateLines) { var t = dl.Trim(); if (!string.IsNullOrEmpty(t)) dateList.Add(t); }
                if (dateList.Count == 0 || dateList.Count > 31 || dateList.Exists(d => d.Length > 50))
                    throw new AppException("候補日の形式が不正です。");

                if (string.IsNullOrEmpty(User.Identity.Name))
                    throw new AppException("このシステムはWindows認証が必要です。管理者にお問い合わせください。", 403);
                string eventId = "evt" + Guid.NewGuid().ToString("N");
                var newEvent = new EventData
                {
                    id = eventId,
                    title = title,
                    locked = false,
                    dates = dateList,
                    participants = new List<Participant>(),
                    creatorLoginId = User.Identity.Name
                };
                SaveJson(dataDir + eventId + ".json", newEvent);
                Response.Write(serializer.Serialize(new { status = "ok", id = eventId }));
            }
            else if (mode == "load")
            {
                string id = Request.QueryString["id"];
                if (!IsValidEventId(id)) throw new AppException("Invalid event ID.");
                string path = dataDir + id + ".json";
                if (File.Exists(path))
                {
                    string json;
                    try { json = File.ReadAllText(path, Encoding.UTF8); }
                    catch (FileNotFoundException) { throw new AppException("Not found.", 404); }
                    var eventData = serializer.Deserialize<EventData>(json);
                    bool isOwner = !string.IsNullOrEmpty(eventData.creatorLoginId) &&
                                   string.Equals(eventData.creatorLoginId, User.Identity.Name, StringComparison.OrdinalIgnoreCase);
                    string myLoginId = User.Identity.Name;
                    var safeParticipants = new List<object>();
                    foreach (var p in eventData.participants)
                    {
                        safeParticipants.Add(new {
                            name = p.name,
                            answers = p.answers,
                            comment = p.comment,
                            isMe = (!string.IsNullOrEmpty(p.loginId) && string.Equals(p.loginId, myLoginId, StringComparison.OrdinalIgnoreCase))
                        });
                    }
                    Response.Write(serializer.Serialize(new {
                        id = eventData.id,
                        title = eventData.title,
                        locked = eventData.locked,
                        dates = eventData.dates,
                        participants = safeParticipants,
                        isOwner = isOwner
                    }));
                }
                else
                {
                    throw new AppException("Not found.", 404);
                }
            }
            else if (mode == "update")
            {
                string id = Request.Form["id"];
                if (!IsValidEventId(id)) throw new AppException("Invalid event ID.");
                string path = dataDir + id + ".json";
                if (!File.Exists(path)) throw new AppException("データなし", 404);
                lock (_fileLocks.GetOrAdd(id, new object()))
                {
                    if (!File.Exists(path)) throw new AppException("データなし", 404);
                    string json = File.ReadAllText(path, Encoding.UTF8);
                    var eventData = serializer.Deserialize<EventData>(json);

                    if (eventData.locked) throw new AppException("このイベントは既に締め切られています。", 409);

                    string name = (Request.Form["name"] ?? "").Trim();
                    if (string.IsNullOrEmpty(name) || name.Length > 50) throw new AppException("名前が無効です。");
                    string ansStr = Request.Form["answers"];
                    if (string.IsNullOrEmpty(ansStr)) throw new AppException("回答が指定されていません。");
                    var answers = new List<int>();
                    foreach (var s in ansStr.Split(','))
                    {
                        int v;
                        if (!int.TryParse(s.Trim(), out v) || v < 0 || v > 2) throw new AppException("回答値が不正です。");
                        answers.Add(v);
                    }
                    if (answers.Count != eventData.dates.Count) throw new AppException("回答数が候補日数と一致しません。");
                    string comment = Request.Form["comment"] ?? "";
                    if (comment.Length > 200) throw new AppException("コメントが長すぎます。");

                    string loginId = User.Identity.Name;
                    var person = eventData.participants.Find(p => string.Equals(p.loginId, loginId, StringComparison.OrdinalIgnoreCase));
                    if (person != null) { person.name = name; person.answers = answers; person.comment = comment; }
                    else
                    {
                        int activeCount = 0;
                        foreach (var p2 in eventData.participants)
                            if (!string.IsNullOrEmpty(p2.loginId)) activeCount++;
                        if (activeCount >= 100)
                            throw new AppException("参加者数の上限（100名）に達しています。", 400);
                        eventData.participants.Add(new Participant { loginId = loginId, name = name, answers = answers, comment = comment });
                    }

                    SaveJson(path, eventData);
                }
                Response.Write(serializer.Serialize(new { status = "ok" }));
            }
            else if (mode == "lock")
            {
                string id = Request.Form["id"];
                if (!IsValidEventId(id)) throw new AppException("Invalid event ID.");
                string path = dataDir + id + ".json";
                if (!File.Exists(path)) throw new AppException("Not found.", 404);
                lock (_fileLocks.GetOrAdd(id, new object()))
                {
                    if (!File.Exists(path)) throw new AppException("Not found.", 404);
                    string json = File.ReadAllText(path, Encoding.UTF8);
                    var eventData = serializer.Deserialize<EventData>(json);
                    if (string.IsNullOrEmpty(eventData.creatorLoginId) ||
                        !string.Equals(eventData.creatorLoginId, User.Identity.Name, StringComparison.OrdinalIgnoreCase))
                        throw new AppException("この操作を行う権限がありません。", 403);
                    eventData.locked = true;
                    SaveJson(path, eventData);
                    Response.Write(serializer.Serialize(new { status = "ok" }));
                }
            }
            else if (mode == "delete")
            {
                string id = Request.Form["id"];
                if (!IsValidEventId(id)) throw new AppException("Invalid event ID.");
                string path = dataDir + id + ".json";
                if (!File.Exists(path)) throw new AppException("Not found.", 404);
                lock (_fileLocks.GetOrAdd(id, new object()))
                {
                    if (!File.Exists(path)) throw new AppException("Not found.", 404);
                    string json = File.ReadAllText(path, Encoding.UTF8);
                    var eventData = serializer.Deserialize<EventData>(json);
                    if (string.IsNullOrEmpty(eventData.creatorLoginId) ||
                        !string.Equals(eventData.creatorLoginId, User.Identity.Name, StringComparison.OrdinalIgnoreCase))
                        throw new AppException("この操作を行う権限がありません。", 403);
                    File.Delete(path);
                    object removedLock;
                    _fileLocks.TryRemove(id, out removedLock);
                    Response.Write(serializer.Serialize(new { status = "ok" }));
                }
            }
        }
        catch (AppException ex)
        {
            if (Response.StatusCode == 200) Response.StatusCode = ex.HttpStatus;
            Response.Write(serializer.Serialize(new { status = "error", msg = ex.Message }));
        }
        catch (Exception ex)
        {
            if (Response.StatusCode == 200) Response.StatusCode = 500;
            string logMsg = string.Format(
                "Chouseisan: mode={0} id={1} user={2}\r\n{3}",
                SanitizeLogValue(mode),
                SanitizeLogValue(Request.QueryString["id"] ?? Request.Form["id"] ?? "(none)"),
                User.Identity.IsAuthenticated ? User.Identity.Name : "(unauthenticated)",
                ex.ToString());
            bool logged = false;
            try
            {
                System.Diagnostics.EventLog.WriteEntry("Application", logMsg, System.Diagnostics.EventLogEntryType.Error);
                logged = true;
            }
            catch { }
            if (!logged)
            {
                try { System.Diagnostics.Trace.TraceError(logMsg); }
                catch { }
            }
            Response.Write(serializer.Serialize(new { status = "error", msg = "サーバー処理中にエラーが発生しました。" }));
        }
        Response.Flush();
        Response.SuppressContent = true;
        Context.ApplicationInstance.CompleteRequest();
    }

    private bool IsValidEventId(string id)
    {
        return !string.IsNullOrEmpty(id) && System.Text.RegularExpressions.Regex.IsMatch(id, @"^evt[0-9a-f]{32}$");
    }

    private string SanitizeLogValue(string value)
    {
        if (string.IsNullOrEmpty(value)) return "(empty)";
        var sb = new StringBuilder();
        foreach (char c in value)
            if (c >= 0x20) sb.Append(c);
        string result = sb.ToString();
        return result.Length > 100 ? result.Substring(0, 100) + "..." : result;
    }

    private void SaveJson(string path, object data)
    {
        var serializer = new JavaScriptSerializer();
        string json = serializer.Serialize(data);
        string tempPath = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(tempPath, json, Encoding.UTF8);
            int retries = 3;
            while (true)
            {
                try
                {
                    if (File.Exists(path))
                        File.Replace(tempPath, path, null);
                    else
                        File.Move(tempPath, path);
                    break;
                }
                catch (IOException)
                {
                    if (--retries <= 0) throw;
                    System.Threading.Thread.Sleep(50);
                }
            }
            tempPath = null;
        }
        finally
        {
            if (tempPath != null && File.Exists(tempPath)) File.Delete(tempPath);
        }
    }
</script>

<!-- 
=============================================================================
 フロントエンド画面
=============================================================================
-->
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>調整さん - 庁内日程調整ツール</title>
    <!-- jQueryパス: 指定の通り -->
    <script src="./common/jquery-3.6.0.min.js"></script>
    <style>
        body { font-family: "Meiryo", "Hiragino Kaku Gothic ProN", sans-serif; background: #f4f4f4; padding: 20px; color: #333; }
        .container { max-width: 800px; margin: 0 auto; background: #fff; padding: 30px; border-radius: 8px; box-shadow: 0 4px 10px rgba(0,0,0,0.1); }
        
        /* ヘッダー */
        .app-header { border-bottom: 2px solid #007bff; padding-bottom: 15px; margin-bottom: 30px; display: flex; align-items: baseline; flex-wrap: wrap; }
        .logo-main { font-size: 32px; font-weight: bold; color: #007bff; margin-right: 15px; letter-spacing: 0.05em; }
        .logo-sub { font-size: 16px; color: #666; font-weight: normal; }
        
        /* ログインユーザー表示 */
        .login-info { margin-left: auto; font-size: 14px; color: #555; background: #eee; padding: 5px 10px; border-radius: 4px; }

        h2 { font-size: 20px; margin-bottom: 15px; border-left: 5px solid #007bff; padding-left: 10px; color: #444; }
        .locked-title { border-color: #6c757d; color: #6c757d; }

        label { display: block; margin-top: 20px; font-weight: bold; font-size: 14px; }
        input[type="text"], textarea { width: 100%; padding: 10px; margin-top: 5px; box-sizing: border-box; border: 1px solid #ccc; border-radius: 4px; font-size: 16px; }
        button { padding: 12px 24px; border: none; border-radius: 4px; cursor: pointer; font-size: 16px; color: white; margin-top: 25px; transition: opacity 0.2s; }
        button:hover { opacity: 0.9; }
        
        .btn-primary { background: #007bff; }
        .btn-lock { background: #28a745; margin-left: 10px; font-size: 14px; padding: 8px 16px; }
        .btn-delete { background: #dc3545; margin-left: 10px; font-size: 14px; padding: 8px 16px; }

        .admin-area { margin-top: 50px; padding-top: 20px; border-top: 1px dashed #ddd; text-align: right; }

        table { width: 100%; border-collapse: collapse; margin-top: 20px; font-size: 14px; }
        th, td { border: 1px solid #ddd; padding: 10px; text-align: center; }
        th { background: #f8f9fa; font-weight: bold; }
        .symbol-ok { color: #d9534f; font-weight: bold; font-size: 1.2em; }
        .symbol-tri { color: #f0ad4e; font-weight: bold; font-size: 1.2em; }
        .symbol-ng { color: #0275d8; font-weight: bold; font-size: 1.2em; }
        
        .hidden { display: none; }
        .input-area { background: #eef2f7; padding: 20px; border-radius: 6px; margin-top: 30px; }
        .locked-msg { background: #fff3cd; color: #856404; padding: 15px; border: 1px solid #ffeeba; border-radius: 4px; margin-top: 20px; text-align: center; font-weight: bold;}
        .share-url-box { background: #f0f0f0; padding: 10px; border-radius: 4px; word-break: break-all; font-family: monospace; color: #007bff; }
        .copy-btn { margin-top: 6px; padding: 4px 12px; font-size: 12px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        .copy-btn:hover { background: #0056b3; }
        .copy-btn.copied { background: #28a745; }
        .locked-banner { background: #495057; color: white; padding: 12px 18px; border-radius: 4px; margin: 0 0 20px; font-weight: bold; text-align: center; font-size: 15px; }
        th:first-child, td:first-child { position: sticky; left: 0; z-index: 1; }
        th:first-child { background: #f8f9fa; }
        td:first-child { background: #fff; }
        .toast { position: fixed; bottom: 28px; left: 50%; transform: translateX(-50%); background: #323232; color: #fff; padding: 10px 24px; border-radius: 20px; font-size: 14px; opacity: 0; transition: opacity 0.3s; pointer-events: none; z-index: 9999; white-space: nowrap; }
        .toast.show { opacity: 1; }
        .inline-confirm { background: #fff3cd; border: 1px solid #ffc107; border-radius: 4px; padding: 12px 14px; margin-top: 10px; text-align: left; }
        .inline-confirm p { margin: 0 0 10px; font-size: 13px; color: #856404; }
        .btn-confirm-yes, .btn-confirm-cancel { padding: 5px 14px; font-size: 13px; border: none; border-radius: 4px; cursor: pointer; color: white; margin-top: 0; }
        .btn-confirm-cancel { background: #6c757d; margin-left: 8px; }
    </style>
</head>
<body>

<div class="container">
    <header class="app-header">
        <span class="logo-main">調整さん</span>
        <span class="logo-sub">庁内日程調整ツール</span>
        
        <!-- ログイン情報表示エリア -->
        <div class="login-info">
            Login: <strong><%= HttpUtility.HtmlEncode(UserDisplayName) %></strong>
        </div>
    </header>

    <!-- 新規作成画面 -->
    <div id="create-view">
        <h2>新規イベント作成</h2>
        <p style="font-size:14px; color:#666; margin-bottom:20px;">
            候補日程を入力してイベントページを作成します。<br>
            作成されたURLを参加者に共有してください。
        </p>
        
        <label>イベント名</label>
        <input type="text" id="new-title" placeholder="例：第3回DX推進会議">
        
        <label>候補日程（1行に1つ入力）</label>
        <textarea id="new-dates" rows="6" placeholder="5/20 10:00&#13;&#10;5/20 13:00&#13;&#10;5/21 10:00"></textarea>
        
        <button class="btn-primary" onclick="execCreateEvent()">イベントを作成する</button>
    </div>

    <!-- 調整・閲覧画面 -->
    <div id="schedule-view" class="hidden">
        <h2 id="evt-title">イベント名</h2>
        <div id="locked-banner" class="locked-banner hidden">このイベントは確定済みのため、回答を締め切っています</div>
        
        <div style="margin-bottom: 20px;">
            <span style="font-size:14px; font-weight:bold;">共有用URL：</span>
            <div id="share-url" class="share-url-box"></div>
            <button class="copy-btn" onclick="copyShareUrl()">URLをコピー</button>
        </div>

        <div id="table-container" style="overflow-x: auto;"></div>

        <!-- 入力エリア -->
        <div id="input-container" class="input-area">
            <h3 style="margin-top:0;">出欠を入力する</h3>
            <label>氏名</label>
            <!-- AD取得した氏名を初期値に設定するための場所 -->
            <input type="text" id="my-name" placeholder="所属 氏名">
            
            <div id="date-inputs"></div>
            
            <label>コメント（任意）</label>
            <input type="text" id="my-comment" placeholder="例：午後以降なら参加可能です">

            <button id="btn-submit" class="btn-primary" onclick="submitAnswer()">登録する</button>
        </div>

        <div id="locked-message" class="hidden locked-msg">
            このイベントは確定済みのため、回答を締め切りました。
        </div>

        <!-- 管理エリア -->
        <div class="admin-area hidden" id="admin-controls">
            <span style="font-size:0.9em; color:#666;">管理者メニュー：</span>
            <button class="btn-lock" onclick="execLockEvent()">確定して締め切る</button>
            <button class="btn-delete" onclick="execDeleteEvent()">削除する</button>
            <div id="inline-confirm" class="inline-confirm hidden">
                <p id="inline-confirm-msg"></p>
                <button id="btn-confirm-yes" class="btn-confirm-yes">はい</button>
                <button onclick="hideConfirm()" class="btn-confirm-cancel">キャンセル</button>
            </div>
        </div>
        
        <div style="margin-top:20px; text-align:right;">
            <a href="default.aspx" style="color:#007bff; text-decoration:none;">&laquo; トップに戻る</a>
        </div>
    </div>
</div>

<script>
    // サーバー側で取得した氏名をJS変数にセット (エスケープ処理付き)
    var currentUserDisplayName = "<%= HttpUtility.JavaScriptStringEncode(UserDisplayName) %>";
    var csrfToken = "<%= CsrfToken %>";

    var currentEventId = "";
    var eventData = null;

    $.ajaxSetup({ headers: { "X-CSRF-Token": csrfToken } });

    $(document).ajaxError(function(event, xhr, settings) {
        if (xhr.status === 404 && settings.url && settings.url.indexOf("mode=load") !== -1) {
            alert("イベントが見つかりません。削除された可能性があります。");
            window.location.href = "default.aspx";
            return;
        }
        var serverMsg = xhr.responseJSON && xhr.responseJSON.msg ? xhr.responseJSON.msg : null;
        if (xhr.status === 401) {
            alert(serverMsg || "認証エラーが発生しました。ページを再読み込みしてください。");
            var lastReload = parseInt(sessionStorage.getItem('_authReloadTime') || '0');
            if (Date.now() - lastReload > 10000) {
                sessionStorage.setItem('_authReloadTime', String(Date.now()));
                window.location.reload();
            }
            return;
        }
        if (xhr.status === 403) {
            alert(serverMsg || "セッションが期限切れ、または操作権限がありません。ページを再読み込みしてください。");
        } else if (xhr.status >= 400) {
            alert(serverMsg || "通信中にエラーが発生しました（" + xhr.status + "）。");
        }
    });

    $(document).ready(function(){
        // 氏名欄にAD名を自動セット
        if(currentUserDisplayName) {
            $("#my-name").val(currentUserDisplayName);
        }

        var params = new URLSearchParams(window.location.search);
        var id = params.get("id");
        if(id) loadEvent(id);
    });

    function execCreateEvent(){
        var title = $("#new-title").val();
        var dates = $("#new-dates").val();
        
        if(!title || !dates) { alert("イベント名と日程を入力してください"); return; }

        $.post("default.aspx?mode=create", {
            title: title,
            dates: dates
        }, function(res){
            if(res.status === "ok"){
                window.location.href = "default.aspx?id=" + res.id;
            } else {
                alert(res.msg);
            }
        });
    }

    function loadEvent(id){
        currentEventId = id;
        $.getJSON("default.aspx?mode=load&id=" + id, function(data){
            eventData = data;
            $("#create-view").addClass("hidden");
            $("#schedule-view").removeClass("hidden");
            
            $("#evt-title").text(data.title);
            document.title = data.title + " - 調整さん";
            $("#share-url").text(window.location.href);
            renderTable(data);
            
            if(data.locked) {
                $("#locked-banner").removeClass("hidden");
                $("#input-container").addClass("hidden");
            } else {
                $("#locked-banner").addClass("hidden");
                $("#input-container").removeClass("hidden");
                renderInputs(data);
            }

            if(data.isOwner) {
                $("#admin-controls").removeClass("hidden");
                if(data.locked) {
                    $(".btn-lock").hide();
                } else {
                    $(".btn-lock").show();
                }
            } else {
                $("#admin-controls").addClass("hidden");
            }
        });
    }

    function renderTable(data){
        if(data.participants.length === 0) {
            $("#table-container").html('<p style="color:#888; text-align:center; padding:20px;">まだ回答がありません。</p>');
            return;
        }
        var parts = [];
        parts.push('<table><thead><tr><th style="min-width:120px;">参加者</th>');
        data.dates.forEach(function(d){ parts.push('<th>' + escapeHtml(d) + '</th>'); });
        parts.push('<th style="min-width:150px;">コメント</th></tr></thead><tbody>');

        data.participants.forEach(function(p){
            parts.push('<tr><td>' + escapeHtml(p.name) + '</td>');
            p.answers.forEach(function(a){
                var sym = a===2 ? "○" : (a===1 ? "△" : "×");
                var cls = a===2 ? "symbol-ok" : (a===1 ? "symbol-tri" : "symbol-ng");
                parts.push('<td class="'+cls+'">' + sym + '</td>');
            });
            parts.push('<td style="text-align:left;">' + escapeHtml(p.comment) + '</td></tr>');
        });

        parts.push('<tr style="background:#ffffe0; font-weight:bold;"><td style="background:#ffffe0;">○の数</td>');
        for(var i=0; i<data.dates.length; i++){
            var count = 0;
            data.participants.forEach(function(p){ if(p.answers[i]===2) count++; });
            parts.push('<td>' + count + '</td>');
        }
        parts.push('<td>-</td></tr></tbody></table>');
        $("#table-container").html(parts.join(''));
    }

    function renderInputs(data){
        var myEntry = null;
        data.participants.forEach(function(p){ if(p.isMe) myEntry = p; });

        if (myEntry) {
            $("#my-name").val(myEntry.name);
            $("#my-comment").val(myEntry.comment || "");
        } else if (currentUserDisplayName) {
            $("#my-name").val(currentUserDisplayName);
        }

        var myAnswers = myEntry ? myEntry.answers : null;
        var parts = [];
        data.dates.forEach(function(d, idx){
            var val = (myAnswers && myAnswers[idx] !== undefined) ? myAnswers[idx] : 2;
            parts.push('<div style="margin-top:10px; border-bottom:1px dotted #ccc; padding-bottom:5px;">');
            parts.push('<span style="font-weight:bold;">' + escapeHtml(d) + '</span><br>');
            parts.push('<label style="display:inline-block; margin-right:15px; cursor:pointer;"><input type="radio" name="ans_'+idx+'" value="2"' + (val===2?' checked':'') + '> <span class="symbol-ok">○</span></label> ');
            parts.push('<label style="display:inline-block; margin-right:15px; cursor:pointer;"><input type="radio" name="ans_'+idx+'" value="1"' + (val===1?' checked':'') + '> <span class="symbol-tri">△</span></label> ');
            parts.push('<label style="display:inline-block; margin-right:15px; cursor:pointer;"><input type="radio" name="ans_'+idx+'" value="0"' + (val===0?' checked':'') + '> <span class="symbol-ng">×</span></label>');
            parts.push('</div>');
        });
        $("#date-inputs").html(parts.join(''));
    }

    function submitAnswer(){
        var name = $("#my-name").val();
        if(!name){ showToast("名前を入力してください"); return; }

        var answers = [];
        for(var i=0; i<eventData.dates.length; i++){
            answers.push($('input[name="ans_'+i+'"]:checked').val());
        }

        var $btn = $("#btn-submit").prop("disabled", true);
        $.post("default.aspx?mode=update", {
            id: currentEventId,
            name: name,
            answers: answers.join(","),
            comment: $("#my-comment").val()
        }, function(res){
            if(res.status === "ok"){
                loadEvent(currentEventId);
                showToast("登録しました。");
                $("#my-comment").val("");
            } else {
                showToast("エラー：" + res.msg);
            }
        }).always(function(){ $btn.prop("disabled", false); });
    }

    function execLockEvent() {
        showConfirm("本当に締め切りますか？締め切ると、これ以上回答を追加できなくなります。", function(){
            $.post("default.aspx?mode=lock", { id: currentEventId }, function(res){
                if(res.status === "ok") {
                    loadEvent(currentEventId);
                    showToast("締め切りました。");
                } else {
                    showToast("エラーが発生しました");
                }
            });
        }, "#28a745");
    }

    function execDeleteEvent() {
        showConfirm("本当に削除しますか？この操作は取り消せません。", function(){
            $.post("default.aspx?mode=delete", { id: currentEventId }, function(res){
                if(res.status === "ok") {
                    window.location.href = "default.aspx";
                } else {
                    showToast("エラーが発生しました");
                }
            });
        }, "#dc3545");
    }

    function copyShareUrl() {
        var url = $("#share-url").text();
        if(navigator.clipboard) {
            navigator.clipboard.writeText(url).then(function(){
                var $btn = $(".copy-btn");
                $btn.text("コピーしました！").addClass("copied");
                setTimeout(function(){ $btn.text("URLをコピー").removeClass("copied"); }, 2000);
            });
        } else {
            window.prompt("URL:", url);
        }
    }

    function showToast(msg) {
        var $t = $("#toast");
        $t.text(msg).addClass("show");
        setTimeout(function(){ $t.removeClass("show"); }, 2500);
    }

    function showConfirm(msg, action, btnColor) {
        $("#inline-confirm-msg").text(msg);
        $("#btn-confirm-yes").css("background", btnColor || "#dc3545")
            .off("click").on("click", function(){ hideConfirm(); action(); });
        $("#inline-confirm").removeClass("hidden");
    }

    function hideConfirm() {
        $("#inline-confirm").addClass("hidden");
    }

    function escapeHtml(str) {
        if(!str) return "";
        return str.replace(/[&<>"']/g, function(m) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[m];
        });
    }
</script>

<div id="toast" class="toast"></div>
</body>
</html>