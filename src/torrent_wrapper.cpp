#include "torrent_wrapper.h"
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/entry.hpp>
#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <cstring>
#include <memory>
#include <thread>
#include <chrono>
#include <mutex>
#include <atomic>
#include <map>

struct TorrentNode {
    lt::torrent_handle handle;
    bool ready_flag;
    bool alive;              // false once torrent_remove() is called; slot is never reused
    std::string cached_path;
    int last_deadline_piece; // Track last piece we set deadlines for (avoid redundant calls)
    // Persistent read handle for the HTTP streaming proxy (torrent_read_bytes).
    // Opened once per (node,file) and reused, instead of a fresh ifstream per chunk.
    std::ifstream read_stream;
    int read_stream_file_idx = -1;
};

struct SessionContext {
    lt::session* ses;
    // STABLE-ID model: torrents are keyed by a monotonic id that is NEVER
    // reused or renumbered. torrent_remove() ERASES the entry (freeing the dead
    // node), but next_id only ever increases, so a freed id is never handed out
    // again — external id holders (players, UI) stay valid across deletes.
    std::map<int, std::shared_ptr<TorrentNode>> torrents;
    int next_id = 0;
    // Guards session add/remove against concurrent reads in torrent_read_bytes.
    std::mutex mtx;
    // Set true by torrent_destroy() BEFORE it tears the session down; get_node()
    // then refuses to hand out nodes so no new reader touches a dying ctx. This
    // is a defense-in-depth latch only — it does NOT drain readers already past
    // get_node() (see the SAFETY note above torrent_destroy). torrent_destroy is
    // currently unwired, so in practice this flag never flips.
    std::atomic<bool> closing{false};
};

// ─── Helper: snapshot a torrent node under the lock ───
// The torrents map is mutated (insert/erase) under mtx. Every reader entry
// point takes a locked snapshot of the shared_ptr here, then does all
// libtorrent handle.status()/is_valid() work OUTSIDE the lock (libtorrent's
// session/handle are internally synchronized; holding mtx across status()
// would serialize it against add/remove). Returns nullptr if the context is
// null or the id was never issued / has been erased (removed torrents thus
// read as not-alive/-1/0, exactly as a dead slot did before).
static std::shared_ptr<TorrentNode> get_node(SessionContext* ctx, int id) {
    if (!ctx) return nullptr;
    // Refuse new nodes once teardown has begun (see torrent_destroy). Cheap
    // acquire load; the real add/remove serialization is still ctx->mtx below.
    if (ctx->closing.load(std::memory_order_acquire)) return nullptr;
    std::lock_guard<std::mutex> lk(ctx->mtx);
    auto it = ctx->torrents.find(id);
    return it == ctx->torrents.end() ? nullptr : it->second;
}

// ─── Helper: Get file piece range ───
static bool get_file_piece_range(const lt::torrent_handle& h, int file_idx,
                                  int& out_first, int& out_last, int& out_total) {
    auto ti = h.torrent_file();
    if (!ti) return false;
    const lt::file_storage& files = ti->files();
    if (file_idx < 0 || file_idx >= files.num_files()) return false;

    std::int64_t file_size = files.file_size(lt::file_index_t(file_idx));
    if (file_size <= 0) return false;

    out_first = static_cast<int>(files.map_file(lt::file_index_t(file_idx), 0, 0).piece);
    out_last  = static_cast<int>(files.map_file(lt::file_index_t(file_idx), file_size - 1, 0).piece);
    out_total = out_last - out_first + 1;
    return true;
}

// ─── Helper: Apply deadline-based sliding window at a piece position ───
// This is the core qBittorrent/Popcorn Time streaming pattern.
// Instead of sequential_download, we tell libtorrent exactly WHICH pieces
// we need and WHEN, so it fetches them from the fastest available peers.
static void apply_streaming_window(lt::torrent_handle& h, int target_piece,
                                    int first_piece, int last_piece,
                                    int window_size = 40) {
    // Set graduated deadlines: piece 0 = NOW, piece 1 = 50ms, piece 2 = 100ms...
    for (int i = 0; i < window_size && (target_piece + i) <= last_piece; ++i) {
        int pc = target_piece + i;
        // Tighter deadlines for first 5 pieces (immediate need), then graduated
        int deadline = (i < 5) ? i * 10 : 50 + (i - 5) * 40;
        h.set_piece_deadline(lt::piece_index_t(pc), deadline);
        h.piece_priority(lt::piece_index_t(pc), lt::download_priority_t(7));
    }

    // Always keep FIRST 3 pieces hot (container header — MKV/MP4 need this)
    for (int i = 0; i < 3 && (first_piece + i) <= last_piece; ++i) {
        h.set_piece_deadline(lt::piece_index_t(first_piece + i), 0);
        h.piece_priority(lt::piece_index_t(first_piece + i), lt::download_priority_t(7));
    }

    // Always keep LAST 5 pieces hot (MP4 moov atom can span multiple pieces)
    for (int i = 0; i < 5 && (last_piece - i) >= first_piece; ++i) {
        h.set_piece_deadline(lt::piece_index_t(last_piece - i), 0);
        h.piece_priority(lt::piece_index_t(last_piece - i), lt::download_priority_t(7));
    }

    // De-prioritize pieces well behind the playback cursor
    // Use priority 4 (normal) instead of 1 to keep background download healthy
    int deprio_start = first_piece + 5; // Don't deprioritize the header pieces
    int deprio_end = target_piece - 20; // Keep 20 pieces behind as back-buffer
    for (int i = deprio_start; i < deprio_end && i >= first_piece; ++i) {
        h.piece_priority(lt::piece_index_t(i), lt::download_priority_t(4));
    }
}

