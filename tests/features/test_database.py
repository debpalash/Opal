"""Auto-split from tests/test_features.py — Database / Config / Memory / Recall tests.
Byte-for-byte identical test bodies; see tests/features/harness.py for the
shared @test decorator, helpers, and run_all()."""
from .harness import *  # noqa: F401,F403
import os, sys, subprocess, sqlite3, socket, time, json  # noqa: F401

@test("Database Exists", "Database")
def test_db_exists():
    if os.path.exists(DB_PATH):
        size = os.path.getsize(DB_PATH)
        return "pass", f"Size: {size/1024:.1f} KB"
    # The db is created on first app launch — absent on fresh machines/CI.
    return "skip", "opal.db not found (app never launched here)"


@test("Config Table", "Database")
def test_config_table():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM config")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} config entries"


@test("Watch History Table", "Database")
def test_watch_history():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM watch_history")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} watch entries"


@test("Search History Table", "Database")
def test_search_history():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM search_history")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} searches"


@test("Download History Table", "Database")
def test_download_history():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM download_history")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} downloads"


@test("TMDB Items Table", "Database")
def test_tmdb_items():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM tmdb_items")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} TMDB items"


@test("AI Memory Table", "Database")
def test_aimemory():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM aimemory")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} memories"


@test("Vector Memory Table", "Database")
def test_vec_aimemory():
    db = get_db()
    if not db: return "skip", "No DB"
    try:
        cur = db.execute("SELECT COUNT(*) FROM vec_aimemory")
        count = cur.fetchone()[0]
        db.close()
        return "pass", f"{count} vectors"
    except:
        db.close()
        return "warn", "sqlite-vec extension not loaded (expected outside app)"


@test("Poster Cache Table", "Database")
def test_poster_cache():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM poster_cache")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} cached posters"


@test("Conversation Log Table", "Memory")
def test_conversation_log():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM conversation_log")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} logged conversations"


@test("User Preferences Table", "Memory")
def test_user_preferences():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT key, value, weight FROM user_preferences ORDER BY weight DESC LIMIT 5")
    rows = cur.fetchall()
    db.close()
    if rows:
        detail = "; ".join(f"{k}={v} (w:{w:.0f})" for k, v, w in rows)
        return "pass", detail
    return "pass", "No preferences learned yet"


@test("Watch Sessions Table", "Memory")
def test_watch_sessions():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT COUNT(*) FROM watch_sessions")
    count = cur.fetchone()[0]
    db.close()
    return "pass", f"{count} sessions"


@test("Proactive Suggestion Query", "Memory")
def test_proactive_suggestion():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute(
        "SELECT name, percent, position_secs FROM watch_history "
        "WHERE percent > 0.1 AND percent < 0.9 ORDER BY updated_at DESC LIMIT 1"
    )
    row = cur.fetchone()
    db.close()
    if row:
        name = row[0].split("/")[-1] if "/" in row[0] else row[0]
        return "pass", f'"{name[:50]}" at {row[1]*100:.0f}%'
    return "warn", "No unfinished content to suggest"


@test("Theme Persistence", "Config")
def test_theme_persistence():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT value FROM config WHERE key = 'theme_preset'")
    row = cur.fetchone()
    db.close()
    if row:
        return "pass", f"Theme: {row[0]}"
    return "warn", "No theme saved yet"


@test("UI Scale Config", "Config")
def test_ui_scale():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT value FROM config WHERE key = 'ui_scale'")
    row = cur.fetchone()
    db.close()
    if row:
        return "pass", f"Scale: {row[0]}x"
    return "warn", "Not set"


@test("TTS Voice Config", "Config")
def test_tts_voice():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT value FROM config WHERE key = 'tts_voice'")
    row = cur.fetchone()
    db.close()
    if row and row[0]:
        return "pass", f"Voice: {row[0]}"
    return "warn", "Default (Bella)"


