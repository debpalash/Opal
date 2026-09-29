#pragma once

// Bounded torrent payload storage. Only libtorrent's public disk interface is
// used; disk-backed torrents continue through its normal storage implementation.
#include <libtorrent/disk_interface.hpp>
#include <libtorrent/disk_buffer_holder.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/storage_defs.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/hasher.hpp>
#include <libtorrent/peer_request.hpp>
#include <boost/asio/post.hpp>
#include <algorithm>
#include <map>
#include <set>
#include <filesystem>
#include <mutex>
#include <memory>
#include <cstring>

namespace opal {
namespace lt = libtorrent;

struct MemoryStorage {
    struct Piece {
        std::vector<char> bytes;
        std::vector<bool> blocks;
        std::uint64_t touched = 0;
        bool hashed = false;
    };
    explicit MemoryStorage(std::size_t limit) : limit(limit) {}
    std::mutex mutex;
    lt::file_storage files;
    std::map<int, Piece> pieces;
    std::set<int> pinned;
    std::map<int, int> readers;
    const std::size_t limit;
    std::size_t used = 0;
    std::uint64_t clock = 0;
    bool closed = false;

    void clear() {
        std::lock_guard<std::mutex> lock(mutex);
        closed = true;
        pieces.clear();
        used = 0;
    }
    bool contains(int piece) {
        std::lock_guard<std::mutex> lock(mutex);
        auto i = pieces.find(piece);
        return i != pieces.end() && i->second.hashed;
    }
    std::size_t size() {
        std::lock_guard<std::mutex> lock(mutex);
        return used;
    }
    bool needs_recheck() {
        std::lock_guard<std::mutex> lock(mutex);
        std::size_t abandoned = 0;
        for (auto const& item : pieces)
            if (!item.second.hashed && !pinned.count(item.first) && !readers.count(item.first)) abandoned += item.second.bytes.size();
        return abandoned >= limit / 4;
    }
    // Called on the libtorrent thread after force_recheck resets its picker.
    // It is now safe to discard abandoned partial pieces as well as finished
    // ones; their downloaded-block state can no longer outlive their bytes.
    bool prepare_recheck() {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto i = pieces.begin(); i != pieces.end();) {
            if (!i->second.hashed) { used -= i->second.bytes.size(); i = pieces.erase(i); }
            else ++i;
        }
        return !pieces.empty();
    }
    // Never evict an unfinished piece: libtorrent may still be assembling or
    // hashing it. Eviction never manufactures bytes for a missing read.
    bool write(lt::peer_request const& r, char const* data) {
        std::lock_guard<std::mutex> lock(mutex);
        if (closed) return false;
        const int n = files.piece_size(r.piece);
        if (r.start < 0 || r.length <= 0 || r.start > n - r.length) return false;
        auto i = pieces.find(int(r.piece));
        if (i == pieces.end()) {
            if (std::size_t(n) > limit) return false;
            while (used + n > limit) {
                auto oldest = pieces.end();
                for (auto it = pieces.begin(); it != pieces.end(); ++it)
                    if (it->second.hashed && !pinned.count(it->first) && !readers.count(it->first) && (oldest == pieces.end() || it->second.touched < oldest->second.touched)) oldest = it;
                if (oldest == pieces.end()) return false;
                used -= oldest->second.bytes.size();
                pieces.erase(oldest);
            }
            Piece p;
            p.bytes.resize(n);
            p.blocks.resize((n + lt::default_block_size - 1) / lt::default_block_size);
            // libtorrent doesn't write pad files; their bytes are implicit zero.
            const auto base = std::int64_t(int(r.piece)) * files.piece_length();
            for (auto f : files.file_range()) {
                if (!files.pad_file_at(f)) continue;
                auto begin = std::max<std::int64_t>(0, files.file_offset(f) - base);
                auto end = std::min<std::int64_t>(n, files.file_offset(f) + files.file_size(f) - base);
                for (auto b = (begin + lt::default_block_size - 1) / lt::default_block_size; b * lt::default_block_size < end; ++b)
                    if (std::min<std::int64_t>(n, (b + 1) * lt::default_block_size) <= end) p.blocks[b] = true;
            }
            i = pieces.emplace(int(r.piece), std::move(p)).first;
            used += n;
        }
        auto& p = i->second;
        std::memcpy(p.bytes.data() + r.start, data, r.length);
        p.blocks[r.start / lt::default_block_size] = true;
        p.hashed = false;
        p.touched = ++clock;
        return true;
    }
    bool read(int piece, int offset, int length, char* out, bool touch = false) {
        std::lock_guard<std::mutex> lock(mutex);
        auto i = pieces.find(piece);
        if (i == pieces.end() || !i->second.hashed || offset < 0 || length < 0
            || std::size_t(offset) + length > i->second.bytes.size()) return false;
        std::memcpy(out, i->second.bytes.data() + offset, length);
        if (touch) i->second.touched = ++clock;
        return true;
    }
    lt::sha1_hash hash(lt::piece_index_t piece, lt::span<lt::sha256_hash> v2) {
        std::lock_guard<std::mutex> lock(mutex);
        std::fill(v2.begin(), v2.end(), lt::sha256_hash{});
        auto i = pieces.find(int(piece));
        // A missing piece hashes to an invalid digest during force_recheck.
        // EOF would cause libtorrent to skip the remaining pieces in the file.
        if (i == pieces.end() || !std::all_of(i->second.blocks.begin(), i->second.blocks.end(), [](bool b){ return b; })) return {};
        auto& p = i->second;
        for (int b = 0; b < int(v2.size()) && b * lt::default_block_size < files.piece_size2(piece); ++b) {
            const int offset = b * lt::default_block_size;
            v2[b] = lt::hasher256(lt::span<char const>{p.bytes.data() + offset, std::min(lt::default_block_size, files.piece_size2(piece) - offset)}).final();
        }
        p.hashed = true;
        return lt::hasher(lt::span<char const>{p.bytes.data(), std::ptrdiff_t(p.bytes.size())}).final();
    }
    lt::sha256_hash hash2(lt::piece_index_t piece, int offset) {
        std::lock_guard<std::mutex> lock(mutex);
        auto i = pieces.find(int(piece));
        if (i == pieces.end() || offset < 0 || offset >= files.piece_size2(piece)
            || !i->second.blocks[offset / lt::default_block_size]) return {};
        return lt::hasher256(lt::span<char const>{i->second.bytes.data() + offset, std::min(lt::default_block_size, files.piece_size2(piece) - offset)}).final();
    }
};