extern "C" TorrentSession torrent_init() {
    SessionContext* ctx = new SessionContext();
    
    lt::settings_pack pack;
    pack.set_str(lt::settings_pack::user_agent, "qBittorrent/4.6.0");
    pack.set_bool(lt::settings_pack::enable_dht, true);
    pack.set_bool(lt::settings_pack::enable_lsd, true);
    pack.set_bool(lt::settings_pack::enable_upnp, true);
    pack.set_bool(lt::settings_pack::enable_natpmp, true);
    pack.set_int(lt::settings_pack::active_downloads, -1);
    pack.set_int(lt::settings_pack::active_seeds, -1);
    pack.set_int(lt::settings_pack::active_limit, -1);
    pack.set_int(lt::settings_pack::connections_limit, 800);
    
    // Streaming-optimized: aggressive peer discovery + fast connections
    pack.set_int(lt::settings_pack::request_timeout, 8);
    pack.set_int(lt::settings_pack::peer_timeout, 15);
    pack.set_int(lt::settings_pack::whole_pieces_threshold, 2);
    // Strict end-game forbids the redundant requests that rescue a piece stalled
    // on one slow peer. For bulk downloading that's the right trade; for streaming
    // a single stuck piece at the play head is the whole failure, so pay the
    // bandwidth and let other peers race it.
    pack.set_bool(lt::settings_pack::strict_end_game_mode, false);
    // A long request queue is why re-prioritization feels laggy: a new deadline
    // can't take effect until the already-queued requests drain. Keep it short so
    // the play head can actually preempt.
    pack.set_int(lt::settings_pack::request_queue_time, 1);
    pack.set_bool(lt::settings_pack::announce_to_all_tiers, true);
    pack.set_bool(lt::settings_pack::announce_to_all_trackers, true);
    
    // FAST STARTUP: more aggressive peer connections
    pack.set_int(lt::settings_pack::torrent_connect_boost, 100); // burst connections on new torrent
    pack.set_int(lt::settings_pack::connection_speed, 200);       // TCP connects per second
    pack.set_int(lt::settings_pack::max_out_request_queue, 500);  // more outstanding requests
    pack.set_int(lt::settings_pack::max_allowed_in_request_queue, 250);
    pack.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
    pack.set_int(lt::settings_pack::handshake_timeout, 5);
    
    pack.set_str(lt::settings_pack::dht_bootstrap_nodes,
        "dht.transmissionbt.com:6881,"
        "router.bittorrent.com:6881,"
        "router.utorrent.com:6881,"
        "dht.aelitis.com:6881");

    ctx->ses = new lt::session(pack);
    return ctx;
}

extern "C" int torrent_add_magnet(TorrentSession session, const char* magnet_url, const char* save_path) {
    if (!session || !magnet_url || !save_path) return -1;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    
    lt::error_code ec;
    lt::add_torrent_params atp = lt::parse_magnet_uri(magnet_url, ec);
    if (ec) {
#ifdef TORRENT_WRAPPER_DEBUG
        std::cerr << "Failed to parse magnet: " << ec.message() << std::endl;
#endif
        return -1;
    }
    
    atp.save_path = save_path;

    // Fast-Lane Metadata Injection: reuse cached .torrent if available
    std::ostringstream ss;
    ss << atp.info_hashes.get_best();
    std::string cached_path = std::string(save_path) + "/" + ss.str() + ".torrent";
    
    lt::error_code ec2;
    auto cached_ti = std::make_shared<lt::torrent_info>(cached_path, ec2);
    if (!ec2) {
        atp.ti = cached_ti;
    }

    auto node = std::make_shared<TorrentNode>();
    {
        std::lock_guard<std::mutex> lk(ctx->mtx);
        node->handle = ctx->ses->add_torrent(atp, ec);
    }
    node->cached_path = cached_path;
    node->ready_flag = false;
    node->alive = true;
    node->last_deadline_piece = -1;
    
    if (!ec && node->handle.is_valid()) {
        // DON'T use sequential_download — it conflicts with our deadline-based
        // streaming window. Deadlines tell libtorrent to fetch pieces from the
        // FASTEST peers, while sequential forces them from ORDERED peers.
        // The apply_streaming_window() function handles playback ordering.
        
        // Add popular public trackers for better peer discovery
        static const char* extra_trackers[] = {
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://open.stealth.si:80/announce",
            "udp://tracker.torrent.eu.org:451/announce",
            "udp://tracker.bittor.pw:1337/announce",
            "udp://public.popcorn-tracker.org:6969/announce",
            "udp://tracker.dler.org:6969/announce",
            "udp://exodus.desync.com:6969/announce",
            "udp://open.demonii.com:1337/announce",
        };
        int tier = 10;
        for (const char* t : extra_trackers) {
            lt::announce_entry ae(t);
            node->handle.add_tracker(ae);
            tier++;
        }
        
        // If we have cached metadata, immediately set up initial streaming window
        if (!ec2 && atp.ti) {
            node->ready_flag = true;
            // Initial deadlines will be set on first torrent_poll/ensure_streaming_buffer call
        }
    }
    
    if (ec) return -1;

    // STABLE-ID model: assign a monotonic id that is NEVER reused or
    // renumbered. torrent_remove() erases the entry, but next_id only ever
    // increases, so external id holders (players, UI) stay valid across deletes.
    std::lock_guard<std::mutex> lk(ctx->mtx);
    int id = ctx->next_id++;
    ctx->torrents[id] = node;
    return id;
}

