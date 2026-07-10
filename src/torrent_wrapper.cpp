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
    std::vector<std::shared_ptr<TorrentNode>> torrents;
    // Guards session add/remove against concurrent reads in torrent_read_bytes.
    std::mutex mtx;
};

// ─── Helper: snapshot a torrent node under the lock ───
// torrent_add_magnet() does ctx->torrents.push_back() under mtx, which can
// REALLOCATE the vector and move every shared_ptr. Every reader entry point
// therefore takes a locked snapshot of the shared_ptr here, then does all
// libtorrent handle.status()/is_valid() work OUTSIDE the lock (libtorrent's
// session/handle are internally synchronized; holding mtx across status()
// would serialize it against add/remove). Returns nullptr if the context is
// null or the id is out of range.
static std::shared_ptr<TorrentNode> get_node(SessionContext* ctx, int id) {
    if (!ctx) return nullptr;
    std::lock_guard<std::mutex> lk(ctx->mtx);
    if (id < 0 || (size_t)id >= ctx->torrents.size()) return nullptr;
    return ctx->torrents[id];
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
    pack.set_bool(lt::settings_pack::strict_end_game_mode, true);
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

    // STABLE-SLOT model: ids are vector indices that are NEVER reused or
    // renumbered. torrent_remove() marks a slot dead but keeps it in place,
    // so external id holders (players, UI) stay valid across deletes.
    std::lock_guard<std::mutex> lk(ctx->mtx);
    ctx->torrents.push_back(node);
    return static_cast<int>(ctx->torrents.size()) - 1;
}

extern "C" int torrent_count(TorrentSession session) {
    if (!session) return 0;
    SessionContext* ctx = static_cast<SessionContext*>(session);
    std::lock_guard<std::mutex> lk(ctx->mtx);
    return static_cast<int>(ctx->torrents.size());
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
            bool first_piece_ready = st.pieces.get_bit(first_piece);
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
    if ((size_t)torrent_id >= ctx->torrents.size()) return;

    try {
        // STABLE-SLOT model: mark the slot dead and drop it from the session,
        // but NEVER erase or renumber the vector. The id remains valid (and dead)
        // forever, so other id holders are not corrupted.
        std::lock_guard<std::mutex> lk(ctx->mtx);
        auto node = ctx->torrents[torrent_id];
        node->alive = false;
        if (node->read_stream.is_open()) node->read_stream.close();
        node->read_stream_file_idx = -1;
        if (node->handle.is_valid()) {
            ctx->ses->remove_torrent(node->handle);
        }
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

extern "C" void torrent_destroy(TorrentSession session) {
    if (!session) return;
    SessionContext* ctx = static_cast<SessionContext*>(session);
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
            lt::torrent_status st = node->handle.status();
            int num_pieces = st.pieces.size();
            int copy_len = num_pieces > max_len - 1 ? max_len - 1 : num_pieces;
            
            for (int i = 0; i < copy_len; ++i) {
                out_map[i] = st.pieces.get_bit(i) ? '1' : '0';
            }
            out_map[copy_len] = '\0';
            return copy_len;
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
            if (!st.pieces.get_bit(current_piece + i)) {
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

        // Wait for all pieces to arrive (poll at 25ms intervals, timeout after 30s).
        // status() and liveness are read under ctx->mtx so a concurrent
        // torrent_remove() can't tear the handle down mid-access; the lock is
        // released during the sleep so add/remove are not starved.
        bool ready = false;
        for (int attempt = 0; attempt < 1200 && !ready; ++attempt) {
            {
                std::lock_guard<std::mutex> lk(ctx->mtx);
                if (!node->alive || !node->handle.is_valid()) return -1;
                lt::torrent_status st = node->handle.status();
                bool all_ready = true;
                for (int p = first_piece; p <= last_piece; ++p) {
                    if (!st.pieces.get_bit(p)) { all_ready = false; break; }
                }
                ready = all_ready;
            }
            if (!ready) std::this_thread::sleep_for(std::chrono::milliseconds(25));
        }
        if (!ready) return -1; // Timeout — pieces not available

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

