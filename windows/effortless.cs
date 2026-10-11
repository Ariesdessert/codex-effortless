// codex-effortless for Codex on Windows: the CLI in PowerShell or cmd, and Codex Desktop. The same program as
// effortless.pl, in C# 5 so the C# compiler every Windows has (.NET Framework 4) builds it at install time:
//
//   effortless.exe hook             the UserPromptSubmit hook
//   effortless.exe codex [args]     start the Codex CLI with Auto: every prompt runs at the effort the judge picks
//   effortless.exe app-server ...   what Codex Desktop starts when CODEX_CLI_PATH points here (effortless desktop on)
//   effortless.exe desktop on|off   Auto in Codex Desktop
//   effortless.exe stats | debug | auto [on|off] | save [on|off] | config [set KEY VALUE] | test [prompt]
//   effortless.exe handoff-save | resume | handoff-write | copy | bench | update | version
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

static class Effortless
{
    const string VERSION = "0.5.0";
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    static readonly string[] LEVELS = { "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra" };
    static readonly string[] JUDGED = { "low", "medium", "high", "xhigh", "max" };

    static string Here, CodexHome, Data, LogPath;
    [ThreadStatic] static string Session;
    static readonly Dictionary<string, string> Conf = new Dictionary<string, string>();
    static string MODE, JUDGE, MODEL, MIN, MAX, JEV_URL,
        COLD, HANDOFF_FROM, HANDOFF_SKILL, HANDOFF_AFTER, BAR, UPDATE_CHECK, CODEX;
    static int BIAS, BLOCK_GAP, BUDGET, HANDOFF_EVERY;
    static double SWAMP_AT, COLD_MINUTES, COLD_TOKENS, HOT_AT;
    static HashSet<string> HIDE;
    [ThreadStatic] static string by;
    [ThreadStatic] static string failed;

    // ------------------------------------------------------------ settings

    static void LoadSettings()
    {
        Here = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        CodexHome = Env("CODEX_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        string confPath = Path.Combine(Here, "effortless.conf");
        if (File.Exists(confPath))
        {
            foreach (string line in File.ReadAllLines(confPath, Utf8))
            {
                Match m = Regex.Match(line, @"^\s*(EFFORTLESS_\w+)=(.*)$");
                if (!m.Success) continue;
                string v = m.Groups[2].Value;
                Match d = Regex.Match(v, @"^\$\{\w+:-([^}]*)\}");
                v = d.Success ? d.Groups[1].Value : Regex.Replace(v, @"\s+#.*$", "");
                Conf[m.Groups[1].Value] = v.Trim().Trim('"', '\'');
            }
        }
        MODE = S("EFFORTLESS_MODE", "auto");
        JUDGE = S("EFFORTLESS_JUDGE", "auto");
        MODEL = S("EFFORTLESS_MODEL", "gpt-5.6-luna");
        MIN = S("EFFORTLESS_MIN", "medium");
        MAX = S("EFFORTLESS_MAX", "max");
        BIAS = I(S("EFFORTLESS_BIAS", "0"));
        BLOCK_GAP = I(S("EFFORTLESS_BLOCK_GAP", "1"));
        BUDGET = I(S("EFFORTLESS_TIMEOUT", "20"));
        JEV_URL = S("EFFORTLESS_JEV_URL", Env("JEV_URL") ?? "https://api.typesafe.ai/v1/systemone");
        SWAMP_AT = D(S("EFFORTLESS_SWAMP_AT", "50"));
        COLD = S("EFFORTLESS_COLD", "block");
        COLD_MINUTES = D(S("EFFORTLESS_COLD_MINUTES", "30"));
        COLD_TOKENS = D(S("EFFORTLESS_COLD_TOKENS", "150000"));
        HOT_AT = D(S("EFFORTLESS_HOT_AT", "80"));
        HANDOFF_FROM = S("EFFORTLESS_HANDOFF_FROM", "30");
        HANDOFF_EVERY = Math.Max(1, I(S("EFFORTLESS_HANDOFF_EVERY", "2")));
        HANDOFF_SKILL = S("EFFORTLESS_HANDOFF_SKILL", "");
        HANDOFF_AFTER = S("EFFORTLESS_HANDOFF_AFTER", "continue");
        HIDE = new HashSet<string>(S("EFFORTLESS_HIDE", "reason").Split(',').Select(x => x.Trim()).Where(x => x != ""));
        BAR = S("EFFORTLESS_BAR", "changes");
        UPDATE_CHECK = S("EFFORTLESS_UPDATE_CHECK", "on");
        CODEX = S("EFFORTLESS_CODEX", "");
        Data = S("EFFORTLESS_DATA", Path.Combine(CodexHome, @"effortless\data"));
        foreach (string d in new[] { Data, Path.Combine(Data, "sessions"), Path.Combine(Data, "routed") }) Directory.CreateDirectory(d);
        LogPath = Path.Combine(Data, "verdicts.tsv");
    }

    static string Env(string k) { string v = Environment.GetEnvironmentVariable(k); return string.IsNullOrEmpty(v) ? null : v; }
    static string S(string k, string d)
    {
        string e = Env(k);
        if (e != null) return e;
        string c;
        if (Conf.TryGetValue(k, out c) && c != "") return c;
        return d;
    }
    static int I(string s) { int n; return int.TryParse(s, NumberStyles.Integer, Inv, out n) ? n : 0; }
    static double D(string s) { double n; return double.TryParse(s, NumberStyles.Float, Inv, out n) ? n : 0; }
    static int Rank(string l) { return l == null ? -1 : Array.IndexOf(LEVELS, l); }

    // ------------------------------------------------------------ JSON and small helpers

    static readonly JavaScriptSerializer Js = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 1000 };
    static object Parse(string s) { if (s == null) return null; try { return Js.DeserializeObject(s); } catch { return null; } }
    static string Ser(object o) { return Js.Serialize(o); }
    static object Get(object o, params string[] path)
    {
        foreach (string k in path)
        {
            var d = o as Dictionary<string, object>;
            object v;
            if (d == null || !d.TryGetValue(k, out v)) return null;
            o = v;
        }
        return o;
    }
    static string Str(object o) { return o == null ? null : (o as string ?? Convert.ToString(o, Inv)); }
    static double Num(object o, double d) { if (o == null || o is string || o is bool) return d; try { return Convert.ToDouble(o, Inv); } catch { return d; } }
    static object[] Arr(object o) { return o as object[] ?? (o is ArrayList ? ((ArrayList)o).ToArray() : new object[0]); }
    static Dictionary<string, object> Obj(params object[] kv)
    {
        var d = new Dictionary<string, object>();
        for (int i = 0; i + 1 < kv.Length; i += 2) d[(string)kv[i]] = kv[i + 1];
        return d;
    }
    static double Now() { return (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds; }
    static string Cut(string s, int n) { s = s ?? ""; return s.Length > n ? s.Substring(0, n) : s; }
    static string Tail(string s, int n) { s = s ?? ""; return s.Length > n ? s.Substring(s.Length - n) : s; }
    static string Ktokens(double n) { return n >= 1000 ? ((int)(n / 1000 + 0.5)).ToString(Inv) + "k" : ((int)n).ToString(Inv); }
    static string ReadText(string p) { try { return File.ReadAllText(p, Utf8); } catch { return null; } }
    static void WriteText(string p, string t)
    {
        string tmp = p + "." + Process.GetCurrentProcess().Id;
        try { File.WriteAllText(tmp, t, Utf8); File.Copy(tmp, p, true); File.Delete(tmp); } catch { }
    }
    static Dictionary<string, object> ReadJson(string p) { return Parse(ReadText(p)) as Dictionary<string, object>; }
    static void WriteJson(string p, object v) { WriteText(p, Ser(v)); }
    static string ReadShared(string path)
    {
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var r = new StreamReader(fs, Utf8)) return r.ReadToEnd();
    }
    static string ClockOf(double epoch)
    {
        DateTime at = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(epoch).ToLocalTime();
        string hm = at.ToString("HH:mm", Inv);
        if (epoch - Now() < 20 * 3600) return hm;
        return new[] { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }[(int)at.DayOfWeek] + " " + hm;
    }
    static void Out(string s) { byte[] b = Utf8.GetBytes(s); Stream o = Console.OpenStandardOutput(); o.Write(b, 0, b.Length); o.Flush(); }
    static void SayJson(object o) { Out(Ser(o) + "\n"); }
    static string Md5Key(string s)
    {
        using (var md5 = MD5.Create()) return string.Concat(md5.ComputeHash(Utf8.GetBytes(s)).Select(b => b.ToString("x2"))).Substring(0, 16);
    }
    static string SafeId(string s) { return Regex.Replace(s ?? "", @"[^\w.-]", ""); }
    // A time kept in the session file: it comes back as a decimal, a hair off the double it was written from.
    static bool SameTime(object kept, double t) { return Math.Abs(Num(kept, 0) - t) < 0.01; }

    static void LogRow(string cur, string verdict, string sure, long ms, long tokens, string action)
    {
        string row = string.Join("\t", DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", Inv), cur ?? "-", verdict ?? "-", sure ?? "-",
            ms.ToString(Inv), tokens.ToString(Inv), action, by ?? "-", Session ?? "-");
        try { lock (Conf) File.AppendAllText(LogPath, row + "\n", Utf8); } catch { }
    }

    // ------------------------------------------------------------ the transcript

    class Limit { public double Pct, Minutes, Resets; }
    class Transcript
    {
        public string Effort, Model, LastAssistant;
        public bool Desktop;
        public double Tokens, Window, Percent, LastAt;
        public List<string> Users = new List<string>();
        public Dictionary<string, Limit> Limits = new Dictionary<string, Limit>();
        public Dictionary<string, string> TurnEffort = new Dictionary<string, string>();
        public List<double[]> Usage = new List<double[]>();   // in, cached, out
        public List<string> UsageTurn = new List<string>();
        public List<KeyValuePair<string, string>> Msgs = new List<KeyValuePair<string, string>>();   // role, text: with full only
    }