extern "C" int torrent_add_file(TorrentSession session, const char* torrent_path, const char* save_path) {
    if (!session || !torrent_path || !save_path) return -1;
    SessionContext* ctx = static_cast<SessionContext*>(session);

    lt::error_code ec;
    lt::add_torrent_params atp;

    // Unlike a magnet, a .torrent file carries the metadata inline — parse it
    // straight into atp.ti (the same idiom the magnet path uses for its cached
    // metadata fast-lane). A parse failure means a corrupt/non-torrent file.
    lt::error_code ec_parse;
    auto ti = std::make_shared<lt::torrent_info>(torrent_path, ec_parse);
    if (ec_parse) {
#ifdef TORRENT_WRAPPER_DEBUG
        std::cerr << "Failed to parse .torrent: " << ec_parse.message() << std::endl;
#endif
        return -1;
    }
    atp.ti = ti;
    atp.save_path = save_path;

    // Same metadata cache location the magnet path uses, keyed by infohash, so a
    // later magnet add for this same torrent hits the fast-lane.
    std::ostringstream ss;
    ss << ti->info_hashes().get_best();
    std::string cached_path = std::string(save_path) + "/" + ss.str() + ".torrent";

    auto node = std::make_shared<TorrentNode>();
    {
        std::lock_guard<std::mutex> lk(ctx->mtx);
        node->handle = ctx->ses->add_torrent(atp, ec);
    }
    node->cached_path = cached_path;
    // Metadata is present from the first instant — no fetch phase to wait on.
    node->ready_flag = true;
    node->alive = true;
    node->last_deadline_piece = -1;

    if (!ec && node->handle.is_valid()) {
        // Add popular public trackers for better peer discovery (mirrors the
        // magnet path — a .torrent's own tracker list is often stale/dead).
        static const char* extra_trackers[] = {
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://open.stealth.si:80/announce",
            "udp://tracker.torrent.eu.org:451/announce",
            "udp://tracker.bittor.pw:1337/announce",
            "udp://public.popcorn-tracker.org:6969/announce",
            "udp://tracker.dler.org:6969/announce",
            "udp://exodus.desync.com:6969/announce",
            "udp://open.demonii.com:1337/announce",
        };
        for (const char* t : extra_trackers) {
            lt::announce_entry ae(t);
            node->handle.add_tracker(ae);
        }
    }

    if (ec) return -1;

    // STABLE-ID model: same monotonic, never-reused id space as torrent_add_magnet.
    std::lock_guard<std::mutex> lk(ctx->mtx);
    int id = ctx->next_id++;
    ctx->torrents[id] = node;
    return id;
}

extern "C" int torrent_count(TorrentSession session) {
    if (!session) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    std::lock_guard<std::mutex> lk(ctx->mtx);
    // Callers use this only as an UPPER BOUND for `for (i in 0..count) if
    // (torrent_is_alive(i))` loops. Return next_id so every live id (id < next_id)
    // is covered; erased/never-issued ids cheaply report not-alive via get_node's
    // map miss, so dead-id iteration is bounded work, not an unbounded leak.
    return ctx->next_id;
}

extern "C" void torrent_get_name(TorrentSession session, int torrent_id, char* out_name, int max_len) {
    if (!session || torrent_id < 0 || !out_name || max_len <= 0) return;
    out_name[0] = '\0';
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return;

    try {
        if (node->alive && node->handle.is_valid()) {
            std::string name = node->handle.status().name;
            if (name.empty()) name = "Fetching Metadata...";
            std::strncpy(out_name, name.c_str(), max_len);
            out_name[max_len - 1] = '\0';
        }
    } catch(...) {
        std::strncpy(out_name, "Error", max_len);
        out_name[max_len - 1] = '\0';
    }
}

extern "C" int torrent_get_infohash(TorrentSession session, int torrent_id, char* out, int out_len) {
    if (!session || torrent_id < 0 || !out || out_len <= 0) return -1;
    out[0] = '\0';
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return -1;

    try {
        if (!node->alive || !node->handle.is_valid()) return -1;
        // Same stringification as the .torrent cache filename in
        // torrent_add_magnet (info_hashes.get_best() → 40 lowercase hex chars).
        // Available straight from the magnet — no metadata required.
        std::ostringstream ss;
        ss << node->handle.info_hashes().get_best();
        std::string hex = ss.str();
        if (hex.empty() || static_cast<int>(hex.size()) >= out_len) return -1;
        std::strncpy(out, hex.c_str(), out_len);
        out[out_len - 1] = '\0';
        return 0;
    } catch(...) {
        return -1;
    }
}