@test("TTS Speed Config", "Config")
def test_tts_speed():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT value FROM config WHERE key = 'tts_speed'")
    row = cur.fetchone()
    db.close()
    if row and row[0]:
        return "pass", f"Speed: {row[0]}x"
    return "warn", "Default (1.0)"


@test("Window State Persistence", "Config")
def test_window_state():
    db = get_db()
    if not db: return "skip", "No DB"
    keys = ['win_x', 'win_y', 'win_w', 'win_h']
    vals = {}
    for k in keys:
        cur = db.execute("SELECT value FROM config WHERE key = ?", (k,))
        row = cur.fetchone()
        if row: vals[k] = row[0]
    db.close()
    if len(vals) == 4:
        return "pass", f"{vals['win_w']}x{vals['win_h']} at ({vals['win_x']},{vals['win_y']})"
    return "warn", f"Only {len(vals)}/4 window values saved"


@test("Jellyfin Integration Config", "Config")
def test_jellyfin_config():
    db = get_db()
    if not db: return "skip", "No DB"
    cur = db.execute("SELECT value FROM config WHERE key = 'jf_server_url'")
    row = cur.fetchone()
    db.close()
    if row and row[0]:
        return "pass", f"Server: {row[0][:30]}"
    return "skip", "Not configured"


@test("Poster cache SQL matches schema", "Database")
def test_poster_cache_sql():
    # core/poster.zig now reads/writes the poster_cache table from its fetch
    # workers. Execute the exact SQL strings shipped in poster.zig against the
    # CREATE TABLE from db.zig in a scratch sqlite — catches column renames or
    # SQL typos that would silently no-op the disk cache (db helpers swallow
    # prepare errors).
    import re
    poster_src = open(os.path.join(PROJECT_DIR, "src/core/poster.zig")).read()
    db_src = open(os.path.join(PROJECT_DIR, "src/core/db.zig")).read()

    # Reassemble the Zig multiline string (`\\`-prefixed lines) for the table.
    lines = db_src.splitlines()
    start = next((i for i, l in enumerate(lines)
                  if "CREATE TABLE IF NOT EXISTS poster_cache" in l), None)
    if start is None:
        return "fail", "poster_cache CREATE TABLE not found in db.zig"
    sql_lines = []
    for l in lines[start:]:
        stripped = l.strip().lstrip("\\")
        sql_lines.append(stripped)
        if stripped == ")":
            break
    create_sql = "\n".join(sql_lines)

    stmts = re.findall(r'"((?:INSERT|SELECT|DELETE)[^"]+poster_cache[^"]*)"', poster_src)
    if len(stmts) < 3:
        return "fail", f"expected >=3 poster_cache statements in poster.zig, found {len(stmts)}"

    conn = sqlite3.connect(":memory:")
    conn.execute(create_sql)
    for sql in stmts:
        n_params = len(set(re.findall(r"\?\d+", sql)))
        params = tuple(b"x" if i == 1 else 1 for i in range(n_params))
        conn.execute(sql, params)
    conn.close()
    return "pass", f"{len(stmts)} statements OK against schema"