    static double IsoTime(string s)
    {
        DateTime t;
        if (s != null && DateTime.TryParse(s, Inv, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out t))
            return (t - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        return 0;
    }

    // What effortless reads from a session's transcript: the effort and model in use, how full the context is,
    // when the last answer came, the usage limits, and the messages. With full, also every message and tool call in
    // order (Msgs), for a handoff written from the transcript.
    static Transcript ReadTranscript(string path, bool full = false)
    {
        var t = new Transcript();
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return t;
        string text;
        try { text = ReadShared(path); } catch { return t; }
        var type = new Regex("\"type\"\\s*:\\s*\"(turn_context|token_count|message|token_usage_record)\"");
        var call = new Regex("\"type\"\\s*:\\s*\"[a-z_]*(call|call_output)\"");
        int n = 0;
        foreach (string line in text.Split('\n'))
        {
            n++;
            if (n <= 3 && Regex.IsMatch(line, "\"originator\"\\s*:\\s*\"Codex Desktop\"")) t.Desktop = true;
            if (!type.IsMatch(line) && !(full && call.IsMatch(line))) continue;
            var j = Parse(line) as Dictionary<string, object>;
            if (j == null) continue;
            object p = Get(j, "payload");
            string jt = Str(Get(j, "type"));
            string pt = Str(Get(p, "type")) ?? "";
            if (jt == "turn_context")
            {
                string e = Str(Get(p, "effort")) ?? Str(Get(p, "collaboration_mode", "settings", "reasoning_effort"));
                if (e != null) t.Effort = e;
                if (Get(p, "model") != null) t.Model = Str(Get(p, "model"));
                string turn = Str(Get(p, "turn_id"));
                if (turn != null && e != null) t.TurnEffort[turn] = e;
            }
            else if (jt == "event_msg" && pt == "token_count")
            {
                object info = Get(p, "info");
                if (info != null)
                {
                    t.Tokens = Num(Get(info, "last_token_usage", "input_tokens"), 0) + Num(Get(info, "last_token_usage", "output_tokens"), 0);
                    double w = Num(Get(info, "model_context_window"), 0);
                    if (w > 0) t.Window = w;
                    t.LastAt = IsoTime(Str(Get(j, "timestamp")));
                }
                foreach (string k in new[] { "primary", "secondary" })
                {
                    object w = Get(p, "rate_limits", k);
                    if (w == null || Get(w, "used_percent") == null) continue;
                    t.Limits[k] = new Limit { Pct = Num(Get(w, "used_percent"), 0), Minutes = Num(Get(w, "window_minutes"), 0), Resets = Num(Get(w, "resets_at"), 0) };
                }
            }
            else if (jt == "response_item" && pt == "message")
            {
                string said = string.Concat(Arr(Get(p, "content")).Where(c => (Str(Get(c, "type")) ?? "").Contains("text")).Select(c => Str(Get(c, "text")) ?? ""));
                string role = Str(Get(p, "role"));
                if (role == "user")
                {
                    // Codex sends its own context as user messages too: they start with a tag.
                    if (Regex.IsMatch(said, @"^\s*(<[a-z_]+>|# AGENTS\.md)")) continue;
                    t.Users.Add(said);
                    if (full) t.Msgs.Add(new KeyValuePair<string, string>("user", said));
                }
                else if (role == "assistant" && said.Trim() != "")
                {
                    if ((Str(Get(p, "phase")) ?? "final_answer") != "commentary") t.LastAssistant = said;
                    if (full) t.Msgs.Add(new KeyValuePair<string, string>("assistant", said));
                }
            }
            else if (full && jt == "response_item" && pt.EndsWith("_call"))
            {
                object input = Get(p, "arguments") ?? Get(p, "input") ?? Get(p, "action") ?? "";
                t.Msgs.Add(new KeyValuePair<string, string>("tool", (Str(Get(p, "name")) ?? pt) + " " + (input is string ? (string)input : Ser(input))));
            }
            else if (full && jt == "response_item" && pt.EndsWith("_call_output"))
            {
                object o = Get(p, "output") ?? "";
                if (o is Dictionary<string, object> && Get(o, "content") != null) o = Get(o, "content");
                if (o is object[] || o is ArrayList) o = string.Join("\n", Arr(o).Select(x => x is string ? (string)x : Str(Get(x, "text")) ?? ""));
                t.Msgs.Add(new KeyValuePair<string, string>("result", o is string ? (string)o : Ser(o)));
            }
            else if (jt == "token_usage_record")
            {
                object u = Get(p, "usage");
                t.Usage.Add(new[] { Num(Get(u, "input_tokens"), 0), Num(Get(u, "cached_input_tokens"), 0), Num(Get(u, "output_tokens"), 0) });
                t.UsageTurn.Add(Str(Get(p, "turn_id")) ?? "");
            }
        }
        if (t.Effort == null)
        {
            MatchCollection m = Regex.Matches(text, "\"reasoning_effort\"\\s*:\\s*\"([a-z]+)\"");
            if (m.Count > 0) t.Effort = m[m.Count - 1].Groups[1].Value;
        }
        t.Percent = t.Window > 0 ? 100 * t.Tokens / t.Window : 0;
        return t;
    }

    class ModelInfo { public List<string> Supported = new List<string>(); public object Updates; public string Default; public double Window; }

    // The models Codex knows, with the efforts each takes (models_cache.json).
    static ModelInfo GetModelInfo(string model)
    {
        if (model == null) return null;
        var j = ReadJson(Path.Combine(CodexHome, "models_cache.json"));
        foreach (object m in Arr(Get(j, "models")))
        {
            if (Str(Get(m, "slug")) != model) continue;
            var info = new ModelInfo { Updates = Get(m, "supports_reasoning_effort_updates"), Default = Str(Get(m, "default_reasoning_level")), Window = Num(Get(m, "context_window"), 0) };
            foreach (object l in Arr(Get(m, "supported_reasoning_levels")))
            {
                string e = l is string ? (string)l : (Str(Get(l, "effort")) ?? Str(Get(l, "reasoningEffort")));
                if (e != null) info.Supported.Add(e);
            }
            return info;
        }
        return null;
    }

    static string ConfigEffort()
    {
        string t = ReadText(Path.Combine(CodexHome, "config.toml")) ?? "";
        MatchCollection m = Regex.Matches(t, "(?m)^\\s*model_reasoning_effort\\s*=\\s*\"([a-z]+)\"");
        return m.Count > 0 ? m[m.Count - 1].Groups[1].Value : null;
    }

    // ------------------------------------------------------------ what the judges are asked

    const string JUDGE_SYSTEM = @"You choose the reasoning effort an agentic coding assistant (it reads files, runs tools and edits things, not only code) should use for the user's next message. Pick the cheapest effort that will still do the job well. Never use tools.

Effort: low for quick answers, medium for normal work, high for hard problems, xhigh or max only for very hard ones.
- low: quick questions, explanations, small mechanical edits such as a rename, a typo or a config value, running one command.
- medium: ordinary feature work or a bug fix in code that is easy to locate, moderate multi-file edits, tests for clear behaviour.
- high: debugging unclear failures, concurrency, performance or security problems, design decisions, refactors across many files, anything where a wrong answer is costly.
- xhigh: long autonomous multi-step tasks, deep investigations, hard algorithmic or architectural problems.
- max: only the hardest research-level work.
Do not lean toward the current effort: pick what the message needs.

Judge the SCOPE and the amount of work, not whether it is code. A short message can ask for a lot: ""go through my whole drive and clean it up"", ""review the entire repo"", ""migrate everything"" are big, multi-step, tool-heavy jobs where mistakes are costly: never low, usually high. Low is only for answers that need no tools and no planning.

If the message answers a question in the assistant's last reply (picks an option, says which one, confirms a plan), judge only the work that answer starts, as the reply describes it, not the length of the answer and not the work done before the question: ""B"" can mean ""build the complicated section B"" (high), while ""yes"" or ""no"" to one small action (""should I archive this?"", ""delete the old ones too?"") is low, and picking a value for one setting (a log level, a colour, a font) is low. But picking which way to build something (""option 1"", ""the same shapes"", ""B"") starts that build: judge the build. Approving a whole plan or several steps takes the effort of that plan. A plain ""yes"", ""ok"" or ""do it"" after ""Is that OK? Then I'll build X"" or ""Should I build X?"" approves building X: judge X, not the word.

A message that pushes back on, corrects or adds to a plan or claim under discussion continues that work: keep at least the effort that work had, never drop to low for it. Thanks, praise or a closing remark with no new request is low. A question about how to do something, or about effort itself, that needs no tools is low.

If the person asks for deep thought (""think hard"", ""ultrathink"", ""be thorough""), pick at least high; if they ask for a quick answer, pick low.

If the message is a short follow-up to ongoing work (""yes"", ""go"", ""ok"", ""continue"", or the same in any language), keep the current effort.

Reply with JSON only: {""effort"":""low|medium|high|xhigh|max"",""sure"":0.0-1.0 how sure you are of the effort,""why"":""at most 6 words, in the user's language""}";

    const string HANDOFF_SYSTEM = @"You decide whether the person should hand off now: start a fresh chat that carries over a short summary, instead of carrying on in this one. You are shown what the chat was for, the trail of what the person asked, the last turns, the next message, how full the context is and whether the cache is cold. Never use tools.

Say yes only for a clear reason: the task just finished and the next message is something else, the topic has changed so the old context is dead weight, the chat keeps going in circles on the same problem, or a long chat now holds so much unrelated history that a clean start would be sharper. A normal next step of the same work is never a reason, a long chat by itself is not one, and neither is a high context share when the work is going well. When unsure, say no: a wrong yes costs the person more than a missed one.

Reply with JSON only: {""handoff"":""reason of at most 8 words, in the person's language""} for yes, or {""handoff"":null} for no.";

    const string JEV_TASK = "Choose the reasoning effort an agentic coding assistant should use for the next user message. It reads files, " +
        "runs tools and edits things, not only code. Pick the cheapest that still does the job well. Judge the scope and the " +
        "amount of work, not whether it is code: \"go through my whole drive and clean it up\" is a big tool-heavy job. " +
        "A short follow-up (\"yes\", \"go\", \"ok\", in any language) keeps the current effort. When the message answers a " +
        "question in the assistant's last reply (picks an option), judge only the work that answer starts, not its length and " +
        "not the work before the question: yes/no to one small action, or picking a value for one setting (a log level, a colour), is low; picking which way to build something starts that build, so judge the build; " +
        "approving a whole plan takes the effort of that plan; a plain yes to \"Then I will build X\" means judge X. Pushing back on or adding to a plan under discussion continues that work: keep its effort, never low. Thanks or a closing remark with no new request is low. A " +
        "question about how to do something that needs no tools is low. \"think hard\", \"ultrathink\" or \"be thorough\" means " +
        "at least high; \"quick question\" means low.";

    static object EffortSchema()
    {
        return Obj("type", "object", "additionalProperties", false, "required", new object[] { "effort", "sure", "why" },
            "properties", Obj("effort", Obj("type", "string", "enum", JUDGED.Cast<object>().ToArray()), "sure", Obj("type", "number"), "why", Obj("type", "string")));
    }
    static object HandoffSchema()
    {
        return Obj("type", "object", "additionalProperties", false, "required", new object[] { "handoff" },
            "properties", Obj("handoff", Obj("type", new object[] { "string", "null" })));
    }

    static string ContextText(string lastUser, string lastAssistant)
    {
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(lastUser)) parts.Add("user: " + Cut(lastUser, 400));
        if (!string.IsNullOrEmpty(lastAssistant)) parts.Add("assistant: " + Tail(lastAssistant, 2000));
        return string.Join("\n", parts);
    }

    static string JudgeQuestion(string prompt, string current, string context, double percent)
    {
        var parts = new List<string> { "Current effort: " + (current ?? "unknown") };
        if (context != "") parts.Add("Recent conversation:\n" + context);
        parts.Add("Next message:\n" + Cut(prompt, 2000));
        if (percent > 0) parts.Add(string.Format(Inv, "Context used: {0}% of the window", (int)(percent + 0.5)));
        return string.Join("\n\n", parts);
    }

    static string HandoffEvidence(List<string> users, string lastAssistant, string next, double percent, bool cold)
    {
        var asked = users.Where(u => u.Trim() != "").ToList();
        if (asked.Count > 0 && asked[asked.Count - 1] == next) asked.RemoveAt(asked.Count - 1);
        var parts = new List<string>();
        if (asked.Count > 0) parts.Add("What the chat was for (first message):\n" + Cut(asked[0], 500));
        var trail = asked.Skip(Math.Max(1, asked.Count - 8)).Select(m => "- " + Regex.Replace(Cut(m, 160), @"\s+", " ")).ToList();
        if (trail.Count > 0) parts.Add("Trail of earlier messages:\n" + string.Join("\n", trail));
        if (!string.IsNullOrEmpty(lastAssistant)) parts.Add("The assistant's last reply (its end):\n" + Tail(lastAssistant, 700));
        parts.Add("Next message:\n" + Cut(next, 600));
        parts.Add(string.Format(Inv, "Context used: {0}% of the window; {1} messages so far; the cache is {2}.", (int)(percent + 0.5), asked.Count + 1, cold ? "cold" : "warm"));
        return string.Join("\n\n", parts);
    }

    // A short follow-up such as "go", "ok", "继续" keeps the effort the work is on, unless the last reply ended on a
    // question: then the answer can start a small or a big job, and goes to the judge.
    static readonly Regex FollowRe = new Regex(@"^\s*(ok(ay)?|y(es)?|yep|sure|go( ahead)?|continue|do it|proceed|thanks?|lgtm|好的?|行|可以|继续|是的?|对|嗯|开始吧?|确认|没问题)\s*[.!。！~～]*\s*$", RegexOptions.IgnoreCase);
    // A level the prompt names ("max effort", "effort: high", "xhigh"), or nothing. The word effort must sit beside the
    // level, so "a medium sized image" names nothing, and "don't use max effort" is a no. As in the original, a named
    // level runs without the judge.
    const string LEVEL_WORD = "(low|medium|high|xhigh|x-high|extra[- ]high|max|maximum)";
    static readonly Regex NAMED_LEVEL = new Regex(@"\b" + LEVEL_WORD + @"\s+effort\b|\beffort(?:\s+level)?\s*(?:[:=]|to|at|of|on)?\s*" + LEVEL_WORD + @"\b|\bxhigh\b",
        RegexOptions.IgnoreCase | RegexOptions.ECMAScript);
    static string NamedEffort(string text)
    {
        foreach (Match m in NAMED_LEVEL.Matches(text ?? ""))
        {
            string before = text.Substring(Math.Max(0, m.Index - 20), Math.Min(20, m.Index)).ToLowerInvariant();
            if (Regex.IsMatch(before, @"\b(not|no|don'?t|never|without|instead of)\b", RegexOptions.ECMAScript) || Regex.IsMatch(before, "(不要|不用|别|无需|不必)")) continue;
            string w = Regex.Replace((m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Success ? m.Groups[2].Value : "xhigh").ToLowerInvariant(), @"\s+", " ");
            return w == "x-high" || w == "extra high" || w == "extra-high" ? "xhigh" : w == "maximum" ? "max" : w;
        }
        return null;
    }

    static bool IsFollowUp(string s)
    {
        string t = (s ?? "").Trim();
        if (t == "") return false;
        if (t.Length <= 24 && FollowRe.IsMatch(t)) return true;
        // The original's rule for words split by spaces: a dozen characters and two words at most.
        return !t.Any(c => c > 0x7f) && t.Length <= 12 && Regex.Split(t, @"\s+").Length <= 2;
    }
    static bool EndsOnQuestion(string reply) { string t = Tail(reply, 400); return t.Contains("?") || t.Contains("？"); }
    static bool KeepsEffort(string p, string lastAssistant) { return IsFollowUp(p) && !EndsOnQuestion(lastAssistant); }

    // ------------------------------------------------------------ the judges

    class Job { public string System, Ask, Effort; public object Schema; }   // no Schema: free text; Effort none unless set
    class Answer { public string Text; public long Tokens; }

    // Finds codex.exe: the setting, then PATH, then the npm package, then Codex Desktop's own.
    static string FindCodex()
    {
        if (CODEX != "" && File.Exists(CODEX)) return CODEX;
        string self = Path.GetFullPath(Process.GetCurrentProcess().MainModule.FileName);
        foreach (string dir in (Env("PATH") ?? "").Split(';'))
        {
            try
            {
                string c = Path.Combine(dir.Trim().Trim('"'), "codex.exe");
                if (dir.Trim() != "" && File.Exists(c) && !string.Equals(Path.GetFullPath(c), self, StringComparison.OrdinalIgnoreCase)) return c;
            }
            catch { }
        }
        string npm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe");
        if (File.Exists(npm)) return npm;
        return DesktopCodex();
    }

    // Codex Desktop's own codex.exe, from its package (remembered: asking Windows takes a second).
    static string DesktopCodex()
    {
        string cache = Path.Combine(Data, "desktop-codex.txt");
        string known = ReadText(cache);
        if (known != null && File.Exists(known.Trim())) return known.Trim();
        try
        {
            var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -NonInteractive -Command \"(Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1).InstallLocation\"")
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true };
            using (var p = Process.Start(psi))
            {
                p.StandardInput.Close();
                string dir = p.StandardOutput.ReadToEnd().Trim();
                p.WaitForExit(10000);
                string exe = dir == "" ? "" : Path.Combine(dir, @"app\resources\codex.exe");
                if (exe != "" && File.Exists(exe)) { WriteText(cache, exe); return exe; }
            }
        }
        catch { }
        return null;
    }