extern "C" int torrent_poll(TorrentSession session, int torrent_id, int target_file_idx, char* out_path, int path_max_len, float* out_progress, int* out_dl_rate, int* out_seeds) {
    if (!session || torrent_id < 0) return -1;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return -1;

    try {
        if (!node->alive || !node->handle.is_valid()) return -1;

        lt::torrent_status st = node->handle.status();

        if (out_progress) *out_progress = st.progress;
        if (out_dl_rate) *out_dl_rate = st.download_rate;
        if (out_seeds) *out_seeds = st.num_seeds;

        if (!st.has_metadata) return 0;

        std::shared_ptr<const lt::torrent_info> ti = node->handle.torrent_file();
        if (!ti) return 0;
        
        // Save metadata to cache if not exists
        std::ifstream test_f(node->cached_path);
        if (!test_f.good()) {
            try {
                lt::create_torrent ct(*ti);
                lt::entry e = ct.generate();
                std::vector<char> buffer;
                lt::bencode(std::back_inserter(buffer), e);
                std::ofstream out(node->cached_path, std::ios_base::binary);
                out.write(buffer.data(), buffer.size());
            } catch(...) {}
        }
        
        lt::file_storage const& files = ti->files();
        int active_idx = target_file_idx;
        
        if (active_idx < 0) {
            std::int64_t largest_size = 0;
            for (int i = 0; i < files.num_files(); ++i) {
                if (files.file_size(lt::file_index_t(i)) > largest_size) {
                    largest_size = files.file_size(lt::file_index_t(i));
                    active_idx = i;
                }
            }
        }
        
        if (active_idx >= 0 && active_idx < files.num_files()) {
            int first_piece, last_piece, total_pieces;
            if (!get_file_piece_range(node->handle, active_idx, first_piece, last_piece, total_pieces))
                return 0;

            std::string full_path = st.save_path + "/" + files.file_path(lt::file_index_t(active_idx));

            // ── Initial streaming window: deadline-based (NOT sequential) ──
            // Also re-apply if the file changed (ready_flag was reset by file_priority set)
            if (!node->ready_flag) {
                // Set deadlines on first 40 pieces for smooth startup
                apply_streaming_window(node->handle, first_piece, first_piece, last_piece, 40);
                node->ready_flag = true;
                node->last_deadline_piece = first_piece;
            }

            if (out_path && path_max_len > 0) {
                std::strncpy(out_path, full_path.c_str(), path_max_len);
                out_path[path_max_len - 1] = '\0';
            }

            // Only need the FIRST piece to start mpv — the HTTP streaming proxy
            // handles back-pressure for subsequent pieces, so mpv won't read holes.
            bool first_piece_ready = st.pieces.get_bit(lt::piece_index_t(first_piece));
            return first_piece_ready ? 1 : 0;
        }

        return 0;
    } catch(...) {
        return -1;
    }
}

extern "C" int torrent_get_file_count(TorrentSession session, int torrent_id) {
    if (!session || torrent_id < 0) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;
    try {
        if (!node->alive || !node->handle.is_valid()) return 0;
        std::shared_ptr<const lt::torrent_info> ti = node->handle.torrent_file();
        if (!ti) return 0;
        return ti->files().num_files();
    } catch(...) { return 0; }
}

extern "C" void torrent_get_file_name(TorrentSession session, int torrent_id, int file_idx, char* out_name, int max_len) {
    if (!session || torrent_id < 0 || !out_name || max_len <= 0) return;
    out_name[0] = '\0';
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return;
    try {
        if (!node->alive || !node->handle.is_valid()) return;
        std::shared_ptr<const lt::torrent_info> ti = node->handle.torrent_file();
        if (!ti || file_idx < 0 || file_idx >= ti->files().num_files()) return;
        std::string path = ti->files().file_path(lt::file_index_t(file_idx));
        size_t last_slash = path.find_last_of("/\\");
        std::string name = (last_slash == std::string::npos) ? path : path.substr(last_slash + 1);
        std::strncpy(out_name, name.c_str(), max_len);
        out_name[max_len - 1] = '\0';
    } catch(...) {
        std::strncpy(out_name, "Error", max_len);
        out_name[max_len - 1] = '\0';
    }
}

extern "C" long long torrent_get_file_size(TorrentSession session, int torrent_id, int file_idx) {
    if (!session || torrent_id < 0) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;
    try {
        if (!node->alive || !node->handle.is_valid()) return 0;
        std::shared_ptr<const lt::torrent_info> ti = node->handle.torrent_file();
        if (!ti || file_idx < 0 || file_idx >= ti->files().num_files()) return 0;
        return ti->files().file_size(lt::file_index_t(file_idx));
    } catch(...) { return 0; }
}

extern "C" void torrent_remove(TorrentSession session, int torrent_id) {
    if (!session || torrent_id < 0) return;
    SessionContext* ctx = static_cast<SessionContext*>(session);

    try {
        // STABLE-ID model: drop the torrent from the session and ERASE its map
        // entry (freeing the dead node). Erasing a key does NOT renumber other
        // keys and next_id is never rewound, so the id is retired forever and
        // other id holders are not corrupted — a later get_node(id) simply
        // returns nullptr (reads as not-alive), same as the old dead slot.
        std::lock_guard<std::mutex> lk(ctx->mtx);
        auto it = ctx->torrents.find(torrent_id);
        if (it == ctx->torrents.end()) return;
        auto node = it->second;
        node->alive = false;
        if (node->read_stream.is_open()) node->read_stream.close();
        node->read_stream_file_idx = -1;
        if (node->handle.is_valid()) {
            ctx->ses->remove_torrent(node->handle);
        }
        ctx->torrents.erase(it);
    } catch(...) {}
}

