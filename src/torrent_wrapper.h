#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef void* TorrentSession;

// Initialize a libtorrent session
TorrentSession torrent_init();

// Add a torrent magnet link and start downloading. Returns a Torrent ID.
int torrent_add_magnet(TorrentSession session, const char* magnet_url, const char* save_path);

// Add a torrent from a local .torrent FILE and start downloading. Returns a
// Torrent ID (same stable-id space as torrent_add_magnet), or -1 if the file
// can't be parsed / the add fails. Metadata is available immediately, so the
// torrent is marked ready without a metadata-fetch phase.
int torrent_add_file(TorrentSession session, const char* torrent_path, const char* save_path);

// Get the total number of registered torrents
int torrent_count(TorrentSession session);

// Stop and remove a specific torrent
void torrent_remove(TorrentSession session, int torrent_id);

// Returns non-zero if the torrent id refers to a live (non-removed) torrent.
// Ids are stable slots that are never reused/renumbered, so callers can probe
// liveness after a remove instead of assuming compaction.
int torrent_is_alive(TorrentSession session, int torrent_id);

// Poll for playback readiness and gather qBittorrent-style stats.
// target_file_idx: if >= 0, specifically poll that file index. If -1, finds largest file.
// Returns:
//   -1: Error / Invalid
//    0: Buffering / Waiting for metadata
//    1: Ready (metadata acquired, sequential download started).
// If ready, out_path is populated with the absolute path of the target file.
int torrent_poll(TorrentSession session, int torrent_id, int target_file_idx, char* out_path, int path_max_len, float* out_progress, int* out_dl_rate, int* out_seeds);

// Multi-file / Playlist support
int torrent_get_file_count(TorrentSession session, int torrent_id);
void torrent_get_file_name(TorrentSession session, int torrent_id, int file_idx, char* out_name, int max_len);
long long torrent_get_file_size(TorrentSession session, int torrent_id, int file_idx);

// Fast string queries for the Side-Panel
void torrent_get_name(TorrentSession session, int torrent_id, char* out_name, int max_len);

// Lowercase-hex infohash (40 chars, v1 btih — the same stringification used for
// the .torrent metadata cache filename). Known from the magnet URI immediately,
// i.e. BEFORE metadata arrives, which is what lets the Downloads list join a
// still-fetching torrent to its history record. Returns 0 on success, -1 on
// failure (out is always NUL-terminated).
int torrent_get_infohash(TorrentSession session, int torrent_id, char* out, int out_len);

// Destroy the session
void torrent_destroy(TorrentSession session);

// Milestone 2: Torrent Manager functions
void torrent_set_file_priority(TorrentSession session, int torrent_id, int file_idx, int priority);
float torrent_get_file_progress(TorrentSession session, int torrent_id, int file_idx);
void torrent_set_download_limit(TorrentSession session, int limit_bytes_per_sec);
int torrent_get_piece_map(TorrentSession session, int torrent_id, char* out_map, int max_len);
int torrent_ensure_streaming_buffer(TorrentSession session, int torrent_id, int file_idx, double percent_pos);
void torrent_seek_prioritize(TorrentSession session, int torrent_id, int file_idx, double percent_pos);
// Torrent management
void torrent_pause(TorrentSession session, int torrent_id);
void torrent_resume(TorrentSession session, int torrent_id);
int torrent_is_paused(TorrentSession session, int torrent_id);
int torrent_get_num_peers(TorrentSession session, int torrent_id);
int torrent_get_upload_rate(TorrentSession session, int torrent_id);
long long torrent_get_total_size(TorrentSession session, int torrent_id);

// Piece-aware reads for HTTP streaming proxy
int torrent_get_piece_size(TorrentSession session, int torrent_id);
int torrent_read_bytes(TorrentSession session, int torrent_id, int file_idx, long long offset, char* out_buf, int buf_len);
long long torrent_get_file_offset(TorrentSession session, int torrent_id, int file_idx);

// ─── Byte-range streaming primitives ───
//
// The readiness gate reasons in BYTES, not pieces. A container's index lives at a
// byte offset (MKV Cues, MP4 moov), and "last 5 pieces" is 5 MB on a 1 MB-piece
// torrent but 80 MB on a 16 MB-piece one — piece counts are the wrong unit.

// 1 when every piece covering [offset, offset+len) of `file_idx` is downloaded.
int torrent_range_ready(TorrentSession session, int torrent_id, int file_idx, long long offset, long long len);

// Pin [offset, offset+len) at top priority with a near-immediate deadline, so
// libtorrent fetches it from the FASTEST peers. Batched in one call on purpose:
// the first deadline cancels outstanding non-critical requests, so dripping them
// in one at a time from Zig would thrash the request pipeline.
void torrent_prioritize_range(TorrentSession session, int torrent_id, int file_idx, long long offset, long long len, int deadline_ms);

// Percent (0-100) of [offset, offset+len) that is downloaded. Drives a real
// buffering bar, instead of the whole-torrent progress that says 11% while the
// bytes the demuxer is actually blocked on are 0% there.
int torrent_range_progress(TorrentSession session, int torrent_id, int file_idx, long long offset, long long len);

#ifdef __cplusplus
}
#endif