@test("Chat session SQL matches schema", "Memory")
def test_chat_sessions_sql():
    # The Claude-style history sidebar groups conversation_log rows by
    # session_id (ai_chat.loadSessions/loadSession; ai_memory writes the tag).
    # Execute the shipped SQL against the real schema in a scratch sqlite.
    import re
    chat_src = open(os.path.join(PROJECT_DIR, "src/services/ai_chat.zig")).read()
    mem_src = open(os.path.join(PROJECT_DIR, "src/services/ai_memory.zig")).read()
    db_src = open(os.path.join(PROJECT_DIR, "src/core/db.zig")).read()

    lines = db_src.splitlines()
    start = next((i for i, l in enumerate(lines)
                  if "CREATE TABLE IF NOT EXISTS conversation_log" in l), None)
    if start is None:
        return "fail", "conversation_log CREATE TABLE not found"
    sql_lines = []
    for l in lines[start:]:
        stripped = l.strip().lstrip("\\")
        sql_lines.append(stripped)
        if stripped == ")":
            break
    conn = sqlite3.connect(":memory:")
    conn.execute("\n".join(sql_lines))

    # Multiline sidebar SELECT (Zig \\-string containing the GROUP BY).
    m = re.search(r"const sql =\n((?:\s*\\\\.*\n)+)\s*;", chat_src)
    if not m or "GROUP BY c1.session_id" not in m.group(1):
        return "fail", "loadSessions SQL not found in ai_chat.zig"
    sidebar_sql = "\n".join(l.strip().lstrip("\\") for l in m.group(1).splitlines())
    conn.execute(sidebar_sql)

    # Single-line statements: session restore + the tagged INSERT.
    for src, needle in ((chat_src, "SELECT role, content FROM conversation_log WHERE session_id"),
                        (mem_src, "INSERT INTO conversation_log(role, content, session_id)")):
        stmt = next((s for s in re.findall(r'"([^"\n]+)"', src) if needle in s), None)
        if stmt is None:
            return "fail", f"missing statement: {needle[:50]}"
        n_params = len(set(re.findall(r"\?\d+", stmt)))
        conn.execute(stmt, tuple("x" for _ in range(n_params)))
    conn.close()
    return "pass", "sidebar SELECT + restore + tagged INSERT OK against schema"


@test("Total Recall Wired", "Recall")
def test_total_recall():
    sm = _src("src/services/scene_memory.zig")
    cw = _src("src/services/co_watch.zig")
    db = _src("src/core/db.zig")
    tools = _src("src/services/ai_tools.zig")
    ctx = _src("src/services/ai_context.zig")
    if ("pub fn ingestScene" in sm and "ingestScene" in cw
            and "insertSceneMemory" in db and "retrieveScene" in db and "position_secs" in db
            and "recall_scene" in tools and "executeRecallScene" in tools and "recall_scene" in ctx):
        return "pass", "scene capture + recall_scene tool + DB store wired"
    return "fail", "total recall not fully wired"


@test("aimemory position_secs Column", "Recall")
def test_aimemory_position_col():
    db = get_db()
    if not db: return "skip", "No DB"
    cols = [r[1] for r in db.execute("PRAGMA table_info(aimemory)").fetchall()]
    db.close()
    if "position_secs" in cols:
        return "pass", "position_secs migration applied"
    return "warn", "position_secs not present yet (runs on first launch)"


@test("Taste Receipts Wired", "Recall")
def test_taste_receipts():
    tv = _src("src/services/taste_vector.zig")
    db = _src("src/core/db.zig")
    recs = _src("src/services/recommendations.zig")
    dui = _src("src/ui/discovery_ui.zig")
    home = _src("src/ui/home.zig")
    shell = _src("src/ui/shell.zig")
    srch = _src("src/services/search.zig")
    if ("pub fn computeTaste" in tv and "seedTitlesByTaste" in db and "getEmbeddingBlob" in db
            and "computeTaste" in recs and "renderForYouRail" in dui and "renderForYouRail" in home
            and "pub fn memorySearch" in srch and "memorySearch" in shell):
        return "pass", "taste vector + For-You rail + ?-memory-search wired"
    return "fail", "taste receipts not fully wired"