extern "C" int torrent_is_alive(TorrentSession session, int torrent_id) {
    if (!session || torrent_id < 0) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;
    try {
        return (node->alive && node->handle.is_valid()) ? 1 : 0;
    } catch(...) {}
    return 0;
}

// SAFETY: torrent_destroy is INTENTIONALLY UNWIRED — no .zig caller invokes it.
// The session (and its background threads) is deliberately leaked at process
// exit; the OS reclaims everything, which is cheaper and race-free than an
// in-process teardown.
//
// MUST NOT be called while ANY reader / proxy thread may still touch the ctx.
// It does `delete ctx->ses` / `delete ctx`, so a concurrent torrent_read_bytes
// (or a remote streaming read) holding this ctx would dereference freed memory
// → use-after-free. The `closing` latch below (checked in get_node) stops NEW
// readers from acquiring a node, but it does NOT drain readers already past
// get_node. A genuinely safe teardown would: (1) set `closing`, (2) block until
// every in-flight reader has finished (refcount / quiescence barrier), THEN
// (3) delete. Until that drain exists, DO NOT wire this into any caller.
extern "C" void torrent_destroy(TorrentSession session) {
    if (!session) return;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    // Latch teardown so get_node() stops handing out nodes. NOTE: insufficient
    // on its own — see the SAFETY note; readers already past get_node are not
    // drained here.
    ctx->closing.store(true, std::memory_order_release);
    try {
        delete ctx->ses;
    } catch(...) {}
    delete ctx;
}

extern "C" void torrent_set_file_priority(TorrentSession session, int torrent_id, int file_idx, int priority) {
    if (!session || torrent_id < 0) return;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return;

    try {
        if (node->alive && node->handle.is_valid()) {
            node->handle.file_priority(lt::file_index_t(file_idx), lt::download_priority_t(priority));
            // When setting max priority, reset ready_flag so torrent_poll
            // re-applies the streaming deadline window for this file
            if (priority == 7) {
                node->ready_flag = false;
                node->last_deadline_piece = -1;
            }
        }
    } catch(...) {}
}

extern "C" float torrent_get_file_progress(TorrentSession session, int torrent_id, int file_idx) {
    if (!session || torrent_id < 0) return 0.0f;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0.0f;

    try {
        if (node->alive && node->handle.is_valid()) {
            std::vector<std::int64_t> progress;
            node->handle.file_progress(progress, lt::torrent_handle::piece_granularity);
            
            if (file_idx >= 0 && (size_t)file_idx < progress.size()) {
                std::shared_ptr<const lt::torrent_info> ti = node->handle.torrent_file();
                if (ti) {
                    std::int64_t total = ti->files().file_size(lt::file_index_t(file_idx));
                    if (total > 0) {
                        return (float)progress[file_idx] / (float)total;
                    }
                }
            }
        }
    } catch(...) {}
    return 0.0f;
}

extern "C" void torrent_set_download_limit(TorrentSession session, int limit_bytes_per_sec) {
    if (!session) return;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    try {
        lt::settings_pack pack;
        pack.set_int(lt::settings_pack::download_rate_limit, limit_bytes_per_sec <= 0 ? -1 : limit_bytes_per_sec);
        ctx->ses->apply_settings(pack);
    } catch(...) {}
}

extern "C" int torrent_get_piece_map(TorrentSession session, int torrent_id, char* out_map, int max_len) {
    if (!session || torrent_id < 0 || !out_map || max_len <= 0) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;

    try {
        if (node->alive && node->handle.is_valid()) {
            // status()/pieces read happens OUTSIDE ctx->mtx (get_node released it);
            // libtorrent's handle is internally synchronized.
            lt::torrent_status st = node->handle.status();
            int num_pieces = st.pieces.size();
            if (num_pieces <= 0) { out_map[0] = '\0'; return 0; }

            // Reserve one byte for the NUL terminator so the buffer stays a valid
            // C-string for any caller that treats it as one.
            int cap = max_len - 1;
            if (cap <= 0) { out_map[0] = '\0'; return 0; }

            // Emit a PROPORTIONAL map of `n_out` bytes ('1' = have, '0' = not).
            // footer.zig (the only consumer) draws a single buffered-fill bar of
            // width (count of '1') / n_out and never uses per-byte positions, so
            // what matters is the have RATIO, not where the '1's sit. We set the
            // number of '1' bytes to round(n_out * have / num_pieces). This fixes
            // the old >cap truncation (which mis-reported large torrents by mapping
            // only their first `cap` pieces) AND keeps the bar proportional while
            // downloading — an all-or-nothing per-bucket rule would under-report
            // scattered progress until whole ranges complete. For num_pieces <= cap
            // this equals have/num_pieces, identical (as a count) to the old 1:1 map.
            int n_out = num_pieces < cap ? num_pieces : cap;
            long long have = 0;
            for (int p = 0; p < num_pieces; ++p) {
                if (st.pieces.get_bit(lt::piece_index_t(p))) ++have;
            }
            int ones = (int)(((long long)n_out * have + num_pieces / 2) / num_pieces); // rounded
            if (ones > n_out) ones = n_out;
            for (int k = 0; k < n_out; ++k) out_map[k] = (k < ones) ? '1' : '0';
            out_map[n_out] = '\0';
            return n_out;
        }
    } catch(...) {}
    out_map[0] = '\0';
    return 0;
}

