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
        public string name { get; set; }
        public List<int> answers { get; set; }
        public string comment { get; set; }
    }

    // =============================================================================
    // バックエンド処理
    // =============================================================================
    protected void Page_Load(object sender, EventArgs e)
    {
        string mode = Request["mode"];

        // ---------------------------------------------------------
        // 通常アクセス時 (HTML表示)
        // ---------------------------------------------------------
        if (string.IsNullOrEmpty(mode)) 
        {
            if (Session["UserDisplayName"] != null)
            {
                UserDisplayName = (string)Session["UserDisplayName"];
            }
            else
            {
                string loginId = User.Identity.Name;
                if (!string.IsNullOrEmpty(loginId))
                {
                    try
                    {
                        using (PrincipalContext ctx = new PrincipalContext(ContextType.Domain))
                        {
                            UserPrincipal user = UserPrincipal.FindByIdentity(ctx, loginId);
                            UserDisplayName = (user != null && !string.IsNullOrEmpty(user.DisplayName))
                                ? user.DisplayName
                                : loginId;
                        }
                    }
                    catch
                    {
                        UserDisplayName = loginId;
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

        string dataDir = Server.MapPath("../chouseisan/data/");
        if (!Directory.Exists(dataDir)) Directory.CreateDirectory(dataDir);

        var serializer = new JavaScriptSerializer();

        try
        {
            if (mode == "create")
            {
                string title = Request["title"];
                string rawDates = Request["dates"];
                if (string.IsNullOrEmpty(title) || string.IsNullOrEmpty(rawDates)) throw new Exception("入力不足");

                string eventId = "evt" + DateTime.Now.ToString("yyyyMMddHHmmss") + new Random().Next(100, 999);
                var newEvent = new EventData
                {
                    id = eventId,
                    title = title,
                    locked = false,
                    dates = new List<string>(rawDates.Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries)),
                    participants = new List<Participant>(),
                    creatorLoginId = User.Identity.Name
                };
                SaveJson(dataDir + eventId + ".json", newEvent);
                Response.Write(serializer.Serialize(new { status = "ok", id = eventId }));
            }
            else if (mode == "load")
            {
                string id = Request["id"];
                if (!IsValidEventId(id)) throw new Exception("Invalid event ID.");
                string path = dataDir + id + ".json";
                if (File.Exists(path))
                {
                    string json = File.ReadAllText(path, Encoding.UTF8);
                    var eventData = serializer.Deserialize<EventData>(json);
                    bool isOwner = string.IsNullOrEmpty(eventData.creatorLoginId) ||
                                   eventData.creatorLoginId == User.Identity.Name;
                    Response.Write(serializer.Serialize(new {
                        id = eventData.id,
                        title = eventData.title,
                        locked = eventData.locked,
                        dates = eventData.dates,
                        participants = eventData.participants,
                        isOwner = isOwner
                    }));
                }
                else
                {
                    Response.Write(serializer.Serialize(new { status = "error", msg = "Not found." }));
                }
            }
            else if (mode == "update")
            {
                string id = Request["id"];
                if (!IsValidEventId(id)) throw new Exception("Invalid event ID.");
                string path = dataDir + id + ".json";
                lock (string.Intern(path)) 
                {
                    if (!File.Exists(path)) throw new Exception("データなし");
                    string json = File.ReadAllText(path, Encoding.UTF8);
                    var eventData = serializer.Deserialize<EventData>(json);

                    if (eventData.locked) throw new Exception("このイベントは既に締め切られています。");

                    string name = Request["name"];
                    string ansStr = Request["answers"];
                    var answers = new List<int>();
                    foreach (var s in ansStr.Split(',')) answers.Add(int.Parse(s));

                    var person = eventData.participants.Find(p => p.name == name);
                    if (person != null) { person.answers = answers; person.comment = Request["comment"]; }
                    else { eventData.participants.Add(new Participant { name = name, answers = answers, comment = Request["comment"] }); }

                    File.WriteAllText(path, serializer.Serialize(eventData), Encoding.UTF8);
                }
                Response.Write(serializer.Serialize(new { status = "ok" }));
            }
            else if (mode == "lock")
            {
                string id = Request["id"];
                if (!IsValidEventId(id)) throw new Exception("Invalid event ID.");
                string path = dataDir + id + ".json";
                lock (string.Intern(path)) 
                {
                    if (!File.Exists(path)) throw new Exception("Not found.");
                    string json = File.ReadAllText(path, Encoding.UTF8);
                    var eventData = serializer.Deserialize<EventData>(json);
                    if (!string.IsNullOrEmpty(eventData.creatorLoginId) &&
                        eventData.creatorLoginId != User.Identity.Name)
                        throw new Exception("Unauthorized.");
                    eventData.locked = true;
                    File.WriteAllText(path, serializer.Serialize(eventData), Encoding.UTF8);
                    Response.Write(serializer.Serialize(new { status = "ok" }));
                }
            }
            else if (mode == "delete")
            {
                string id = Request["id"];
                if (!IsValidEventId(id)) throw new Exception("Invalid event ID.");
                string path = dataDir + id + ".json";
                lock (string.Intern(path)) 
                {
                    if (!File.Exists(path)) throw new Exception("Not found.");
                    string json = File.ReadAllText(path, Encoding.UTF8);
                    var eventData = serializer.Deserialize<EventData>(json);
                    if (!string.IsNullOrEmpty(eventData.creatorLoginId) &&
                        eventData.creatorLoginId != User.Identity.Name)
                        throw new Exception("Unauthorized.");
                    File.Delete(path);
                    Response.Write(serializer.Serialize(new { status = "ok" }));
                }
            }
        }
        catch (Exception ex)
        {
            Response.Write(serializer.Serialize(new { status = "error", msg = ex.Message }));
        }
        Response.End();
    }

    private bool IsValidEventId(string id)
    {
        return !string.IsNullOrEmpty(id) && System.Text.RegularExpressions.Regex.IsMatch(id, @"^evt\d{17}$");
    }

    private void SaveJson(string path, object data)
    {
        var serializer = new JavaScriptSerializer();
        File.WriteAllText(path, serializer.Serialize(data), Encoding.UTF8);
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
    </style>
</head>
<body>

<div class="container">
    <header class="app-header">
        <span class="logo-main">調整さん</span>
        <span class="logo-sub">庁内日程調整ツール</span>
        
        <!-- ログイン情報表示エリア -->
        <div class="login-info">
            Login: <strong><%= UserDisplayName %></strong>
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
        
        <div style="margin-bottom: 20px;">
            <span style="font-size:14px; font-weight:bold;">共有用URL：</span>
            <div id="share-url" class="share-url-box"></div>
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
            <input type="text" id="my-comment">

            <button class="btn-primary" onclick="submitAnswer()">登録する</button>
        </div>

        <div id="locked-message" class="hidden locked-msg">
            このイベントは確定済みのため、回答を締め切りました。
        </div>

        <!-- 管理エリア -->
        <div class="admin-area hidden" id="admin-controls">
            <span style="font-size:0.9em; color:#666;">管理者メニュー：</span>
            <button class="btn-lock" onclick="execLockEvent()">確定して締め切る</button>
            <button class="btn-delete" onclick="execDeleteEvent()">削除する</button>
        </div>
        
        <div style="margin-top:20px; text-align:right;">
            <a href="default.aspx" style="color:#007bff; text-decoration:none;">&laquo; トップに戻る</a>
        </div>
    </div>
</div>

<script>
    // サーバー側で取得した氏名をJS変数にセット (エスケープ処理付き)
    var currentUserDisplayName = "<%= UserDisplayName.Replace("\"", "\\\"") %>";

    var currentEventId = "";
    var eventData = null;

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
            if(data.status === "error"){ alert("イベントが見つかりません。削除された可能性があります。"); window.location.href="default.aspx"; return; }
            
            eventData = data;
            $("#create-view").addClass("hidden");
            $("#schedule-view").removeClass("hidden");
            
            $("#evt-title").text(data.title);
            $("#share-url").text(window.location.href);

            renderTable(data);
            
            if(data.locked) {
                $("#evt-title").addClass("locked-title").text(data.title + "【確定済】");
                $("#input-container").addClass("hidden");
                $("#locked-message").removeClass("hidden");
            } else {
                $("#evt-title").removeClass("locked-title");
                $("#input-container").removeClass("hidden");
                $("#locked-message").addClass("hidden");
                renderInputs(data);
                if(currentUserDisplayName) $("#my-name").val(currentUserDisplayName);
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
        var html = '<table><thead><tr><th style="min-width:120px;">参加者</th>';
        data.dates.forEach(function(d){ html += '<th>' + escapeHtml(d) + '</th>'; });
        html += '<th style="min-width:150px;">コメント</th></tr></thead><tbody>';

        data.participants.forEach(function(p){
            html += '<tr><td>' + escapeHtml(p.name) + '</td>';
            p.answers.forEach(function(a){
                var sym = a===2 ? "○" : (a===1 ? "△" : "×");
                var cls = a===2 ? "symbol-ok" : (a===1 ? "symbol-tri" : "symbol-ng");
                html += '<td class="'+cls+'">' + sym + '</td>';
            });
            html += '<td style="text-align:left;">' + escapeHtml(p.comment) + '</td></tr>';
        });

        html += '<tr style="background:#ffffe0; font-weight:bold;"><td>○の数</td>';
        for(var i=0; i<data.dates.length; i++){
            var count = 0;
            data.participants.forEach(function(p){ if(p.answers[i]===2) count++; });
            html += '<td>' + count + '</td>';
        }
        html += '<td>-</td></tr></tbody></table>';
        $("#table-container").html(html);
    }

    function renderInputs(data){
        var html = '';
        data.dates.forEach(function(d, idx){
            html += '<div style="margin-top:10px; border-bottom:1px dotted #ccc; padding-bottom:5px;">';
            html += '<span style="font-weight:bold;">' + escapeHtml(d) + '</span><br>';
            html += '<label style="display:inline-block; margin-right:15px; cursor:pointer;"><input type="radio" name="ans_'+idx+'" value="2" checked> <span class="symbol-ok">○</span></label> ';
            html += '<label style="display:inline-block; margin-right:15px; cursor:pointer;"><input type="radio" name="ans_'+idx+'" value="1"> <span class="symbol-tri">△</span></label> ';
            html += '<label style="display:inline-block; margin-right:15px; cursor:pointer;"><input type="radio" name="ans_'+idx+'" value="0"> <span class="symbol-ng">×</span></label>';
            html += '</div>';
        });
        $("#date-inputs").html(html);
    }

    function submitAnswer(){
        var name = $("#my-name").val();
        if(!name){ alert("氏名を入力してください"); return; }

        var answers = [];
        for(var i=0; i<eventData.dates.length; i++){
            answers.push($('input[name="ans_'+i+'"]:checked').val());
        }

        $.post("default.aspx?mode=update", {
            id: currentEventId,
            name: name,
            answers: answers.join(","),
            comment: $("#my-comment").val()
        }, function(res){
            if(res.status === "ok"){
                loadEvent(currentEventId);
                // コメントのみクリアします。
                // $("#my-name").val(""); 
                $("#my-comment").val("");
            } else {
                alert("エラーが発生しました: " + res.msg);
            }
        });
    }

    function execLockEvent() {
        if(!confirm("本当にこの日程調整を締め切りますか？\n締め切ると、これ以上回答を追加できなくなります。")) return;

        $.post("default.aspx?mode=lock", { id: currentEventId }, function(res){
            if(res.status === "ok") {
                alert("締め切りました。");
                loadEvent(currentEventId);
            } else {
                alert("エラーが発生しました");
            }
        });
    }

    function execDeleteEvent() {
        if(!confirm("本当に削除しますか？\nこの操作は取り消せません。")) return;

        $.post("default.aspx?mode=delete", { id: currentEventId }, function(res){
            if(res.status === "ok") {
                alert("削除しました。トップ画面に戻ります。");
                window.location.href = "default.aspx";
            } else {
                alert("エラーが発生しました");
            }
        });
    }

    function escapeHtml(str) {
        if(!str) return "";
        return str.replace(/[&<>"']/g, function(m) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[m];
        });
    }
</script>

</body>
</html>