    static void KillTree(Process p)
    {
        try
        {
            if (p.HasExited) return;
            var k = Process.Start(new ProcessStartInfo("taskkill.exe", "/PID " + p.Id + " /T /F") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true });
            k.WaitForExit(5000);
        }
        catch { }
        try { if (!p.HasExited) p.Kill(); } catch { }
    }

    // Codex: a short-lived app-server on your login, hooks and tools off, one ephemeral thread per question.
    static Answer[] AskCodex(Job[] jobs, int budget)
    {
        var answers = new Answer[jobs.Length];
        string exe = FindCodex();
        if (exe == null) { failed = "no-codex"; return answers; }
        string off = "apps browser_use browser_use_external computer_use code_mode_host goals hooks image_generation multi_agent plugins remote_plugin shell_snapshot shell_tool skill_search sleep_tool tool_suggest unified_exec view_image web_search workspace_dependencies worktrees";
        // notify=[]: a notify program from config.toml must not fire on (and see) the judge's turn; a long-lived one
        // would also hold this hook's output open. An empty working directory keeps AGENTS.md and the like out.
        string cwd = Path.Combine(Data, "judge-cwd");
        Directory.CreateDirectory(cwd);
        var psi = new ProcessStartInfo(exe, "app-server -c notify=[]" + string.Concat(off.Split(' ').Select(f => " --disable " + f)))
        {
            WorkingDirectory = cwd, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Utf8
        };
        psi.EnvironmentVariables["EFFORTLESS_JUDGE"] = "1";
        DateTime deadline = DateTime.UtcNow.AddSeconds(budget);
        Process proc;
        try { proc = Process.Start(psi); } catch { failed = "spawn"; return answers; }
        proc.ErrorDataReceived += (s, e) => { };
        proc.BeginErrorReadLine();
        var lines = new BlockingCollection<string>();
        var reader = new Thread(() => { try { string l; while ((l = proc.StandardOutput.ReadLine()) != null) lines.Add(l); } catch { } lines.CompleteAdding(); }) { IsBackground = true };
        reader.Start();
        Stream stdin = proc.StandardInput.BaseStream;
        Action<object> send = o => { byte[] b = Utf8.GetBytes(Ser(o) + "\n"); stdin.Write(b, 0, b.Length); stdin.Flush(); };
        try
        {
            send(Obj("id", 1, "method", "initialize", "params", Obj("clientInfo", Obj("name", "codex-effortless", "title", null, "version", VERSION), "capabilities", null)));
            if (!WaitLine(lines, deadline, l => l != null && Regex.IsMatch(l, "\"id\"\\s*:\\s*1\\b"))) { failed = "init"; return answers; }
            send(Obj("method", "initialized"));
            for (int i = 0; i < jobs.Length; i++)
                send(Obj("id", 10 + i, "method", "thread/start", "params", Obj("model", MODEL, "ephemeral", true, "sandbox", "read-only", "approvalPolicy", "never", "cwd", cwd, "baseInstructions", jobs[i].System)));
            var threadJob = new Dictionary<string, int>();
            var over = new HashSet<int>();
            var tokens = new Dictionary<int, long>();
            DateTime? allOver = null;
            WaitLine(lines, deadline, l =>
            {
                if (l != null)
                {
                    var m = Parse(l) as Dictionary<string, object>;
                    if (m == null) return false;
                    double id = Num(Get(m, "id"), -1);
                    if (id >= 10 && id < 10 + jobs.Length && Get(m, "method") == null)
                    {
                        int i = (int)id - 10;
                        string tid = Str(Get(m, "result", "thread", "id"));
                        if (tid == null) over.Add(i);
                        else
                        {
                            threadJob[tid] = i;
                            var turn = Obj("threadId", tid, "effort", jobs[i].Effort ?? "none", "input", new object[] { Obj("type", "text", "text", "[effortless-judge] " + jobs[i].Ask) });
                            if (jobs[i].Schema != null) turn["outputSchema"] = jobs[i].Schema;
                            send(Obj("id", 20 + i, "method", "turn/start", "params", turn));
                        }
                    }
                    else
                    {
                        string method = Str(Get(m, "method"));
                        string tid = Str(Get(m, "params", "threadId"));
                        int i;
                        if (method != null && tid != null && threadJob.TryGetValue(tid, out i))
                        {
                            if (method == "item/completed" && Str(Get(m, "params", "item", "type")) == "agentMessage" && answers[i] == null)
                            {
                                answers[i] = new Answer { Text = Str(Get(m, "params", "item", "text")) };
                                over.Add(i);
                            }
                            else if (method == "turn/completed" || method == "error") over.Add(i);
                            else if (method == "thread/tokenUsage/updated") tokens[i] = (long)Num(Get(m, "params", "tokenUsage", "total", "totalTokens"), 0);
                        }
                    }
                }
                if (over.Count < jobs.Length) return false;
                // Every question answered or given up: wait a moment for the token counts.
                if (allOver == null) allOver = DateTime.UtcNow;
                bool counted = Enumerable.Range(0, jobs.Length).All(i => answers[i] == null || tokens.ContainsKey(i));
                return counted || (DateTime.UtcNow - allOver.Value).TotalSeconds > 1.5;
            });
            for (int i = 0; i < jobs.Length; i++) if (answers[i] != null && tokens.ContainsKey(i)) answers[i].Tokens = tokens[i];
            if (answers.All(a => a == null) && string.IsNullOrEmpty(failed)) failed = "turn";
            return answers;
        }
        catch (Exception e) { ProxyLog("judge: " + e.GetType().Name + ": " + e.Message); if (string.IsNullOrEmpty(failed)) failed = "error"; return answers; }
        finally
        {
            // The whole tree: anything the server started inherits this hook's handles and would keep Codex waiting.
            KillTree(proc);
        }
    }

    // Calls onLine for each line before the deadline, and with null on a quiet moment; true once it says so.
    static bool WaitLine(BlockingCollection<string> lines, DateTime deadline, Func<string, bool> onLine)
    {
        while (true)
        {
            if (onLine(null)) return true;
            double left = (deadline - DateTime.UtcNow).TotalMilliseconds;
            if (left <= 0) return false;
            string l;
            try
            {
                if (!lines.TryTake(out l, (int)Math.Min(left, 250))) { if (lines.IsCompleted) return false; continue; }
            }
            catch (InvalidOperationException) { return false; }
            if (onLine(l)) return true;
        }
    }

    // One HTTP POST: (status, body). The key goes in a header from memory; nothing shows in a process list.
    static KeyValuePair<int, string> Post(string url, string[] headers, string body, int timeoutSec)
    {
        try
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "POST";
            req.ContentType = "application/json";
            req.Timeout = timeoutSec * 1000;
            req.ReadWriteTimeout = timeoutSec * 1000;
            foreach (string h in headers) { int c = h.IndexOf(':'); req.Headers[h.Substring(0, c)] = h.Substring(c + 1).Trim(); }
            byte[] b = Utf8.GetBytes(body);
            using (Stream s = req.GetRequestStream()) s.Write(b, 0, b.Length);
            using (var res = (HttpWebResponse)req.GetResponse())
            using (var r = new StreamReader(res.GetResponseStream(), Utf8))
                return new KeyValuePair<int, string>((int)res.StatusCode, r.ReadToEnd());
        }
        catch (WebException e)
        {
            var res = e.Response as HttpWebResponse;
            if (res == null) return new KeyValuePair<int, string>(0, "");
            using (var r = new StreamReader(res.GetResponseStream(), Utf8)) return new KeyValuePair<int, string>((int)res.StatusCode, r.ReadToEnd());
        }
        catch { return new KeyValuePair<int, string>(0, ""); }
    }

    // The judge for a set of questions: Luna on your Codex login. Sets by to the judge that answered.
    static Answer[] AskJudge(Job[] jobs)
    {
        failed = "";
        by = "codex";
        return AskCodex(jobs, BUDGET);
    }

    static string JevKey()
    {
        string k = S("EFFORTLESS_TYPESAFE_KEY", "");
        if (k != "") return k;
        k = Env("TYPESAFE_API_KEY") ?? Environment.GetEnvironmentVariable("TYPESAFE_API_KEY", EnvironmentVariableTarget.User);
        if (!string.IsNullOrEmpty(k)) return k;
        // Only when Jev was picked outright is ~/.config/jev/.env read: a file holding a secret nobody asked us to use.
        if (JUDGE != "jev") return null;
        string t = ReadText(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), @".config\jev\.env")) ?? "";
        Match m = Regex.Match(t, "(?m)^\\s*TYPESAFE_API_KEY\\s*=\\s*['\"]?([^'\"\\s]+)");
        return m.Success ? m.Groups[1].Value : null;
    }

    class Verdict { public string Effort, Why, Down; public double Sure = 0.5; public bool Unsure; public long Tokens; }

    // Jev on TypeSafe: quick, and answers with its confidence. Below even odds it is unsure: Luna decides then.
    static Verdict AskJev(string key, string prompt, string current, string context)
    {
        var criteria = Obj("low", "quick answer, no tools, no planning", "medium", "normal work: a few tool calls or edits",
            "high", "hard or large multi-step job: many tool calls, costly mistakes", "xhigh", "very hard: a long investigation", "max", "the hardest research-level work");
        var body = Obj("model", "jev-latest",
            "state", Obj("task", JEV_TASK, "current_effort", current, "recent_conversation", context, "next_message", Cut(prompt, 4000)),
            "questions", Obj("effort", Obj("type", "choice", "instructions", "Which effort fits the next message?", "criteria", criteria)));
        var r = Post(JEV_URL, new[] { "Authorization: Bearer " + key }, Ser(body), 3);
        if (r.Key != 200) return new Verdict { Down = JevFailure(r.Key) };
        var j = Parse(r.Value);
        object a = Get(Get(j, "answers") ?? Get(j, "result", "answers"), "effort");
        string effort = Str(Get(a, "choice"));
        if (effort == null || !JUDGED.Contains(effort)) return new Verdict { Down = "Jev 回复无法读取" };
        object sure = Get(a, "confidence") ?? Get(a, "probabilities", effort);
        long tokens = (long)(Num(Get(j, "usage", "input_tokens"), 0) + Num(Get(j, "usage", "output_tokens"), 0));
        if (sure != null && Num(sure, 1) < 0.5) return new Verdict { Unsure = true, Tokens = tokens };
        return new Verdict { Effort = effort, Sure = sure != null ? Num(sure, 0.5) : 0.5, Why = sure != null ? string.Format(Inv, "{0}% sure", (int)(Num(sure, 0) * 100 + 0.5)) : "", Tokens = tokens };
    }
    static string JevFailure(int c)
    {
        if (c == 0) return "Jev 没有及时回答";
        if (c == 401 || c == 403) return "Jev 拒绝了 key（" + c + "）";
        if (c == 402) return "Jev 额度用完了（" + c + "）";
        if (c == 429) return "Jev 限流了（" + c + "）";
        return "Jev 出错了（" + c + "）";
    }

    static Dictionary<string, object> JsonIn(string text)
    {
        if (text == null) return null;
        Match m = Regex.Match(text, @"\{.*\}", RegexOptions.Singleline);
        return m.Success ? Parse(m.Value) as Dictionary<string, object> : null;
    }
    static Verdict ParseVerdict(string text)
    {
        var v = JsonIn(text);
        if (v == null) return null;
        string effort = (Str(Get(v, "effort")) ?? "").ToLowerInvariant();
        if (!JUDGED.Contains(effort)) return null;
        double sure = Num(Get(v, "sure"), 0.5);
        if (sure < 0 || sure > 1) sure = 0.5;
        string why = Regex.Replace(Regex.Replace(Cut(Str(Get(v, "why")) ?? "", 60), "[\"\\\\]", ""), "[.。!！ ]+$", "");
        return new Verdict { Effort = effort, Sure = sure, Why = why };
    }
    static string ParseHandoff(string text)
    {
        var v = JsonIn(text);
        string h = v == null ? null : Get(v, "handoff") as string;
        return h != null && h.Trim() != "" ? Cut(h.Trim(), 70) : null;
    }

    // ------------------------------------------------------------ picking the effort

    // The slider tips close calls only; then the floor and ceiling; save mode caps at medium; then the efforts the model takes.
    static string ShapeEffort(string effort, double sure, List<string> supported)
    {
        int i = Rank(effort);
        if (BIAS != 0 && sure < (Math.Abs(BIAS) == 1 ? 0.65 : 0.85))
        {
            i += Math.Sign(BIAS);
            i = Math.Max(Rank("low"), Math.Min(Rank("max"), i));
        }
        int lo = Rank(MIN), hi = Rank(MAX);
        if (lo < 0) lo = Rank("low");
        if (hi < 0) hi = Rank("max");
        if (hi < lo) hi = lo;
        i = Math.Max(lo, Math.Min(hi, i));
        if (Saving() && i > Rank("medium")) i = Rank("medium");
        return FitSupported(LEVELS[i], supported);
    }

    // The nearest level the model takes, the higher one on a tie.
    static string FitSupported(string level, List<string> supported)
    {
        int i = Rank(level);
        if (supported != null && supported.Count > 0 && !supported.Contains(level))
        {
            int best = -1, dist = int.MaxValue;
            foreach (string s in supported)
            {
                int r = Rank(s);
                if (r < 0) continue;
                int d = Math.Abs(r - i);
                if (d < dist || (d == dist && r > best)) { best = r; dist = d; }
            }
            if (best >= 0) i = best;
        }
        return LEVELS[i];
    }

    static bool Saving()
    {
        string u = ReadText(Path.Combine(Data, "save-until"));
        if (u == null) return false;
        if (D(u.Trim()) > Now()) return true;
        try { File.Delete(Path.Combine(Data, "save-until")); } catch { }
        return false;
    }
    static bool AutoOn() { return !File.Exists(Path.Combine(Data, "auto-off")); }

    class Decision
    {
        public string Effort, Raw, Why, By, Action, Fail, Down, Handoff;
        public double Sure;
        public long Ms, Tokens;
        public bool HandoffChecked;
    }

    // One prompt through the pipeline every caller shares (the hook, Auto, the bench): a level named in the prompt
    // ("max effort") runs as asked, a follow-up keeps the effort, else Jev (when set) and then Luna judge. With handoff
    // evidence, the handoff question goes along with Luna's.
    static Decision Decide(string prompt, string current, string lastUser, string lastAssistant, double percent, List<string> supported,
        string attachments, string handoff, bool onlyHandoff)
    {
        by = "-";
        var r = new Decision();
        var sw = Stopwatch.StartNew();
        string context = ContextText(lastUser, lastAssistant);
        string asked = prompt;
        if (!string.IsNullOrEmpty(attachments)) asked += "\n\n[The message comes with " + attachments + " to look at.]";
        string named = !onlyHandoff && !Regex.IsMatch(prompt, @"^\s*[$/]") ? NamedEffort(prompt) : null;
        if (onlyHandoff) { r.Effort = current; r.Action = "skip"; }
        else if (named != null)
        {
            // The person said the level: it runs past Min, Max and save mode, and no judge is asked.
            by = r.By = "named";
            r.Effort = FitSupported(named, supported); r.Raw = named; r.Sure = 1; r.Why = "你点名要的"; r.Action = "named";
            if (handoff == null) return r;
        }
        else if (string.IsNullOrEmpty(attachments) && Rank(current) >= 0 && KeepsEffort(prompt, lastAssistant))
        {
            r.Effort = r.Raw = current; r.Sure = 1; r.Why = ""; r.Action = "follow-up";
            if (handoff == null) return r;
        }
        string key = r.Action == null && JUDGE != "luna" ? JevKey() : null;
        if (key != null)
        {
            Verdict j = AskJev(key, asked, current, context);
            r.Tokens += j.Tokens;
            if (j.Down != null) r.Down = j.Down;
            if (j.Effort != null) { by = "jev"; r.Raw = j.Effort; r.Sure = j.Sure; r.Why = j.Why; r.Action = "judged"; }
        }
        var jobs = new List<Job>();
        int effortJob = -1, handoffJob = -1;
        if (r.Action == null) { effortJob = jobs.Count; jobs.Add(new Job { System = JUDGE_SYSTEM, Ask = JudgeQuestion(asked, current, context, percent), Schema = EffortSchema() }); }
        if (handoff != null) { handoffJob = jobs.Count; jobs.Add(new Job { System = HANDOFF_SYSTEM, Ask = handoff, Schema = HandoffSchema() }); }
        if (jobs.Count > 0)
        {
            string judgeBy = by;
            Answer[] answers = AskJudge(jobs.ToArray());
            r.Tokens += answers.Where(a => a != null).Sum(a => a.Tokens);
            if (effortJob >= 0)
            {
                Verdict v = ParseVerdict(answers[effortJob] == null ? null : answers[effortJob].Text);
                if (v != null) { r.Raw = v.Effort; r.Sure = v.Sure; r.Why = v.Why; r.Action = "judged"; }
                else
                {
                    r.Action = "fail";
                    r.Fail = by + ":" + (answers[effortJob] != null ? "verdict" : (string.IsNullOrEmpty(failed) ? "turn" : failed));
                    if (answers[effortJob] == null && r.Down == null) r.Down = "判断器没有及时回答，档位保持不变";
                }
            }
            else by = judgeBy;
            if (handoffJob >= 0 && answers[handoffJob] != null) { r.HandoffChecked = true; r.Handoff = ParseHandoff(answers[handoffJob].Text); }
        }
        r.Ms = sw.ElapsedMilliseconds;
        r.By = by;
        r.Effort = r.Action == "judged" ? ShapeEffort(r.Raw, r.Sure, supported) : (r.Effort ?? current);
        return r;
    }
    static string JudgeName(string b) { return b == "jev" ? "Jev" : b == "named" ? "你" : "Luna"; }

    // ------------------------------------------------------------ the hook

    static string LimitName(double m) { return m == 300 ? "5 小时" : m == 10080 ? "每周" : m % 60 == 0 ? (m / 60).ToString(Inv) + " 小时" : m.ToString(Inv) + " 分钟"; }
    static Limit Hottest(Transcript t) { return t.Limits.Values.OrderByDescending(l => l.Pct).FirstOrDefault(); }

    // Running hot is said once per usage window (its length and reset time), and once more when it passes HOT_FINAL.
    const double HOT_FINAL = 95;
    // To the quarter hour: the reset time Codex reports can shift by seconds between turns.
    static string HotWindow(Limit top) { return top.Minutes.ToString(Inv) + " " + (top.Resets > 0 ? Math.Floor(top.Resets / 900 + 0.5).ToString(Inv) : ""); }
    static bool HotVisible(Limit top, Dictionary<string, object> said)
    {
        if (said == null || Str(Get(said, "window")) != HotWindow(top)) return true;
        return top.Pct >= HOT_FINAL && Num(Get(said, "pct"), 0) < HOT_FINAL;
    }

    static int Hook()
    {
        if (Env("EFFORTLESS_JUDGE") != null || MODE == "off") return 0;
        string raw = new StreamReader(Console.OpenStandardInput(), Utf8).ReadToEnd();
        var p = Parse(raw) as Dictionary<string, object>;
        if (p == null) return 0;
        string prompt = Str(Get(p, "prompt")) ?? "";
        if (prompt.Trim() == "") return 0;
        Session = SafeId(Str(Get(p, "session_id")) ?? "");
        string sid = Session != "" ? Session : "none";
        if (Session == "") Session = "-";
        string tpath = Str(Get(p, "transcript_path"));
        Transcript t = ReadTranscript(tpath);
        WriteJson(Path.Combine(Data, "last-session"), Obj("id", sid, "transcript", tpath, "at", Now()));
        string stPath = Path.Combine(Data, "sessions", sid + ".json");
        var st = ReadJson(stPath) ?? new Dictionary<string, object>();
        st["prompts"] = Num(Get(st, "prompts"), 0) + 1;
        string key = Md5Key(prompt);
        var notes = new List<string>();
        string model = Str(Get(p, "model")) ?? t.Model;
        ModelInfo info = GetModelInfo(model);
        string current = t.Effort ?? ConfigEffort() ?? (info != null ? info.Default : null) ?? "medium";
        var users = new List<string>(t.Users);
        if (users.Count > 0 && users[users.Count - 1] == prompt) users.RemoveAt(users.Count - 1);
        string lastUser = users.Count > 0 ? users[users.Count - 1] : null;
        double idle = t.LastAt > 0 ? (Now() - t.LastAt) / 60 : 0;
        bool cold = t.LastAt > 0 && idle >= COLD_MINUTES;
        var warned = Get(st, "warned") as Dictionary<string, object> ?? new Dictionary<string, object>();
        st["warned"] = warned;
        Func<string, bool> once = k => { if (warned.ContainsKey(k)) return false; warned[k] = 1; return true; };

        // A quick handoff from a cold chat: the chat's model would reread the whole context at full price to write it.
        // Luna writes it from the transcript instead, in the background, as the original has Haiku do. Sent again in the
        // same idle spell, the prompt goes through and the chat's model writes it.
        if (cold && Regex.IsMatch(prompt, @"^\s*\$effortless\s+handoff\s*$", RegexOptions.IgnoreCase) && !SameTime(Get(st, "cold_handoff_for"), t.LastAt) && StartHandoffWriter(tpath))
        {
            st["cold_handoff_for"] = t.LastAt;
            WriteJson(stPath, st);
            LogRow(current, "-", "-", 0, 0, "cold-handoff");
            SayJson(Obj("decision", "block", "reason", "effortless: 对话已冷，快速交接改由 " + MODEL + " 在后台从对话记录写，不让当前模型按全价重读约 " + Ktokens(t.Tokens) +
                " tokens。输入 /new 开新对话，发送 $effortless resume 即可接上（还没写完会稍等）。想让当前模型来写，直接回车重发。"));
            return 0;
        }

        // A chat gone cold: the next message rereads the whole context at full price. Held back once, so /compact or a
        // handoff can come first; sent again (or anything else sent in the same idle spell), it goes through.
        if (cold && COLD != "off" && !HIDE.Contains("cold") && t.Tokens >= COLD_TOKENS && !SameTime(Get(st, "cold_for"), t.LastAt))
        {
            string msg = string.Format(Inv, "effortless: 对话已冷（闲置 {0} 分钟），这条消息会按全价重读约 {1} tokens。", (int)idle, Ktokens(t.Tokens));
            if (COLD == "block")
            {
                st["cold_for"] = t.LastAt;
                WriteJson(stPath, st);
                LogRow(current, "-", "-", 0, 0, "cold-block");
                SayJson(Obj("decision", "block", "reason", msg + "想省就先 /compact 或 $effortless handoff；原文还在输入框里，直接回车重发就照常发送。"));
                return 0;
            }
            notes.Add(msg + "下次闲置这么久后，先 /compact 或 $effortless handoff 更省。");
        }

        var routed = ReadJson(Path.Combine(Data, "routed", sid));
        if (routed != null && Now() - Num(Get(routed, "at"), 0) >= 120) routed = null;
        double percent = t.Percent;
        string evidence = null;
        if (HANDOFF_FROM != "off" && percent >= D(HANDOFF_FROM))
        {
            st["since_check"] = Num(Get(st, "since_check"), 0) + 1;
            if (Num(st["since_check"], 0) >= HANDOFF_EVERY) { st["since_check"] = 0; evidence = HandoffEvidence(t.Users, t.LastAssistant, prompt, percent, cold); }
        }
        else { st["since_check"] = 0; st["advice"] = null; }

        string block = null;
        Decision r = null;
        bool noUpdates = info != null && info.Updates is bool && !(bool)info.Updates;
        if (routed != null)
        {
            // Auto already set this turn's effort (effortless codex, or Codex Desktop with Auto on): say what it did.
            by = Str(Get(routed, "by")) ?? "-";
            string rEffort = Str(Get(routed, "effort")), rPrev = Str(Get(routed, "previous")), rWhy = Str(Get(routed, "why")), rDown = Str(Get(routed, "down"));
            if (Str(Get(routed, "action")) == "manual")
            {
                if (Get(st, "manual_said") == null) { st["manual_said"] = 1; notes.Add("effortless: 你手动改了档位，本对话的 Auto 已暂停（你说了算）。输入 $effortless auto 恢复。"); }
            }
            else if (rEffort != null && rEffort != rPrev)
            {
                string why = (!HIDE.Contains("reason") || Str(Get(routed, "action")) == "named") && !string.IsNullOrEmpty(rWhy) ? " · " + JudgeName(by) + "：" + rWhy : "";
                notes.Add("effortless: 自动切到 " + rEffort + "（原 " + (rPrev ?? "?") + "）" + why);
            }
            if (!string.IsNullOrEmpty(rDown) && once(rDown)) notes.Add("effortless: " + rDown);
            LogRow(rPrev, rEffort, Str(Get(routed, "sure")), (long)Num(Get(routed, "ms"), 0), (long)Num(Get(routed, "tokens"), 0), "auto:" + (Str(Get(routed, "action")) ?? "-"));
            if (evidence != null) r = Decide(prompt, current, null, null, 0, null, null, evidence, true);
        }
        else if (!AutoOn() || noUpdates)
        {
            if (noUpdates && AutoOn() && Get(st, "paused_said") == null) { st["paused_said"] = 1; notes.Add("effortless: " + model + " 不支持在对话中途改档位，Auto 在这个模型上暂停。"); }
            if (evidence != null) r = Decide(prompt, current, null, null, 0, null, null, evidence, true);
            LogRow(current, "-", "-", 0, 0, AutoOn() ? "paused-model" : "auto-off");
        }
        else if (Rank(current) < 0)
        {
            LogRow(current, "-", "-", 0, 0, "unknown-effort");
        }
        else
        {
            // No Auto in this session: the judge picks, and the hook says which effort to switch to.
            string heldPath = Path.Combine(Data, "held");
            var held = ReadJson(heldPath);
            if (held != null && Str(Get(held, "key")) == key && Now() - Num(Get(held, "at"), 0) < 900)
            {
                // A prompt held back, sent again: the advice was seen, so it goes through.
                try { File.Delete(heldPath); } catch { }
                LogRow(current, "-", "-", 0, 0, "resent");
            }
            else
            {
                r = Decide(prompt, current, lastUser, t.LastAssistant, percent, info != null ? info.Supported : null, null, evidence, false);
                if (r.Down != null && once(r.Down)) notes.Add("effortless: " + r.Down);
                string sure = r.Sure.ToString("0.00", Inv);
                if (r.Action == "follow-up") LogRow(current, "-", "-", 0, 0, "follow-up");
                else if (r.Action == "fail") LogRow(current, "-", "-", r.Ms, r.Tokens, "fail:" + r.Fail);
                else
                {
                    int gap = Rank(r.Effort) - Rank(current);
                    if (gap == 0) LogRow(current, r.Effort, sure, r.Ms, r.Tokens, "same");
                    else
                    {
                        string how = t.Desktop ? "在输入框旁的推理档位菜单切到 " + r.Effort : gap > 0 ? "按 Alt+. 升 " + gap + " 档" : "按 Alt+, 降 " + (-gap) + " 档";
                        string text = "effortless: 建议 " + r.Effort + "（当前 " + current + "）— " + (string.IsNullOrEmpty(r.Why) ? JudgeName(r.By) : r.Why);
                        if (MODE != "warn" && gap >= BLOCK_GAP)
                        {
                            LogRow(current, r.Effort, sure, r.Ms, r.Tokens, "block");
                            WriteJson(heldPath, Obj("key", key, "at", Now()));
                            block = text + "。" + how + " 后直接回车重发（原文还在输入框里，重发会直接放行）。";
                        }
                        else
                        {
                            LogRow(current, r.Effort, sure, r.Ms, r.Tokens, "warn");
                            notes.Add(text + "（" + how + "，对下一条消息生效）");
                        }
                    }
                }
            }
        }

        // A fresh chat would serve better: said when the advice appears or changes.
        if (r != null && r.HandoffChecked)
        {
            if (r.Handoff != null && (Str(Get(st, "advice")) ?? "") != r.Handoff)
            {
                string full = HANDOFF_SKILL != "" ? "$" + HANDOFF_SKILL : "$effortless handoff full（检查 git、写 HANDOFF.md）";
                notes.Add("effortless: 建议换个新对话 — " + r.Handoff + "。输入 $effortless handoff（快速）或 " + full + "。");
            }
            st["advice"] = r.Handoff;
        }

        // Swamped: every message rereads a lot of context. Said again once the context has grown 50k tokens more.
        if (percent >= SWAMP_AT && !HIDE.Contains("swamp"))
        {
            if (!cold && (Get(st, "swamp_at") == null || t.Tokens >= Num(Get(st, "swamp_at"), 0) + 50000))
            {
                notes.Add(string.Format(Inv, "effortless: 对话臃肿 — 上下文已用 {0}%（约 {1} tokens），每条消息都要重读这些内容。可以 /compact 或 $effortless handoff。", (int)(percent + 0.5), Ktokens(t.Tokens)));
                st["swamp_at"] = t.Tokens;
            }
        }
        else st.Remove("swamp_at");

        // Running hot: a usage window past HOT_AT. Said once for that window, in any chat, and once more at HOT_FINAL%.
        Limit top = Hottest(t);
        if (top != null)
        {
            string saidPath = Path.Combine(Data, "hot-said");
            if (top.Pct >= HOT_AT && !HIDE.Contains("hot") && HotVisible(top, ReadJson(saidPath)))
            {
                string reset = top.Resets > 0 ? "，" + ClockOf(top.Resets) + " 重置" : "";
                string save = Saving() ? "省钱模式已开（Auto 最高 medium）。" : "输入 $effortless save 开启省钱模式：Auto 最高只到 medium，直到额度重置。";
                notes.Add(string.Format(Inv, "effortless: {0}额度已用 {1}%{2}。{3}", LimitName(top.Minutes), (int)top.Pct, reset, save));
                WriteJson(saidPath, Obj("window", HotWindow(top), "pct", top.Pct));
            }
        }

        string upd = Path.Combine(Data, "update-available");
        if (File.Exists(upd) && Get(st, "update_said") == null)
        {
            st["update_said"] = 1;
            notes.Add("effortless: 有新版本（领先 " + (ReadText(upd) ?? "").Trim() + " 个提交）。输入 $effortless update 更新。");
        }
        CheckUpdateLater();

        if (BAR == "always")
        {
            var bar = new List<string> { "effortless: " + (routed != null ? Str(Get(routed, "effort")) : current) };
            if (t.Window > 0) bar.Add(string.Format(Inv, "◔ {0}%", (int)(percent + 0.5)));
            if (t.LastAt > 0) bar.Add(cold ? "❄ 缓存已冷" : string.Format(Inv, "缓存约剩 {0} 分钟", (int)(COLD_MINUTES - idle)));
            if (top != null) bar.Add(string.Format(Inv, "{0} {1}%", LimitName(top.Minutes), (int)top.Pct));
            notes.Insert(0, string.Join(" · ", bar));
        }

        WriteJson(stPath, st);
        if (new Random().Next(20) == 0) Forget();
        if (block != null) { notes.Add(block); SayJson(Obj("decision", "block", "reason", string.Join("\n", notes))); }
        else if (notes.Count > 0) SayJson(Obj("systemMessage", string.Join("\n", notes)));
        return 0;
    }

    // Sessions untouched for a week are forgotten.
    static void Forget()
    {
        foreach (string dir in new[] { Path.Combine(Data, "sessions"), Path.Combine(Data, "routed") })
            foreach (string f in Directory.GetFiles(dir))
                try { if (File.GetLastWriteTimeUtc(f) < DateTime.UtcNow.AddDays(-7)) File.Delete(f); } catch { }
    }

    // At most every 6 hours, in the background: is the repo this was installed from behind its remote?
    static void CheckUpdateLater()
    {
        if (UPDATE_CHECK != "on") return;
        string src = (ReadText(Path.Combine(Here, "source")) ?? "").Trim();
        if (src == "" || !Directory.Exists(Path.Combine(src, ".git"))) return;
        string stamp = Path.Combine(Data, "update-checked");
        if (File.Exists(stamp) && File.GetLastWriteTimeUtc(stamp) > DateTime.UtcNow.AddHours(-6)) return;
        WriteText(stamp, Now().ToString(Inv));
        try
        {
            StartDetached("update-check");
        }
        catch { }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, int flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    // Runs this program again on its own, so the hook can finish. Process.Start would hand it the hook's output (even
    // with pipes of its own and the handles made uninheritable, as measured), and Codex would wait until it exits:
    // CreateProcess with no handles inherited and no window.
    static void StartDetached(string args)
    {
        string self = Process.GetCurrentProcess().MainModule.FileName;
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        PROCESS_INFORMATION pi;
        if (!CreateProcess(self, new StringBuilder(Quote(self) + " " + args), IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, null, ref si, out pi))
            throw new System.ComponentModel.Win32Exception();
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
    static int UpdateCheck()
    {
        string src = (ReadText(Path.Combine(Here, "source")) ?? "").Trim();
        if (src == "") return 1;
        if (Run("git", "-C \"" + src + "\" fetch --quiet") == null) return 1;
        string n = (Run("git", "-C \"" + src + "\" rev-list --count HEAD..@{u}") ?? "").Trim();
        int count;
        string f = Path.Combine(Data, "update-available");
        if (int.TryParse(n, out count) && count > 0) WriteText(f, n); else try { File.Delete(f); } catch { }
        return 0;
    }
    static string Run(string exe, string args)
    {
        try
        {
            var p = Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Utf8 });
            p.ErrorDataReceived += (s, e) => { };
            p.BeginErrorReadLine();
            string o = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            return p.ExitCode == 0 ? o : null;
        }
        catch { return null; }
    }

    // ------------------------------------------------------------ commands

    static string LastTranscript()
    {
        string tr = Str(Get(ReadJson(Path.Combine(Data, "last-session")), "transcript"));
        return tr != null && File.Exists(tr) ? tr : null;
    }
    static List<string[]> LogRows()
    {
        if (!File.Exists(LogPath)) return new List<string[]>();
        return File.ReadAllLines(LogPath, Utf8).Where(l => l != "").Select(l => l.Split('\t')).ToList();
    }

    static int Stats()
    {
        var sb = new StringBuilder();
        string path = LastTranscript();
        string sid = Str(Get(ReadJson(Path.Combine(Data, "last-session")), "id")) ?? "";
        if (path != null)
        {
            Transcript t = ReadTranscript(path);
            var cost = new Dictionary<string, double>();
            var reqs = new Dictionary<string, int>();
            var turns = new Dictionary<string, HashSet<string>>();
            double total = 0;
            // Relative cost: input 1, cached input 0.1, output 8 (GPT pricing at the time of writing).
            for (int i = 0; i < t.Usage.Count; i++)
            {
                string e;
                if (!t.TurnEffort.TryGetValue(t.UsageTurn[i], out e)) e = "?";
                double[] u = t.Usage[i];
                double c = (u[0] - u[1]) + 0.1 * u[1] + 8 * u[2];
                cost[e] = (cost.ContainsKey(e) ? cost[e] : 0) + c;
                reqs[e] = (reqs.ContainsKey(e) ? reqs[e] : 0) + 1;
                if (!turns.ContainsKey(e)) turns[e] = new HashSet<string>();
                turns[e].Add(t.UsageTurn[i]);
                total += c;
            }
            sb.Append("本对话（最近一个）：\n");
            if (total > 0)
                foreach (string e in cost.Keys.OrderBy(Rank))
                    sb.AppendFormat(Inv, "  {0,-7} {1,3} 轮  {2,4} 次请求  费用占比 {3,3}%\n", e, turns[e].Count, reqs[e], (int)(100 * cost[e] / total + 0.5));
            else sb.Append("  还没有用量记录。\n");
        }
        var rows = LogRows();
        Action<List<string[]>> judge = list =>
        {
            var act = list.GroupBy(r => r.Length > 6 ? r[6] : "?").OrderByDescending(g => g.Count()).Select(g => g.Key + " " + g.Count());
            sb.AppendFormat(Inv, "  {0} 条消息：{1}\n", list.Count, string.Join("，", act));
            var timed = list.Where(r => r.Length > 5 && Num(D(r[4]), 0) > 0).ToList();
            var judges = list.Where(r => r.Length > 7 && r[7] != "-").GroupBy(r => r[7]).OrderBy(g => g.Key).Select(g => JudgeName(g.Key) + " " + g.Count());
            if (timed.Count > 0)
                sb.AppendFormat(Inv, "  判断器：{0}；平均 {1:0.0} 秒、{2} tokens\n", string.Join("，", judges), timed.Average(r => D(r[4])) / 1000, (int)timed.Average(r => D(r[5])));
        };
        var mine = rows.Where(r => r.Length > 8 && r[8] == sid).ToList();
        if (mine.Count > 0) { sb.Append("Auto 在本对话：\n"); judge(mine); }
        if (rows.Count > 0) { sb.Append("全部记录：\n"); judge(rows); } else sb.Append("还没有判断记录（" + LogPath + "）。\n");
        Out(sb.ToString());
        return 0;
    }

    static int DebugInfo()
    {
        var sb = new StringBuilder();
        sb.AppendFormat("codex-effortless {0}（{1}）\n", VERSION, Here);
        sb.AppendFormat(Inv, "设置：MODE={0} JUDGE={1} MODEL={2} MIN={3} MAX={4} BIAS={5} COLD={6}/{7}分钟 SWAMP_AT={8} HOT_AT={9} HANDOFF_FROM={10}\n", MODE, JUDGE, MODEL, MIN, MAX, BIAS, COLD, COLD_MINUTES, SWAMP_AT, HOT_AT, HANDOFF_FROM);
        sb.Append("判断器：Codex 登录上的 " + MODEL + (JevKey() != null ? "；Jev 先答" : "") + "\n");
        sb.Append("Auto：" + (AutoOn() ? "开" : "关（$effortless auto 打开）") + "；省钱模式：" + (Saving() ? "开" : "关") + "\n");
        string cli = Environment.GetEnvironmentVariable("CODEX_CLI_PATH", EnvironmentVariableTarget.User);
        sb.Append("Codex Desktop 的 Auto：" + (cli != null && cli.EndsWith("effortless.exe", StringComparison.OrdinalIgnoreCase) ? "开（CODEX_CLI_PATH 指向 effortless.exe）" : "关（effortless desktop on 打开）") + "\n");
        sb.Append("codex：" + (FindCodex() ?? "找不到") + "\n");
        string path = LastTranscript();
        if (path != null)
        {
            Transcript t = ReadTranscript(path);
            sb.AppendFormat(Inv, "最近对话：模型 {0}，档位 {1}，上下文 {2} / {3}（{4}%）{5}\n", t.Model ?? "?", t.Effort ?? "?", Ktokens(t.Tokens), Ktokens(t.Window), (int)(t.Percent + 0.5), t.Desktop ? "，Codex Desktop" : "");
            if (t.LastAt > 0) sb.AppendFormat(Inv, "  上次回答在 {0} 分钟前\n", (int)((Now() - t.LastAt) / 60));
            foreach (Limit l in t.Limits.Values.OrderBy(l => l.Minutes)) sb.AppendFormat(Inv, "  {0}额度 {1}%\n", LimitName(l.Minutes), (int)l.Pct);
        }
        var rows = LogRows();
        if (rows.Count > 0) { sb.Append("最近的判断：\n"); foreach (var r in rows.Skip(Math.Max(0, rows.Count - 5))) sb.Append("  " + string.Join("\t", r) + "\n"); }
        Out(sb.ToString());
        return 0;
    }

    static int AutoCmd(string arg)
    {
        bool on = arg == "on" ? true : arg == "off" ? false : arg == "status" ? AutoOn() : !AutoOn();
        string f = Path.Combine(Data, "auto-off");
        if (on) { try { File.Delete(f); } catch { } } else WriteText(f, Now().ToString(Inv));
        // A pause from changing the effort by hand ends too.
        foreach (string p in Directory.GetFiles(Path.Combine(Data, "routed"), "*.paused")) try { File.Delete(p); } catch { }
        Out(on ? "Auto 已打开：每条消息由判断器挑选档位。\n" : "Auto 已关闭：档位由你自己设置，effortless 只做其他提醒。\n");
        return 0;
    }

    static int SaveCmd(string arg)
    {
        bool on = arg == "on" ? true : arg == "off" ? false : !Saving();
        string f = Path.Combine(Data, "save-until");
        if (!on) { try { File.Delete(f); } catch { } Out("省钱模式已关闭。\n"); return 0; }
        double until = Now() + 5 * 3600;
        string path = LastTranscript();
        if (path != null) { Limit top = Hottest(ReadTranscript(path)); if (top != null && top.Resets > Now()) until = top.Resets; }
        WriteText(f, ((long)until).ToString(Inv));
        Out("省钱模式已开启：Auto 最高只到 medium，直到 " + ClockOf(until) + "（额度重置）。\n");
        return 0;
    }

    static int ConfigCmd(string[] a)
    {
        string file = Path.Combine(Here, "effortless.conf");
        if (a.Length > 0 && a[0] == "set")
        {
            if (a.Length < 2 || !Regex.IsMatch(a[1], "^EFFORTLESS_[A-Z_]+$")) { Out("用法：config set EFFORTLESS_XXX 值\n"); return 2; }
            string k = a[1], v = string.Join(" ", a.Skip(2));
            if (v.Contains("\n") || v.Contains("\r")) { Out("值里不能有换行\n"); return 2; }
            string text = ReadText(file) ?? "";
            string line = k + "=${" + k + ":-" + v + "}";
            var re = new Regex("(?m)^\\s*" + Regex.Escape(k) + "=.*$");
            text = re.IsMatch(text) ? re.Replace(text, line.Replace("$", "$$"), 1) : text + (text == "" || text.EndsWith("\n") ? "" : "\n") + line + "\n";
            WriteText(file, text);
            Out("已设置 " + k + "=" + v + "\n");
            return 0;
        }
        var sb = new StringBuilder();
        foreach (var kv in Conf.OrderBy(x => x.Key)) sb.Append(kv.Key + "=" + (kv.Key.EndsWith("KEY") && kv.Value != "" ? "（已设置，不显示）" : kv.Value) + "\n");
        Out(sb.ToString());
        return 0;
    }

    static int TestCmd(string[] a)
    {
        string prompt = a.Length > 0 ? string.Join(" ", a) : "rename one variable in a single file";
        Decision r = Decide(prompt, "medium", null, null, 0, null, null, null, false);
        if (r.Action == "judged" || r.Action == "named") { Out(string.Format(Inv, "{0} 回答：{1}（{2:0}% 把握，{3:0.0} 秒）{4}\n", JudgeName(r.By), r.Effort, r.Sure * 100, r.Ms / 1000.0, r.Why != "" ? " — " + r.Why : "")); return 0; }
        Out("判断失败：" + (r.Fail ?? r.Action) + (r.Down != null ? "（" + r.Down + "）" : "") + "\n");
        return 1;
    }

    static int HandoffSave()
    {
        string text = new StreamReader(Console.OpenStandardInput(), Utf8).ReadToEnd();
        if (text.Trim() == "") { Out("没有收到交接内容\n"); return 1; }
        WriteText(Path.Combine(Data, "handoff.md"), text);
        Out("交接已保存（" + Path.Combine(Data, "handoff.md") + "）。\n");
        if (HANDOFF_AFTER == "copy") { CopyText(text); Out("也已复制到剪贴板：粘贴到新对话即可。\n"); }
        else Out("下一步：开一个新对话（CLI 输入 /new；Desktop 点新对话），然后发送 $effortless resume。\n");
        return 0;
    }

    static int HandoffShow()
    {
        // A handoff Luna is still writing from a cold chat: wait a little (the shell tool has a short timeout), then say so.
        DateTime deadline = DateTime.UtcNow.AddSeconds(8);
        Dictionary<string, object> w;
        while ((w = HandoffWriting()) != null)
        {
            if (Get(w, "failed") != null) { Out("Luna 没写成交接（" + Str(Get(w, "why")) + "）。回到原来的对话再发一次 $effortless handoff，由那个对话的模型来写。\n"); return 1; }
            if (DateTime.UtcNow >= deadline) { Out(string.Format(Inv, "交接还在写（已 {0} 秒）。稍等十几秒再运行一次 resume。\n", (int)(Now() - Num(Get(w, "at"), 0)))); return 3; }
            Thread.Sleep(1000);
        }
        string text = ReadText(Path.Combine(Data, "handoff.md"));
        if (text == null) { Out("没有保存的交接\n"); return 1; }
        string ask = HANDOFF_AFTER == "confirm"
            ? "Read this, say in two lines where things stand and what is next, then wait for me."
            : "Continue with the next step. If it is marked \"needs user\", say what you need and wait.";
        Out("Handoff from the previous chat:\n\n" + text + "\n\n" + ask + "\n");
        return 0;
    }

    // ------------------------------------------------------------ the handoff from a cold chat

    const string HANDOFF_PROMPT = @"Write a handoff so this work can continue in a fresh chat that has no other context.