@test("Exact resume: schema v2 + path keying", "Database")
def test_exact_resume_schema_v2():
    # Replays the shipped v1→v2 migration (player/watch_history.zig
    # migrateSchema) against a scratch sqlite seeded with the LEGACY schema:
    # existing percent-keyed rows must survive, gain position_secs /
    # duration_secs / file_key, get local paths backfilled into file_key, and
    # the DB must be stamped user_version=2. Also pins the wiring: the pure
    # module is registered in build.zig and the resume UIs reuse the tested
    # yt_pure.formatDuration (no hand-rolled zero-padded-signed formatter).
    import re
    wh_src = open(os.path.join(PROJECT_DIR, "src/player/watch_history.zig")).read()

    m = re.search(r"pub fn migrateSchema\(\) void \{(.*?)\n\}", wh_src, re.S)
    if not m:
        return "fail", "migrateSchema() not found in watch_history.zig"
    stmts = re.findall(r'db\.exec\("([^"]+)"\)', m.group(1))
    if not any("position_secs" in s for s in stmts): return "fail", "migration lacks position_secs"
    if not any("duration_secs" in s for s in stmts): return "fail", "migration lacks duration_secs"
    if not any("file_key" in s for s in stmts): return "fail", "migration lacks file_key"
    if not any("user_version" in s for s in stmts): return "fail", "migration not stamped via user_version"

    conn = sqlite3.connect(":memory:")
    # Legacy v1 schema — pre-seconds, pre-file_key.
    conn.execute("CREATE TABLE watch_history (name TEXT PRIMARY KEY, percent REAL DEFAULT 0, "
                 "link TEXT DEFAULT '', updated_at INTEGER DEFAULT (strftime('%s','now')))")
    conn.execute("INSERT INTO watch_history (name, percent, link) VALUES ('/Users/x/Movies/Foo.mkv', 42.0, '')")
    conn.execute("INSERT INTO watch_history (name, percent, link) VALUES ('file:///Users/x/Bar.mkv', 10.0, '')")
    conn.execute("INSERT INTO watch_history (name, percent, link) VALUES ('Some.Torrent.1080p', 55.0, 'magnet:?xt=abc')")
    for s in stmts:
        conn.execute(s)  # shipped statements must run verbatim on a v1 DB
    cols = [r[1] for r in conn.execute("PRAGMA table_info(watch_history)")]
    for col in ("position_secs", "duration_secs", "file_key"):
        if col not in cols:
            return "fail", f"column {col} missing after migration"
    rows = dict(conn.execute("SELECT name, file_key FROM watch_history"))
    if rows["/Users/x/Movies/Foo.mkv"] != "/Users/x/Movies/Foo.mkv":
        return "fail", "absolute-path row not backfilled into file_key"
    if rows["file:///Users/x/Bar.mkv"] != "/Users/x/Bar.mkv":
        return "fail", "file:// row not stripped into file_key"
    if rows["Some.Torrent.1080p"] != "":
        return "fail", "torrent row must keep the legacy name key (empty file_key)"
    if conn.execute("SELECT COUNT(*) FROM watch_history").fetchone()[0] != 3:
        return "fail", "migration lost rows"
    if conn.execute("PRAGMA user_version").fetchone()[0] != 2:
        return "fail", "user_version not stamped to 2"
    conn.close()

    # Wiring: pure module registered + routed; resume UIs reuse formatDuration.
    build_src = open(os.path.join(PROJECT_DIR, "build.zig")).read()
    if "src/player/watch_history_pure.zig" not in build_src:
        return "fail", "watch_history_pure.zig not registered in build.zig test step"
    if "watch_history_pure.zig" not in wh_src:
        return "fail", "watch_history.zig not routed through watch_history_pure"
    footer_src = open(os.path.join(PROJECT_DIR, "src/ui/footer.zig")).read()
    if "formatDuration" not in footer_src:
        return "fail", "resume prompt (footer.zig) does not use yt_pure.formatDuration"
    player_src = open(os.path.join(PROJECT_DIR, "src/player/player.zig")).read()
    if "formatDuration" not in player_src or "savePositionFull" not in player_src:
        return "fail", "player.zig missing formatDuration toast or savePositionFull save"
    hist_src = open(os.path.join(PROJECT_DIR, "src/services/history.zig")).read()
    if "resolveFileKey" not in hist_src or "pickPosition" not in hist_src:
        return "fail", "history.zig missing path keying / legacy fallback routing"
    return "pass", "v1→v2 migration + path keying + formatDuration wiring OK"