// ─── STREAMING ENGINE: Deadline-based sliding window ───
// Called every frame during playback. Maintains a 20-piece read-ahead window
// with graduated deadlines so libtorrent fetches from the fastest peers.
extern "C" int torrent_ensure_streaming_buffer(TorrentSession session, int torrent_id, int file_idx, double percent_pos) {
    if (!session || torrent_id < 0 || file_idx < 0) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;

    try {
        if (!node->alive || !node->handle.is_valid()) return 0;

        int first_piece, last_piece, total_pieces;
        if (!get_file_piece_range(node->handle, file_idx, first_piece, last_piece, total_pieces))
            return 0;

        int current_piece_offset = static_cast<int>((percent_pos / 100.0) * total_pieces);
        int current_piece = first_piece + std::max(0, std::min(current_piece_offset, total_pieces - 1));

        // Only update deadlines if playback moved to a new piece (avoid spamming libtorrent)
        if (current_piece != node->last_deadline_piece) {
            apply_streaming_window(node->handle, current_piece, first_piece, last_piece, 40);
            node->last_deadline_piece = current_piece;
        }

        // Check if we have the next 3 pieces — enough read-ahead so mpv doesn't stutter
        lt::torrent_status st = node->handle.status();
        bool needs_buffer = false;
        for (int i = 0; i < 3 && (current_piece + i) <= last_piece; ++i) {
            if (!st.pieces.get_bit(lt::piece_index_t(current_piece + i))) {
                needs_buffer = true;
                break;
            }
        }
        
        return needs_buffer ? 1 : 0;
    } catch (...) {}
    
    return 0;
}

// ─── SEEK PRIORITIZER: Instant piece fetching at seek target ───
// Called when user drags the seekbar. Clears old deadlines and immediately
// prioritizes pieces at the new position with deadline=0 (fetch NOW).
extern "C" void torrent_seek_prioritize(TorrentSession session, int torrent_id, int file_idx, double percent_pos) {
    if (!session || torrent_id < 0 || file_idx < 0) return;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return;

    try {
        if (!node->alive || !node->handle.is_valid()) return;

        int first_piece, last_piece, total_pieces;
        if (!get_file_piece_range(node->handle, file_idx, first_piece, last_piece, total_pieces))
            return;

        // Clear all existing deadlines — stop fetching old pieces urgently
        node->handle.clear_piece_deadlines();

        // Calculate target piece
        int target_offset = static_cast<int>((percent_pos / 100.0) * total_pieces);
        int target_piece = first_piece + std::max(0, std::min(target_offset, total_pieces - 1));

        // Aggressive window: 30 pieces with tight deadlines
        apply_streaming_window(node->handle, target_piece, first_piece, last_piece, 30);

        // Update tracking
        node->last_deadline_piece = target_piece;

    } catch (...) {}
}

// ─── TORRENT MANAGEMENT ───

extern "C" void torrent_pause(TorrentSession session, int torrent_id) {
    if (!session || torrent_id < 0) return;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return;
    try {
        if (node->alive && node->handle.is_valid()) node->handle.pause();
    } catch (...) {}
}

extern "C" void torrent_resume(TorrentSession session, int torrent_id) {
    if (!session || torrent_id < 0) return;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return;
    try {
        if (node->alive && node->handle.is_valid()) node->handle.resume();
    } catch (...) {}
}

extern "C" int torrent_is_paused(TorrentSession session, int torrent_id) {
    if (!session || torrent_id < 0) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;
    try {
        if (!node->alive || !node->handle.is_valid()) return 0;
        auto flags = node->handle.flags();
        return (flags & lt::torrent_flags::paused) ? 1 : 0;
    } catch (...) {}
    return 0;
}

extern "C" int torrent_get_num_peers(TorrentSession session, int torrent_id) {
    if (!session || torrent_id < 0) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;
    try {
        if (!node->alive || !node->handle.is_valid()) return 0;
        return node->handle.status().num_peers;
    } catch (...) {}
    return 0;
}

extern "C" int torrent_get_upload_rate(TorrentSession session, int torrent_id) {
    if (!session || torrent_id < 0) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;
    try {
        if (!node->alive || !node->handle.is_valid()) return 0;
        return node->handle.status().upload_rate;
    } catch (...) {}
    return 0;
}

extern "C" long long torrent_get_total_size(TorrentSession session, int torrent_id) {
    if (!session || torrent_id < 0) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;
    try {
        if (!node->alive || !node->handle.is_valid()) return 0;
        auto ti = node->handle.torrent_file();
        if (ti) return ti->total_size();
    } catch (...) {}
    return 0;
}

// ─── HTTP STREAMING PROXY SUPPORT ───