Start with the project, its folder and the branch. Then:
- Goal: one or two lines.
- Done: what changed, with file paths, and how each change was checked. Never present something planned, skipped or untested as done.
- Not done: what is half done, and the concrete blocker (a failed check, a missing approval, an open question).
- Git: local changes, local commits, pushed commits and open PRs, as last seen in this chat. You cannot check now, so say ""as of last check"".
- Next steps in priority order. Make the first one runnable: a file path, a command or a specific decision. Mark every step that needs the user with ""needs user"".
- To resume: the start command, the preview URL, and the limits on what is allowed (what needs the user's approval, test vs production).
- Do not redo: decisions made and why, approaches that failed.

Give only the final state of anything that changed during the chat. Point to specs, plans and files instead of copying them. Leave out what is finished and no longer matters. Never include secrets, environment values or raw logs. Write in the language the user writes in. Short bullets, at most about 40 lines. Do not use tools. Reply with the handoff only, no preamble or farewell.";
    const int COMPACT_TAIL = 6;

    // The transcript as plain text: every message whole, tool calls and results cut short except in the last few messages.
    static string CompactTranscript(List<KeyValuePair<string, string>> msgs, int toolChars, int tailChars)
    {
        Func<string, int, string> shorten = (s, n) => s.Length > n ? s.Substring(0, n) + " …[" + (s.Length - n) + " more characters]" : s;
        var said = Enumerable.Range(0, msgs.Count).Where(i => msgs[i].Key == "user" || msgs[i].Key == "assistant").ToList();
        int tailFrom = said.Count > COMPACT_TAIL ? said[said.Count - COMPACT_TAIL] : 0;
        var sb = new StringBuilder();
        for (int i = 0; i < msgs.Count; i++)
        {
            bool inTail = i >= tailFrom;
            string role = msgs[i].Key, text = msgs[i].Value ?? "";
            if (role == "tool") sb.Append("  [" + shorten(text, inTail ? tailChars : 400) + "]\n");
            else if (role == "result") sb.Append("  → " + shorten(text, inTail ? tailChars : toolChars) + "\n");
            else sb.Append("\n" + (role == "user" ? "USER" : "CODEX") + ": " + text.Trim() + "\n");
        }
        return sb.ToString().Trim();
    }
    // Roughly: four characters of ASCII to a token, one of anything else.
    static double EstTokens(string s) { int wide = s.Count(c => c > 0x7f); return (s.Length - wide) / 4.0 + wide; }

    static Dictionary<string, object> HandoffWriting()
    {
        string path = Path.Combine(Data, "handoff-writing");
        var w = ReadJson(path);
        if (w == null) return null;
        if (Get(w, "failed") != null || Now() - Num(Get(w, "at"), 0) < 200) return w;
        try { File.Delete(path); } catch { }
        return null;
    }

    // Starts `handoff-write` on its own, so the hook can answer at once. False when there is no transcript to write from.
    static bool StartHandoffWriter(string path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return false;
        WriteJson(Path.Combine(Data, "handoff-writing"), Obj("at", Now()));
        try { StartDetached("handoff-write " + Quote(path)); return true; }
        catch { return false; }
    }

    // Luna writes the quick handoff from a chat's transcript (the last chat unless one is named) and saves it.
    static int HandoffWrite(string[] a)
    {
        string path = a.Length > 0 ? a[0] : LastTranscript();
        if (path == null || !File.Exists(path)) { Out("找不到对话记录\n"); return 1; }
        string marker = Path.Combine(Data, "handoff-writing");
        WriteJson(marker, Obj("at", Now()));
        Func<string, int> fail = why => { WriteJson(marker, Obj("at", Now(), "failed", 1, "why", why)); try { Out("交接没写成（" + why + "）\n"); } catch { } return 1; };
        Transcript t = ReadTranscript(path, true);
        if (t.Msgs.Count == 0) return fail("对话记录里没有消息");
        ModelInfo info = GetModelInfo(MODEL);
        double room = 0.75 * (info != null && info.Window > 0 ? info.Window : 272000);
        string text = CompactTranscript(t.Msgs, 2000, 20000);
        if (EstTokens(text) > room) text = CompactTranscript(t.Msgs, 300, 4000);
        // Still too long: the start of the chat (after its first message) goes first.
        var msgs = new List<KeyValuePair<string, string>>(t.Msgs);
        while (EstTokens(text) > room && msgs.Count > COMPACT_TAIL + 2)
        {
            msgs.RemoveRange(1, Math.Max(1, msgs.Count / 10));
            var shown = new List<KeyValuePair<string, string>>(msgs);
            shown.Insert(1, new KeyValuePair<string, string>("user", "[… an earlier part of the chat is left out …]"));
            text = CompactTranscript(shown, 300, 4000);
        }
        failed = "";
        Answer[] answers = AskCodex(new[] { new Job { System = "You read a conversation between a user and Codex, an AI coding agent, and write the handoff the user asks for.",
            Ask = text + "\n\n---\n" + HANDOFF_PROMPT, Effort = "medium" } }, 150);
        string got = answers[0] == null ? "" : (answers[0].Text ?? "").Trim();
        got = Regex.Replace(got, @"^\[effortless-judge\]\s*", "");
        if (got.Length < 100) return fail(failed == "no-codex" || failed == "spawn" ? "找不到 codex" : "没有及时写完");
        WriteText(Path.Combine(Data, "handoff.md"), got + "\n");
        try { File.Delete(marker); } catch { }
        if (HANDOFF_AFTER == "copy") CopyText(got);
        try { Out("交接已由 " + MODEL + " 写好并保存（" + Path.Combine(Data, "handoff.md") + "）。输入 /new 开新对话，然后发送 $effortless resume。\n"); } catch { }
        return 0;
    }

    static bool CopyText(string text)
    {
        try
        {
            // clip.exe takes UTF-16 with a byte-order mark as Unicode.
            var p = Process.Start(new ProcessStartInfo("clip.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true });
            byte[] b = new UnicodeEncoding(false, true).GetPreamble().Concat(Encoding.Unicode.GetBytes(text)).ToArray();
            p.StandardInput.BaseStream.Write(b, 0, b.Length);
            p.StandardInput.Close();
            p.WaitForExit(5000);
            return true;
        }
        catch { return false; }
    }

    static int Bench()
    {
        string file = Path.Combine(Here, @"bench\judge-cases.json");
        var j = ReadJson(file);
        if (j == null) { Out("找不到 bench\\judge-cases.json\n"); return 1; }
        // Cases about effort relative to Claude models do not carry over to Codex models.
        var cases = Arr(Get(j, "cases")).Where(c => Str(Get(c, "kind")) != "model-relative").ToArray();
        Out(string.Format(Inv, "{0} 个用例，判断器：{1}。每个约几秒，请稍候…\n", cases.Length, JevKey() != null ? "Jev + Luna" : "Luna"));
        var answers = new Decision[cases.Length];
        int next = -1;
        var workers = Enumerable.Range(0, 4).Select(w => new Thread(() =>
        {
            int i;
            while ((i = Interlocked.Increment(ref next)) < cases.Length)
            {
                object c = cases[i];
                string ctx = Str(Get(c, "context")) ?? "";
                Match u = Regex.Match(ctx, "(?m)^user: (.*)$"), a = Regex.Match(ctx, @"assistant: (.*)\z", RegexOptions.Singleline);
                answers[i] = Decide(Str(Get(c, "message")), Str(Get(c, "current", "effort")), u.Success ? u.Groups[1].Value : null, a.Success ? a.Groups[1].Value : null, 0, null, null, null, false);
            }
        })).ToList();
        workers.ForEach(w => w.Start());
        workers.ForEach(w => w.Join());
        var grades = new Dictionary<string, Dictionary<string, int>> { { "all", new Dictionary<string, int>() }, { "tuned", new Dictionary<string, int>() }, { "held", new Dictionary<string, int>() } };
        var miss = new List<string>();
        var ms = new List<long>();
        for (int i = 0; i < cases.Length; i++)
        {
            object c = cases[i];
            Decision a = answers[i];
            string e = a == null || a.Action == "fail" ? null : (a.Raw ?? a.Effort);
            var ok = Arr(Get(c, "ok")).Select(Str).ToList();
            string g = e == null ? "none" : ok.Contains(e) ? "hit" : Rank(e) < ok.Min(o => Rank(o)) ? "under" : "over";
            foreach (string set in new[] { "all", Get(c, "holdout") is bool && (bool)Get(c, "holdout") ? "held" : "tuned" })
                grades[set][g] = (grades[set].ContainsKey(g) ? grades[set][g] : 0) + 1;
            if (a != null && a.Ms > 0) ms.Add(a.Ms);
            if (g != "hit") miss.Add("- " + Str(Get(c, "id")) + "：答 " + (e ?? "无") + "，应为 " + string.Join("/", ok) + "：\"" + Cut(Str(Get(c, "message")), 50) + "\"");
        }
        Func<Dictionary<string, int>, string> pct = h => { int n = h.Values.Sum(); return n > 0 ? string.Format(Inv, "{0}%（{1}）", (int)(100.0 * (h.ContainsKey("hit") ? h["hit"] : 0) / n + 0.5), n) : "-"; };
        Func<string, int> cnt = k => grades["all"].ContainsKey(k) ? grades["all"][k] : 0;
        ms.Sort();
        Out(string.Format(Inv, "答对：全部 {0}，调优用 {1}，留出 {2}\n偏低 {3}，偏高 {4}，无回答 {5}，中位耗时 {6:0.0} 秒\n", pct(grades["all"]), pct(grades["tuned"]), pct(grades["held"]),
            cnt("under"), cnt("over"), cnt("none"), ms.Count > 0 ? ms[ms.Count / 2] / 1000.0 : 0));
        if (miss.Count > 0) Out("未答对：\n" + string.Join("\n", miss) + "\n");
        return 0;
    }

    static int Update()
    {
        string src = (ReadText(Path.Combine(Here, "source")) ?? "").Trim();
        if (src == "" || !Directory.Exists(Path.Combine(src, ".git"))) { Out("不知道从哪里安装的（" + Path.Combine(Here, "source") + "）\n"); return 1; }
        if (Run("git", "-C \"" + src + "\" pull --ff-only") == null) { Out("git pull 失败\n"); return 1; }
        // The installer rebuilds effortless.exe, which this process holds: it runs on its own, after this exits.
        Process.Start(new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(src, "install.ps1") + "\" -Quiet") { UseShellExecute = true, WindowStyle = ProcessWindowStyle.Hidden });
        Out("已拉取新版本，正在后台重新安装。几秒后生效；Codex Desktop 的 Auto 需要重启 Desktop。\n");
        return 0;
    }

    // Auto in Codex Desktop: Desktop starts whatever CODEX_CLI_PATH names as its app-server, so it points here.
    static int DesktopCmd(string arg)
    {
        string self = Process.GetCurrentProcess().MainModule.FileName;
        string now = Environment.GetEnvironmentVariable("CODEX_CLI_PATH", EnvironmentVariableTarget.User);
        bool ours = now != null && string.Equals(now, self, StringComparison.OrdinalIgnoreCase);
        if (arg == "on")
        {
            if (now != null && !ours) { Out("CODEX_CLI_PATH 已经指向 " + now + "，没有改动。要换成 effortless，先删掉它，或把 EFFORTLESS_CODEX 设成它。\n"); return 1; }
            if (DesktopCodex() == null && FindCodex() == null) { Out("找不到 Codex Desktop 或 codex.exe。\n"); return 1; }
            Environment.SetEnvironmentVariable("CODEX_CLI_PATH", self, EnvironmentVariableTarget.User);
            Out("Codex Desktop 的 Auto 已打开：重启 Codex Desktop（托盘里也退出）后生效。\n关闭：effortless desktop off。\n");
        }
        else if (arg == "off")
        {
            if (ours) Environment.SetEnvironmentVariable("CODEX_CLI_PATH", null, EnvironmentVariableTarget.User);
            Out(ours ? "Codex Desktop 的 Auto 已关闭：重启 Codex Desktop 后生效。\n" : "Codex Desktop 的 Auto 本来就没开。\n");
        }
        else Out(ours ? "Codex Desktop 的 Auto：开\n" : "Codex Desktop 的 Auto：关\n");
        return 0;
    }

    // ------------------------------------------------------------ Auto: the router both front ends share

    class ThreadState { public bool Auto = true, Active; public string Model, Effort, ClientEffort, LastUser = "", LastAssistant = ""; }
    class Held { public Dictionary<string, object> Message; public string Tid, Current, Model, File; public bool Settings, Cancelled; }

    // Sits between a client (the TUI over a WebSocket, or Codex Desktop over stdio) and the real app-server.
    // Everything passes through untouched, except a new prompt's turn/start: the judge picks the effort and the
    // router writes it into the request. Changing the effort yourself pauses Auto for that chat.
    class Router
    {
        public Action<string> ToClient, ToBackend;
        readonly object gate = new object();
        readonly Dictionary<string, ThreadState> threads = new Dictionary<string, ThreadState>();
        readonly Dictionary<string, Dictionary<string, object>> pending = new Dictionary<string, Dictionary<string, object>>();
        readonly Dictionary<string, Dictionary<string, object>> routedFor = new Dictionary<string, Dictionary<string, object>>();
        readonly Dictionary<string, ModelInfo> models = new Dictionary<string, ModelInfo>();
        readonly List<Held> judging = new List<Held>();
        readonly string discovery = "effortless-models-" + Guid.NewGuid().ToString("N");

        ThreadState State(string id) { ThreadState s; if (!threads.TryGetValue(id, out s)) threads[id] = s = new ThreadState(); return s; }
        static string IdKey(object id) { return id == null ? null : Ser(id); }

        public void FromClient(string raw)
        {
            var m = Parse(raw) as Dictionary<string, object>;
            if (m == null) { ToBackend(raw); return; }
            string method = Str(Get(m, "method")) ?? "";
            lock (gate)
            {
                if (Get(m, "id") != null && method != "") pending[IdKey(Get(m, "id"))] = m;
                if (method == "turn/interrupt")
                {
                    // Interrupted while the judge thinks: the held turn never starts.
                    string tid = Str(Get(m, "params", "threadId"));
                    foreach (Held h in judging.Where(h => h.Tid == tid && !h.Cancelled))
                    {
                        h.Cancelled = true;
                        ToClient(Ser(Obj("id", Get(h.Message, "id"), "error", Obj("code", -32000, "message", "Turn cancelled before it started"))));
                    }
                }
                if (method == "turn/start" && StartJudge(m)) return;
            }
            ToBackend(raw);
            // The models and the efforts each takes, asked once the client is set up.
            if (method == "initialized") ToBackend(Ser(Obj("id", discovery, "method", "model/list", "params", Obj())));
        }

        public void FromBackend(string raw)
        {
            var m = Parse(raw) as Dictionary<string, object>;
            if (m == null) { ToClient(raw); return; }
            bool forward = true;
            lock (gate)
            {
                object id = Get(m, "id");
                string idKey = IdKey(id);
                Dictionary<string, object> req = null;
                if (idKey != null && Get(m, "method") == null) pending.TryGetValue(idKey, out req);
                string method = req != null ? Str(Get(req, "method")) ?? "" : "";
                var result = Get(m, "result") as Dictionary<string, object>;
                bool isDiscovery = Str(id) == discovery;
                if (result != null && (method == "model/list" || isDiscovery))
                {
                    foreach (object model in Arr(Get(result, "data")))
                    {
                        var info = new ModelInfo { Default = Str(Get(model, "defaultReasoningEffort")) };
                        foreach (object e in Arr(Get(model, "supportedReasoningEfforts"))) { string r = Str(Get(e, "reasoningEffort")); if (r != null) info.Supported.Add(r); }
                        if (Get(model, "model") != null) models[Str(Get(model, "model"))] = info;
                        if (Get(model, "id") != null) models[Str(Get(model, "id"))] = info;
                    }
                }
                if (result != null && Get(result, "thread") != null && Regex.IsMatch(method, "^thread/(start|resume|fork)$"))
                {
                    ThreadState s = State(Str(Get(result, "thread", "id")));
                    s.Model = Str(Get(result, "model")) ?? Str(Get(req, "params", "model"));
                    s.Effort = Str(Get(result, "reasoningEffort")) ?? s.Effort;
                    foreach (object turn in Arr(Get(result, "thread", "turns")))
                        foreach (object item in Arr(Get(turn, "items")))
                        {
                            if (Str(Get(item, "type")) == "agentMessage") s.LastAssistant = Tail(Str(Get(item, "text")), 2400);
                            if (Str(Get(item, "type")) == "userMessage") s.LastUser = Cut(InputText(Get(item, "content")), 600);
                        }
                }
                if (result != null && method == "turn/start")
                {
                    ThreadState s = State(Str(Get(req, "params", "threadId")) ?? "");
                    Dictionary<string, object> r;
                    if (routedFor.TryGetValue(idKey, out r)) { s.Effort = Str(Get(r, "effort")); if (Get(r, "model") != null) s.Model = Str(Get(r, "model")); routedFor.Remove(idKey); }
                    else { s.Effort = Str(Get(req, "params", "effort")) ?? s.Effort; s.Model = Str(Get(req, "params", "model")) ?? s.Model; }
                    s.LastUser = Cut(InputText(Get(req, "params", "input")), 600);
                }
                string tid = Str(Get(m, "params", "threadId"));
                if (tid != null)
                {
                    ThreadState s = State(tid);
                    string n = Str(Get(m, "method")) ?? "";
                    if (n == "turn/started") s.Active = true;
                    if (n == "turn/completed") s.Active = false;
                    if (n == "item/completed" && Str(Get(m, "params", "item", "type")) == "agentMessage") s.LastAssistant = Tail(Str(Get(m, "params", "item", "text")), 2400);
                }
                if (idKey != null && Get(m, "method") == null) pending.Remove(idKey);
                forward = !isDiscovery;
            }
            if (forward) ToClient(raw);
        }

        // A new prompt: hold its turn/start while the judge decides (on its own thread, so everything else keeps flowing).
        bool StartJudge(Dictionary<string, object> m)
        {
            var prm = Get(m, "params") as Dictionary<string, object>;
            string tid = Str(Get(prm, "threadId"));
            if (tid == null) return false;
            ThreadState s = State(tid);
            object input = Get(prm, "input");
            string text = InputText(input);
            // Steering, tool continuations and delegated work are not new prompts.
            if (s.Active || judging.Any(h => h.Tid == tid) || Get(prm, "toolOutput") != null || Get(prm, "parentTurnId") != null || Get(prm, "rootTurnId") != null) return false;
            if (text.Trim() == "" && Arr(input).Length == 0) return false;
            if (MODE == "warn" || MODE == "off" || !AutoOn()) return false;
            var settings = Get(prm, "collaborationMode", "settings") as Dictionary<string, object>;
            string model = Str(Get(settings, "model")) ?? Str(Get(prm, "model")) ?? s.Model;
            string incoming = Str(Get(settings, "reasoning_effort")) ?? Str(Get(prm, "effort"));
            string ftid = SafeId(tid);
            string pausedFile = Path.Combine(Data, "routed", ftid + ".paused");
            string routedFile = Path.Combine(Data, "routed", ftid);
            // The effort changed by hand since the last prompt (and not to what Auto set): you win, Auto pauses for this chat.
            bool manual = incoming != null && s.ClientEffort != null && incoming != s.ClientEffort && incoming != s.Effort;
            if (incoming != null) s.ClientEffort = incoming;
            if (manual) { s.Auto = false; WriteText(pausedFile, Now().ToString(Inv)); }
            if (!s.Auto && !File.Exists(pausedFile)) s.Auto = true;
            if (!s.Auto)
            {
                WriteJson(routedFile, Obj("at", Now(), "action", "manual", "effort", incoming, "previous", incoming));
                if (incoming != null) s.Effort = incoming;
                return false;
            }
            ModelInfo info;
            if (model == null || !models.TryGetValue(model, out info) || info.Supported.Count == 0) return false;
            string current = (s.Model != null && model == s.Model ? s.Effort : null) ?? incoming ?? info.Default;
            var held = new Held { Message = m, Tid = tid, Current = current, Model = model, Settings = settings != null, File = routedFile };
            judging.Add(held);
            string lastUser = s.LastUser, lastAssistant = s.LastAssistant, attachments = InputAttachments(input);
            var supported = new List<string>(info.Supported);
            new Thread(() =>
            {
                Decision d;
                try { Session = SafeId(tid); d = Decide(text, current, lastUser, lastAssistant, 0, supported, attachments, null, false); }
                catch { d = new Decision { Action = "fail", Fail = "error" }; }
                Finish(held, d);
            }) { IsBackground = true }.Start();
            return true;
        }

        void Finish(Held h, Decision d)
        {
            string send = null;
            lock (gate)
            {
                judging.Remove(h);
                if (h.Cancelled) return;
                string effort = d.Action == "fail" ? h.Current : d.Effort;
                WriteJson(h.File, Obj("at", Now(), "effort", effort, "previous", h.Current, "why", d.Why, "by", d.By, "sure", d.Sure,
                    "action", d.Action, "down", d.Down, "ms", d.Ms, "tokens", d.Tokens));
                if (effort != null)
                {
                    var prm = (Dictionary<string, object>)h.Message["params"];
                    prm["effort"] = effort;
                    // Older clients put the effort in collaborationMode, which wins over params.effort.
                    if (h.Settings) ((Dictionary<string, object>)Get(prm, "collaborationMode", "settings"))["reasoning_effort"] = effort;
                    string idKey = IdKey(Get(h.Message, "id"));
                    if (idKey != null) routedFor[idKey] = Obj("effort", effort, "model", h.Model);
                }
                send = Ser(h.Message);
            }
            ToBackend(send);
        }
    }

    static string InputText(object input)
    {
        return string.Join("\n", Arr(input).Where(i => Str(Get(i, "type")) == "text").Select(i => Str(Get(i, "text")) ?? ""));
    }
    static string InputAttachments(object input)
    {
        var n = new SortedDictionary<string, int>();
        foreach (object i in Arr(input))
        {
            string t = Str(Get(i, "type")) ?? "";
            if (!Regex.IsMatch(t, "image|audio|mention", RegexOptions.IgnoreCase)) continue;
            string k = Regex.IsMatch(t, "image", RegexOptions.IgnoreCase) ? "image" : Regex.IsMatch(t, "audio", RegexOptions.IgnoreCase) ? "audio" : "file";
            n[k] = (n.ContainsKey(k) ? n[k] : 0) + 1;
        }
        return string.Join(", ", n.Select(kv => kv.Value + " " + kv.Key + (kv.Value > 1 ? "s" : "")));
    }

    static void ProxyLog(string s)
    {
        try { lock (Conf) File.AppendAllText(Path.Combine(Data, "proxy.log"), DateTime.Now.ToString("s", Inv) + " " + s + "\n", Utf8); } catch { }
    }

    // Starts the real app-server with redirected stdin/stdout. Its stderr stays the caller's for Desktop, which reads
    // its logs there; under the TUI it is dropped, or it would draw over the screen.
    static Process StartBackend(string exe, string args, Action<string> onLine, Action onExit, bool keepStderr)
    {
        var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = !keepStderr, StandardOutputEncoding = Utf8 };
        // Whatever the app-server starts by CODEX_CLI_PATH should be the real codex, not this program again.
        psi.EnvironmentVariables["CODEX_CLI_PATH"] = exe;
        var p = Process.Start(psi);
        if (!keepStderr) { p.ErrorDataReceived += (s, e) => { }; p.BeginErrorReadLine(); }
        new Thread(() =>
        {
            try { string l; while ((l = p.StandardOutput.ReadLine()) != null) onLine(l); } catch { }
            onExit();
        }) { IsBackground = true }.Start();
        return p;
    }

    static Action<string> LineWriter(Stream s)
    {
        object gate = new object();
        return line => { byte[] b = Utf8.GetBytes(line + "\n"); lock (gate) { try { s.Write(b, 0, b.Length); s.Flush(); } catch { } } };
    }

    // Codex Desktop: CODEX_CLI_PATH names this program, so Desktop starts `effortless.exe app-server ...` and talks
    // JSON lines over stdio. The real codex.exe runs behind the router with the same arguments.
    static int DesktopShim(string[] args)
    {
        string exe = RealCodexForShim();
        if (exe == null) { Console.Error.WriteLine("effortless: cannot find the real codex.exe (set EFFORTLESS_CODEX)"); return 1; }
        string argline = string.Join(" ", args.Select(Quote));
        bool appServer = args.Contains("app-server") && !args.Any(a => a == "daemon" || a == "proxy" || a.StartsWith("generate-"));
        if (!appServer || MODE == "off") return Passthrough(exe, argline);
        var router = new Router();
        Stream stdout = Console.OpenStandardOutput();
        router.ToClient = LineWriter(stdout);
        Process backend = null;
        var exited = new ManualResetEvent(false);
        backend = StartBackend(exe, argline, l => router.FromBackend(l), () => exited.Set(), true);
        router.ToBackend = LineWriter(backend.StandardInput.BaseStream);
        new Thread(() =>
        {
            var input = new StreamReader(Console.OpenStandardInput(), Utf8);
            try { string l; while ((l = input.ReadLine()) != null) router.FromClient(l); } catch { }
            // Desktop let go: the app-server goes too.
            try { backend.StandardInput.Close(); } catch { }
            Thread.Sleep(2000);
            KillTree(backend);
            exited.Set();
        }) { IsBackground = true }.Start();
        exited.WaitOne();
        try { backend.WaitForExit(3000); return backend.HasExited ? backend.ExitCode : 0; } catch { return 0; }
    }

    static int Passthrough(string exe, string argline)
    {
        var p = Process.Start(new ProcessStartInfo(exe, argline) { UseShellExecute = false });
        p.WaitForExit();
        return p.ExitCode;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_BASIC_INFORMATION { public IntPtr Reserved1, PebBaseAddress, Reserved2_0, Reserved2_1, UniqueProcessId, InheritedFromUniqueProcessId; }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PROCESS_BASIC_INFORMATION pbi, int len, out int ret);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    static string ParentImage()
    {
        try
        {
            var pbi = new PROCESS_BASIC_INFORMATION();
            int ret;
            if (NtQueryInformationProcess(Process.GetCurrentProcess().Handle, 0, ref pbi, Marshal.SizeOf(pbi), out ret) != 0) return null;
            IntPtr h = OpenProcess(0x1000, false, pbi.InheritedFromUniqueProcessId.ToInt32());
            if (h == IntPtr.Zero) return null;
            try { var sb = new StringBuilder(1024); int size = sb.Capacity; return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : null; }
            finally { CloseHandle(h); }
        }
        catch { return null; }
    }

    // The codex.exe Desktop would have run: the one next to the Desktop that started us, else its package's, else any.
    static string RealCodexForShim()
    {
        if (CODEX != "" && File.Exists(CODEX)) return CODEX;
        string parent = ParentImage();
        if (parent != null)
        {
            string dir = Path.GetDirectoryName(parent);
            foreach (string c in new[] { Path.Combine(dir, @"resources\codex.exe"), Path.Combine(dir, @"..\resources\codex.exe"), Path.Combine(dir, @"app\resources\codex.exe") })
                if (File.Exists(c)) return Path.GetFullPath(c);
        }
        return DesktopCodex() ?? FindCodex();
    }

    // Windows command-line quoting, the way CommandLineToArgvW reads it back.
    static string Quote(string a)
    {
        if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return a;
        var sb = new StringBuilder("\"");
        int bs = 0;
        foreach (char c in a)
        {
            if (c == '\\') { bs++; continue; }
            if (c == '"') { sb.Append('\\', bs * 2 + 1).Append('"'); bs = 0; continue; }
            sb.Append('\\', bs).Append(c); bs = 0;
        }
        sb.Append('\\', bs * 2).Append('"');
        return sb.ToString();
    }

    // The CLI: `effortless codex [args]` starts a private WebSocket the TUI connects to with --remote, and the real
    // app-server behind it. Loopback only, one client, and a random token it must present.
    static int CliAuto(string[] args)
    {
        if (args.Any(a => a.StartsWith("--remote"))) { Console.Error.WriteLine("effortless: leave --remote out; the proxy sets it"); return 2; }
        string exe = FindCodex();
        if (exe == null) { Console.Error.WriteLine("effortless: cannot find codex.exe (set EFFORTLESS_CODEX)"); return 1; }
        byte[] tok = new byte[32];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(tok);
        string token = string.Concat(tok.Select(b => b.ToString("x2")));
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        new Thread(() => ServeWs(listener, exe, token)) { IsBackground = true }.Start();
        if (args.Length > 0 && args[0] == "--serve")
        {
            // No TUI: the address and token for a client of your own (tests). Runs until stopped.
            Out("ws://127.0.0.1:" + port + " " + token + "\n");
            Thread.Sleep(Timeout.Infinite);
        }
        // Ctrl+C belongs to the TUI; this process stays until it exits.
        Console.CancelKeyPress += (s, e) => { e.Cancel = true; };
        var psi = new ProcessStartInfo(exe, "--remote ws://127.0.0.1:" + port + " --remote-auth-token-env EFFORTLESS_PROXY_TOKEN" + string.Concat(args.Select(a => " " + Quote(a)))) { UseShellExecute = false };
        psi.EnvironmentVariables["EFFORTLESS_PROXY_TOKEN"] = token;
        var tui = Process.Start(psi);
        tui.WaitForExit();
        lock (Backends) foreach (Process b in Backends) KillTree(b);
        return tui.ExitCode;
    }
    static readonly List<Process> Backends = new List<Process>();

    static void ServeWs(TcpListener listener, string exe, string token)
    {
        while (true)
        {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); } catch { return; }
            try { if (!ServeOne(client, exe, token)) client.Close(); } catch (Exception e) { ProxyLog("client: " + e.Message); try { client.Close(); } catch { } }
        }
    }

    static bool ServeOne(TcpClient client, string exe, string token)
    {
        NetworkStream ns = client.GetStream();
        // The HTTP upgrade request, up to the blank line.
        var head = new List<byte>();
        while (head.Count < 65536)
        {
            int b = ns.ReadByte();
            if (b < 0) return false;
            head.Add((byte)b);
            int n = head.Count;
            if (n >= 4 && head[n - 4] == 13 && head[n - 3] == 10 && head[n - 2] == 13 && head[n - 1] == 10) break;
        }
        string req = Encoding.ASCII.GetString(head.ToArray());
        Match key = Regex.Match(req, @"(?mi)^Sec-WebSocket-Key:\s*(\S+)");
        Match auth = Regex.Match(req, @"(?mi)^Authorization:\s*Bearer\s+(\S+)");
        // A browser page would send an Origin; anything without the token is not our TUI.
        if (!key.Success || !auth.Success || auth.Groups[1].Value != token || Regex.IsMatch(req, "(?mi)^Origin:"))
        {
            byte[] no = Encoding.ASCII.GetBytes("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
            ns.Write(no, 0, no.Length);
            return false;
        }
        string accept;
        using (var sha = SHA1.Create()) accept = Convert.ToBase64String(sha.ComputeHash(Encoding.ASCII.GetBytes(key.Groups[1].Value + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
        byte[] ok = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
        ns.Write(ok, 0, ok.Length);
        ProxyLog("client connected");
        object wgate = new object();
        Action<int, byte[]> frame = (op, payload) =>
        {
            var f = new List<byte> { (byte)(0x80 | op) };
            long n = payload.Length;
            if (n < 126) f.Add((byte)n);
            else if (n < 65536) { f.Add(126); f.Add((byte)(n >> 8)); f.Add((byte)n); }
            else { f.Add(127); for (int i = 7; i >= 0; i--) f.Add((byte)(n >> (8 * i))); }
            f.AddRange(payload);
            lock (wgate) { try { ns.Write(f.ToArray(), 0, f.Count); } catch { } }
        };
        var router = new Router();
        router.ToClient = line => frame(1, Utf8.GetBytes(line));
        Process backend = StartBackend(exe, "app-server --listen stdio://", l => router.FromBackend(l), () => { frame(8, new byte[] { 0x03, 0xF3 }); try { client.Close(); } catch { } }, false);
        lock (Backends) Backends.Add(backend);
        router.ToBackend = LineWriter(backend.StandardInput.BaseStream);
        var message = new MemoryStream();
        try
        {
            while (true)
            {
                byte[] h2 = ReadExact(ns, 2);
                if (h2 == null) break;
                int op = h2[0] & 0x0f;
                bool fin = (h2[0] & 0x80) != 0, masked = (h2[1] & 0x80) != 0;
                long len = h2[1] & 0x7f;
                if (len == 126) { byte[] l = ReadExact(ns, 2); len = (l[0] << 8) | l[1]; }
                else if (len == 127) { byte[] l = ReadExact(ns, 8); len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | l[i]; }
                byte[] mask = masked ? ReadExact(ns, 4) : null;
                byte[] payload = ReadExact(ns, (int)len);
                if (payload == null) break;
                if (mask != null) for (int i = 0; i < payload.Length; i++) payload[i] ^= mask[i % 4];
                if (op == 8) { frame(8, payload.Take(2).ToArray()); break; }
                if (op == 9) { frame(10, payload); continue; }
                if (op == 10) continue;
                message.Write(payload, 0, payload.Length);
                if (!fin) continue;
                string text = Utf8.GetString(message.ToArray());
                message.SetLength(0);
                router.FromClient(text);
            }
        }
        finally
        {
            try { backend.StandardInput.Close(); } catch { }
            KillTree(backend);
            try { client.Close(); } catch { }
        }
        return true;
    }

    static byte[] ReadExact(Stream s, int n)
    {
        byte[] b = new byte[n];
        int got = 0;
        while (got < n) { int r = s.Read(b, got, n - got); if (r <= 0) return null; got += r; }
        return b;
    }

    // ------------------------------------------------------------ main

    static int Main(string[] args)
    {
        LoadSettings();
        string cmd = args.Length > 0 ? args[0] : "hook";
        string[] rest = args.Skip(1).ToArray();
        string arg1 = rest.Length > 0 ? rest[0] : null;
        try
        {
            // Codex Desktop runs CODEX_CLI_PATH with its own arguments (app-server, and the odd other command).
            if (args.Contains("app-server") || (cmd.StartsWith("-") && cmd != "--stats")) return DesktopShim(args);
            switch (cmd)
            {
                case "hook": return Hook();
                case "stats": case "--stats": return Stats();
                case "debug": return DebugInfo();
                case "auto": return AutoCmd(arg1 ?? "toggle");
                case "save": return SaveCmd(arg1 ?? "toggle");
                case "config": return ConfigCmd(rest);
                case "test": return TestCmd(rest);
                case "handoff-save": return HandoffSave();
                case "handoff-show": case "resume": return HandoffShow();
                case "handoff-write": return HandoffWrite(rest);
                case "copy": return CopyText(new StreamReader(Console.OpenStandardInput(), Utf8).ReadToEnd()) ? 0 : 1;
                case "bench": return Bench();
                case "update": return Update();
                case "update-check": return UpdateCheck();
                case "desktop": return DesktopCmd(arg1 ?? "status");
                case "codex": return CliAuto(rest);
                case "version": Out("codex-effortless " + VERSION + "\n"); return 0;
                default:
                    // Anything else was meant for codex itself (Desktop may run its CLI for other jobs).
                    return DesktopShim(args);
            }
        }
        catch (Exception e)
        {
            if (cmd == "hook") { LogRow(null, "-", "-", 0, 0, "fail:error:" + e.GetType().Name); return 0; }
            Console.Error.WriteLine("effortless: " + e.Message);
            return 1;
        }
    }
}