// Protect concurrent HTTP range readers from one another's window changes.
struct MemoryReadPin {
    std::shared_ptr<MemoryStorage> storage;
    int piece;
    MemoryReadPin(std::shared_ptr<MemoryStorage> storage, int piece) : storage(std::move(storage)), piece(piece) {
        if (this->storage) { std::lock_guard<std::mutex> lock(this->storage->mutex); ++this->storage->readers[piece]; }
    }
    ~MemoryReadPin() {
        if (storage) {
            std::lock_guard<std::mutex> lock(storage->mutex);
            if (--storage->readers[piece] == 0) storage->readers.erase(piece);
        }
    }
};

struct MemoryRegistry {
    std::mutex mutex;
    std::map<std::string, std::weak_ptr<MemoryStorage>> entries;
    std::uint64_t next = 0;
};

class StreamingDisk final : public lt::disk_interface, public lt::buffer_allocator_interface {
    lt::io_context& io;
    std::unique_ptr<lt::disk_interface> disk;
    std::shared_ptr<MemoryRegistry> registry;
    std::map<lt::storage_index_t, std::shared_ptr<MemoryStorage>> memory;
    std::uint32_t next = 0x80000000u;
    auto store(lt::storage_index_t s) {
        auto i = memory.find(s);
        return i == memory.end() ? std::shared_ptr<MemoryStorage>{} : i->second;
    }
    static lt::storage_error error(boost::system::errc::errc_t code) {
        return lt::storage_error(make_error_code(code), lt::operation_t::file_read);
    }
public:
    StreamingDisk(lt::io_context& io, lt::settings_interface const& settings, lt::counters& counters,
                  std::shared_ptr<MemoryRegistry> registry)
        : io(io), disk(lt::default_disk_io_constructor(io, settings, counters)), registry(std::move(registry)) {}
    lt::storage_holder new_torrent(lt::storage_params const& p, std::shared_ptr<void> const& t) override {
        std::shared_ptr<MemoryStorage> m;
        {
            std::lock_guard<std::mutex> lock(registry->mutex);
            auto i = registry->entries.find(std::filesystem::path(p.path).lexically_normal().generic_string());
            if (i != registry->entries.end()) {
                m = i->second.lock();
                registry->entries.erase(i);
            }
        }
        // Reserved RAM paths must never fall back to a disk implementation.
        if (!m && std::filesystem::path(p.path).filename().string().find(".opal-memory-") == 0)
            m = std::make_shared<MemoryStorage>(0);
        if (!m) return disk->new_torrent(p, t);
        { std::lock_guard<std::mutex> lock(m->mutex); m->files = p.files; }
        auto s = lt::storage_index_t(next++);
        memory.emplace(s, m);
        return {s, *this};
    }
    void remove_torrent(lt::storage_index_t s) override {
        if (auto m = store(s)) { m->clear(); memory.erase(s); }
        else disk->remove_torrent(s);
    }
    void free_disk_buffer(char* b) override { delete[] b; }
    void async_read(lt::storage_index_t s, lt::peer_request const& r,
                    std::function<void(lt::disk_buffer_holder, lt::storage_error const&)> h, lt::disk_job_flags_t f) override {
        auto m = store(s);
        if (!m) return disk->async_read(s, r, std::move(h), f);
        auto b = std::make_unique<char[]>(r.length);
        auto ec = m->read(int(r.piece), r.start, r.length, b.get()) ? lt::storage_error{} : error(boost::system::errc::no_such_file_or_directory);
        boost::asio::post(io, [this, h=std::move(h), b=std::move(b), ec, r]() mutable {
            h(lt::disk_buffer_holder(*this, b.release(), r.length), ec);
        });
    }
    bool async_write(lt::storage_index_t s, lt::peer_request const& r, char const* b,
                     std::shared_ptr<lt::disk_observer> o, std::function<void(lt::storage_error const&)> h, lt::disk_job_flags_t f) override {
        auto m = store(s);
        if (!m) return disk->async_write(s, r, b, std::move(o), std::move(h), f);
        auto ec = m->write(r, b) ? lt::storage_error{} : error(boost::system::errc::no_buffer_space);
        boost::asio::post(io, [h=std::move(h), ec]{ h(ec); });
        return false;
    }
    void async_hash(lt::storage_index_t s, lt::piece_index_t p, lt::span<lt::sha256_hash> v2,
                    lt::disk_job_flags_t f, std::function<void(lt::piece_index_t, lt::sha1_hash const&, lt::storage_error const&)> h) override {
        auto m = store(s);
        if (!m) return disk->async_hash(s, p, v2, f, std::move(h));
        auto hash = m->hash(p, v2);
        boost::asio::post(io, [h=std::move(h), p, hash]{ h(p, hash, {}); });
    }
    void async_hash2(lt::storage_index_t s, lt::piece_index_t p, int offset, lt::disk_job_flags_t f,
                    std::function<void(lt::piece_index_t, lt::sha256_hash const&, lt::storage_error const&)> h) override {
        auto m = store(s);
        if (!m) return disk->async_hash2(s, p, offset, f, std::move(h));
        auto hash = m->hash2(p, offset);
        boost::asio::post(io, [h=std::move(h), p, hash]{ h(p, hash, {}); });
    }
    void async_move_storage(lt::storage_index_t s, std::string p, lt::move_flags_t f,
                            std::function<void(lt::status_t, std::string const&, lt::storage_error const&)> h) override {
        if (!store(s)) return disk->async_move_storage(s, std::move(p), f, std::move(h));
        boost::asio::post(io, [h=std::move(h), p]{ h(lt::status_t::fatal_disk_error, p, error(boost::system::errc::operation_not_supported)); });
    }
    void async_release_files(lt::storage_index_t s, std::function<void()> h) override {
        if (!store(s)) return disk->async_release_files(s, std::move(h));
        if (h) boost::asio::post(io, std::move(h));
    }
    void async_check_files(lt::storage_index_t s, lt::add_torrent_params const* p,
                           lt::aux::vector<std::string, lt::file_index_t> links, std::function<void(lt::status_t, lt::storage_error const&)> h) override {
        auto m = store(s);
        if (!m) return disk->async_check_files(s, p, std::move(links), std::move(h));
        const auto status = m->prepare_recheck() ? lt::status_t::need_full_check : lt::status_t::no_error;
        boost::asio::post(io, [h=std::move(h), status]{ h(status, {}); });
    }
    void async_stop_torrent(lt::storage_index_t s, std::function<void()> h) override {
        if (!store(s)) return disk->async_stop_torrent(s, std::move(h));
        if (h) boost::asio::post(io, std::move(h));
    }
    void async_rename_file(lt::storage_index_t s, lt::file_index_t i, std::string name,
                           std::function<void(std::string const&, lt::file_index_t, lt::storage_error const&)> h) override {
        if (!store(s)) return disk->async_rename_file(s, i, std::move(name), std::move(h));
        boost::asio::post(io, [h=std::move(h), name, i]{ h(name, i, error(boost::system::errc::operation_not_supported)); });
    }
    void async_delete_files(lt::storage_index_t s, lt::remove_flags_t f, std::function<void(lt::storage_error const&)> h) override {
        auto m = store(s);
        if (!m) return disk->async_delete_files(s, f, std::move(h));
        m->clear();
        boost::asio::post(io, [h=std::move(h)]{ h({}); });
    }
    void async_set_file_priority(lt::storage_index_t s, lt::aux::vector<lt::download_priority_t, lt::file_index_t> p,
                                 std::function<void(lt::storage_error const&, lt::aux::vector<lt::download_priority_t, lt::file_index_t>)> h) override {
        if (!store(s)) return disk->async_set_file_priority(s, std::move(p), std::move(h));
        boost::asio::post(io, [h=std::move(h), p=std::move(p)]() mutable { h({}, std::move(p)); });
    }
    void async_clear_piece(lt::storage_index_t s, lt::piece_index_t p, std::function<void(lt::piece_index_t)> h) override {
        auto m = store(s);
        if (!m) return disk->async_clear_piece(s, p, std::move(h));
        { std::lock_guard<std::mutex> lock(m->mutex);
          auto i = m->pieces.find(int(p));
          if (i != m->pieces.end()) { m->used -= i->second.bytes.size(); m->pieces.erase(i); } }
        boost::asio::post(io, [h=std::move(h), p]{ h(p); });
    }
    void update_stats_counters(lt::counters& c) const override { disk->update_stats_counters(c); }
    std::vector<lt::open_file_state> get_status(lt::storage_index_t s) const override {
        return memory.count(s) ? std::vector<lt::open_file_state>{} : disk->get_status(s);
    }
    void abort(bool wait) override { disk->abort(wait); }
    void submit_jobs() override { disk->submit_jobs(); }
    void settings_updated() override { disk->settings_updated(); }
};
} // namespace opal