extern "C" int torrent_get_piece_size(TorrentSession session, int torrent_id) {
    if (!session || torrent_id < 0) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;
    try {
        if (!node->alive || !node->handle.is_valid()) return 0;
        auto ti = node->handle.torrent_file();
        if (ti) return ti->piece_length();
    } catch (...) {}
    return 0;
}

extern "C" long long torrent_get_file_offset(TorrentSession session, int torrent_id, int file_idx) {
    if (!session || torrent_id < 0 || file_idx < 0) return -1;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return -1;
    try {
        if (!node->alive || !node->handle.is_valid()) return -1;
        auto ti = node->handle.torrent_file();
        if (!ti || file_idx >= ti->files().num_files()) return -1;
        return ti->files().file_offset(lt::file_index_t(file_idx));
    } catch (...) {}
    return -1;
}

// Block-read: waits until pieces covering [offset..offset+buf_len) for the given file
// are downloaded, then reads from disk. Returns bytes read, or -1 on error.
// This provides back-pressure: the HTTP proxy stalls until data is available.
extern "C" int torrent_read_bytes(TorrentSession session, int torrent_id, int file_idx,
                                   long long offset, char* out_buf, int buf_len) {
    if (!session || torrent_id < 0 || file_idx < 0 || !out_buf || buf_len <= 0) return -1;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return -1;

    try {
        {
            std::lock_guard<std::mutex> lk(ctx->mtx);
            if (!node->alive || !node->handle.is_valid()) return -1;
        }

        auto ti = node->handle.torrent_file();
        if (!ti) return -1;

        const lt::file_storage& files = ti->files();
        if (file_idx >= files.num_files()) return -1;

        std::int64_t file_size = files.file_size(lt::file_index_t(file_idx));
        if (offset >= file_size) return 0; // EOF

        // Clamp read to file bounds
        int to_read = buf_len;
        if (offset + to_read > file_size) to_read = static_cast<int>(file_size - offset);

        // Map file offset to torrent piece indices
        int piece_size = ti->piece_length();
        if (piece_size <= 0) return -1;

        // File offset within the torrent (multi-file torrents have per-file offsets)
        auto pm_start = files.map_file(lt::file_index_t(file_idx), offset, 0);
        auto pm_end = files.map_file(lt::file_index_t(file_idx), offset + to_read - 1, 0);
        int first_piece = static_cast<int>(pm_start.piece);
        int last_piece = static_cast<int>(pm_end.piece);

        // Set high-priority deadlines on needed pieces
        for (int p = first_piece; p <= last_piece; ++p) {
            node->handle.set_piece_deadline(lt::piece_index_t(p), 0);
            node->handle.piece_priority(lt::piece_index_t(p), lt::download_priority_t(7));
        }

        // Wait for the pieces. status()/liveness are read under ctx->mtx so a
        // concurrent torrent_remove() can't tear the handle down mid-access; the
        // lock is released during the sleep so add/remove aren't starved.
        //
        // The old timeout here was 30s, after which this returned -1 and the HTTP
        // proxy simply STOPPED WRITING mid-body — having already promised a
        // Content-Length. ffmpeg cannot distinguish a read error from end-of-file
        // (demux_lavf.c collapses both to AVERROR_EOF), so mpv concluded the file
        // had ended and gave up for good. That is why downloading more never
        // rescued a stalled stream: the demuxer was already dead.
        //
        // Blocking is safe (mpv is designed to wait on a slow stream); truncating
        // is fatal. So wait as long as the torrent is alive and could still make
        // progress, and re-arm the deadline periodically — libtorrent converts a
        // deadline to an ABSOLUTE time point, so a stale one stops being urgent.
        const int POLL_MS = 25;
        const int REARM_EVERY = 2000 / POLL_MS;          // re-assert the deadline every 2s
        const int MAX_WAIT_MS = 10 * 60 * 1000;          // backstop against a truly wedged read
        const int MAX_ATTEMPTS = MAX_WAIT_MS / POLL_MS;

        bool ready = false;
        for (int attempt = 0; attempt < MAX_ATTEMPTS && !ready; ++attempt) {
            {
                std::lock_guard<std::mutex> lk(ctx->mtx);
                if (!node->alive || !node->handle.is_valid()) return -1;
                bool all_ready = true;
                for (int p = first_piece; p <= last_piece; ++p) {
                    // have_piece() instead of status().pieces: the latter allocates
                    // the whole piece bitfield, 40x/sec, per connection.
                    if (!node->handle.have_piece(lt::piece_index_t(p))) { all_ready = false; break; }
                }
                ready = all_ready;

                if (!ready && attempt > 0 && (attempt % REARM_EVERY) == 0) {
                    for (int p = first_piece; p <= last_piece; ++p) {
                        node->handle.set_piece_deadline(lt::piece_index_t(p), 0);
                    }
                }
            }
            if (!ready) std::this_thread::sleep_for(std::chrono::milliseconds(POLL_MS));
        }
        if (!ready) return -1; // wedged for 10 minutes — genuinely dead

        // Read from disk via a persistent stream kept on the node — opened once
        // per (node,file_index) and reused across chunks instead of reopening
        // an ifstream on every 512KB request.
        {
            std::lock_guard<std::mutex> lk(ctx->mtx);
            if (!node->alive || !node->handle.is_valid()) return -1;

            if (!node->read_stream.is_open() || node->read_stream_file_idx != file_idx) {
                if (node->read_stream.is_open()) node->read_stream.close();
                lt::torrent_status st = node->handle.status();
                std::string full_path = st.save_path + "/" + files.file_path(lt::file_index_t(file_idx));
                node->read_stream.clear();
                node->read_stream.open(full_path, std::ios::binary);
                if (!node->read_stream.is_open()) return -1;
                node->read_stream_file_idx = file_idx;
            }

            node->read_stream.clear(); // clear any prior EOF/fail bits before seeking
            node->read_stream.seekg(offset, std::ios::beg);
            node->read_stream.read(out_buf, to_read);
            return static_cast<int>(node->read_stream.gcount());
        }

    } catch (...) {}
    return -1;
}


// ══════════════════════════════════════════════════════════
// Byte-range streaming primitives
//
// These exist because the readiness gate has to reason in BYTES. A container's
// index sits at a byte offset (MKV Cues, MP4 moov), and a piece count is the
// wrong unit for it: "the last 5 pieces" is 5 MB on a 1 MB-piece torrent and
// 80 MB on a 16 MB-piece one.
// ══════════════════════════════════════════════════════════

// Map a byte range within a file to the inclusive piece range covering it.
// Returns false when the range is empty / out of bounds / metadata is missing.
static bool map_range_to_pieces(const std::shared_ptr<TorrentNode>& node, int file_idx,
                                long long offset, long long len,
                                int& first_piece, int& last_piece) {
    if (!node || !node->handle.is_valid() || file_idx < 0 || len <= 0 || offset < 0) return false;
    auto ti = node->handle.torrent_file();
    if (!ti) return false;

    const lt::file_storage& files = ti->files();
    if (file_idx >= files.num_files()) return false;

    std::int64_t file_size = files.file_size(lt::file_index_t(file_idx));
    if (file_size <= 0 || offset >= file_size) return false;

    long long end = offset + len;
    if (end > file_size) end = file_size;

    first_piece = static_cast<int>(files.map_file(lt::file_index_t(file_idx), offset, 0).piece);
    last_piece  = static_cast<int>(files.map_file(lt::file_index_t(file_idx), end - 1, 0).piece);
    return last_piece >= first_piece;
}

extern "C" int torrent_range_ready(TorrentSession session, int torrent_id, int file_idx,
                                   long long offset, long long len) {
    if (!session) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;

    try {
        std::lock_guard<std::mutex> lk(ctx->mtx);
        if (!node->alive || !node->handle.is_valid()) return 0;

        int first_piece = 0, last_piece = 0;
        if (!map_range_to_pieces(node, file_idx, offset, len, first_piece, last_piece)) return 0;

        for (int p = first_piece; p <= last_piece; ++p) {
            if (!node->handle.have_piece(lt::piece_index_t(p))) return 0;
        }
        return 1;
    } catch (...) {}
    return 0;
}

extern "C" int torrent_range_progress(TorrentSession session, int torrent_id, int file_idx,
                                      long long offset, long long len) {
    if (!session) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return 0;

    try {
        std::lock_guard<std::mutex> lk(ctx->mtx);
        if (!node->alive || !node->handle.is_valid()) return 0;

        int first_piece = 0, last_piece = 0;
        if (!map_range_to_pieces(node, file_idx, offset, len, first_piece, last_piece)) return 0;

        int total = last_piece - first_piece + 1;
        if (total <= 0) return 0;
        int have = 0;
        for (int p = first_piece; p <= last_piece; ++p) {
            if (node->handle.have_piece(lt::piece_index_t(p))) ++have;
        }
        return static_cast<int>((static_cast<long long>(have) * 100) / total);
    } catch (...) {}
    return 0;
}

extern "C" void torrent_prioritize_range(TorrentSession session, int torrent_id, int file_idx,
                                         long long offset, long long len, int deadline_ms) {
    if (!session) return;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    auto node = get_node(ctx, torrent_id);
    if (!node) return;

    try {
        std::lock_guard<std::mutex> lk(ctx->mtx);
        if (!node->alive || !node->handle.is_valid()) return;

        int first_piece = 0, last_piece = 0;
        if (!map_range_to_pieces(node, file_idx, offset, len, first_piece, last_piece)) return;

        // Priorities FIRST, then deadlines. libtorrent's prioritize_pieces() calls
        // remove_time_critical_pieces(), so setting a priority AFTER a deadline
        // silently drops that deadline. (Setting a deadline already forces the
        // piece to top priority, so the explicit call is belt-and-braces for the
        // case where the piece was previously priority 0.)
        std::vector<std::pair<lt::piece_index_t, lt::download_priority_t>> prios;
        prios.reserve(static_cast<size_t>(last_piece - first_piece + 1));
        for (int p = first_piece; p <= last_piece; ++p) {
            prios.emplace_back(lt::piece_index_t(p), lt::download_priority_t(7));
        }
        node->handle.prioritize_pieces(prios);

        // Then the deadlines, in ONE turn: the first deadline cancels outstanding
        // non-critical requests, so dripping these in from separate calls would
        // thrash the request pipeline.
        const int dl = deadline_ms < 0 ? 0 : deadline_ms;
        for (int p = first_piece; p <= last_piece; ++p) {
            node->handle.set_piece_deadline(lt::piece_index_t(p), dl);
        }
    } catch (...) {}
}
