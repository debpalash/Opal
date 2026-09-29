// Real loopback BitTorrent transfer through Opal's C API. No public swarm or
// media fixture downloads. Built/run by test_torrent_memory.py.
#include "../src/torrent_wrapper.cpp"
#include <filesystem>
#include <future>
#include <cassert>

namespace fs = std::filesystem;
static constexpr int piece_size = 64 * 1024;
static constexpr int media_size = 12 * 1024 * 1024 + 317;
static char byte_at(std::int64_t n) { return char((n * 31 + n / 997 + 17) & 255); }
static void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
static void wait_for(std::function<bool()> ready, const char* message, int seconds = 15) {
    auto end = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    while (!ready()) {
        if (std::chrono::steady_clock::now() >= end) throw std::runtime_error(message);
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}
static void local_only(SessionContext* ctx) {
    lt::settings_pack p;
    p.set_bool(lt::settings_pack::enable_dht, false);
    p.set_bool(lt::settings_pack::enable_lsd, false);
    p.set_bool(lt::settings_pack::enable_upnp, false);
    p.set_bool(lt::settings_pack::enable_natpmp, false);
    p.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
    ctx->ses->apply_settings(p);
    { std::lock_guard<std::mutex> lock(ctx->mtx); ctx->extra_trackers.clear(); }
}
int main(int argc, char** argv) try {
    require(argc == 3, "expected temporary directory and v1/hybrid/v2");
    const std::string mode = argv[2];
    const fs::path root(argv[1]);
    const auto downloads = root / "downloads";
    fs::create_directories(downloads);
    lt::file_storage files;
    files.add_file("fixture/selected.mkv", media_size);
    files.add_file("fixture/unselected.bin", 3 * 1024 * 1024);
    const auto flags = mode == "v1" ? lt::create_torrent::v1_only : mode == "v2" ? lt::create_torrent::v2_only : lt::create_flags_t{};
    lt::create_torrent creator(files, piece_size, flags);
    auto piece_bytes = [&](int p) {
        std::vector<char> bytes(files.piece_size(lt::piece_index_t(p)));
        for (int b = 0; b < int(bytes.size()); ++b) bytes[b] = byte_at(std::int64_t(p) * piece_size + b);
        for (auto f : files.file_range()) {
            if (!files.pad_file_at(f)) continue;
            const auto base = std::int64_t(p) * piece_size;
            auto start = std::max<std::int64_t>(0, files.file_offset(f) - base);
            auto end = std::min<std::int64_t>(bytes.size(), files.file_offset(f) + files.file_size(f) - base);
            for (auto b = start; b < end; ++b) bytes[b] = 0;
        }
        return bytes;
    };
    for (int p = 0; p < files.num_pieces(); ++p) {
        auto bytes = piece_bytes(p);
        if (mode != "v2") creator.set_hash(lt::piece_index_t(p), lt::hasher(lt::span<char const>(bytes)).final());
    }
    if (mode != "v1") {
        for (auto f : files.file_range()) {
            if (files.pad_file_at(f)) continue;
            const auto size = files.file_size(f);
            for (int p = 0; std::int64_t(p) * piece_size < size; ++p) {
                std::vector<lt::sha256_hash> hashes(piece_size / lt::default_block_size);
                for (int b = 0; b < int(hashes.size()); ++b) {
                    auto offset = std::int64_t(p) * piece_size + b * lt::default_block_size;
                    if (offset >= size) break;
                    std::vector<char> bytes(std::min<std::int64_t>(lt::default_block_size, size - offset));
                    for (int j = 0; j < int(bytes.size()); ++j) bytes[j] = byte_at(files.file_offset(f) + offset + j);
                    hashes[b] = lt::hasher256(lt::span<char const>(bytes)).final();
                }
                while (hashes.size() > 1) {
                    for (std::size_t b = 0; b < hashes.size() / 2; ++b) {
                        lt::hasher256 h;
                        h.update({hashes[b * 2].data(), 32});
                        h.update({hashes[b * 2 + 1].data(), 32});
                        hashes[b] = h.final();
                    }
                    hashes.resize(hashes.size() / 2);
                }
                creator.set_hash2(f, lt::piece_index_t::diff_type(p), hashes[0]);
            }
        }
    }
    std::vector<char> encoded;
    lt::bencode(std::back_inserter(encoded), creator.generate());
    const auto metadata = root / "fixture.torrent";
    { std::ofstream out(metadata, std::ios::binary); out.write(encoded.data(), encoded.size()); }

    auto seed = static_cast<SessionContext*>(torrent_init());
    auto client = static_cast<SessionContext*>(torrent_init());
    local_only(seed); local_only(client);
    torrent_set_memory_storage(seed, 1, 128);
    torrent_set_memory_storage(client, 1, 1);
    require(client->memory_limit_mib.load() == 128, "RAM minimum not enforced");
    torrent_set_memory_storage(client, 1, 9999);
    require(client->memory_limit_mib.load() == 512, "RAM maximum not enforced");
    // Small test budget forces eviction with a tiny, fast local fixture.
    client->memory_limit_mib.store(4);
    int sid = torrent_add_file(seed, metadata.c_str(), downloads.c_str());
    int id = torrent_add_file(client, metadata.c_str(), downloads.c_str());
    require(sid >= 0 && id >= 0 && torrent_is_memory_only(client, id), "memory torrent add failed");
    auto sn = get_node(seed, sid);
    auto node = get_node(client, id);
    wait_for([&]{ return sn->handle.status().state != lt::torrent_status::checking_resume_data; }, "seed initialization");
    sn->handle.prioritize_files(std::vector<lt::download_priority_t>(files.num_files(), lt::default_priority));
    for (int p = 0; p < files.num_pieces(); ++p) {
        auto bytes = piece_bytes(p);
        sn->handle.add_piece(lt::piece_index_t(p), bytes.data());
    }
    wait_for([&]{ return sn->handle.status().is_seeding; }, "seed did not hash all pieces");
    wait_for([&]{ return seed->ses->listen_port() != 0; }, "seed listener");
    const auto peer = lt::tcp::endpoint(lt::make_address("127.0.0.1"), seed->ses->listen_port());
    node->handle.connect_peer(peer);
    torrent_set_file_priority(client, id, 0, 7);
    char path[1024];
    wait_for([&]{ return torrent_poll(client, id, 0, path, sizeof(path), nullptr, nullptr, nullptr) == 1; }, "startup data unavailable");
    std::vector<char> readbuf(128 * 1024);
    std::size_t peak = 0;
    auto read_at = [&](std::int64_t offset) {
        int n = torrent_read_bytes(client, id, 0, offset, readbuf.data(), readbuf.size());
        if (n <= 0) {
            std::vector<lt::alert*> alerts;
            client->ses->pop_alerts(&alerts);
            for (auto a : alerts) std::cerr << a->message() << '\n';
            auto st = node->handle.status();
            std::cerr << "read " << offset << " returned " << n << "; state=" << st.state << "; error=" << st.errc.message() << "; peers=" << st.num_peers << '\n';
        }
        require(n > 0, "stream read failed");
        for (int b = 0; b < n; ++b) require(readbuf[b] == byte_at(offset + b), "stream returned incorrect bytes");
        peak = std::max(peak, node->memory->size());
        require(peak <= 4 * 1024 * 1024, "memory budget exceeded");
        return n;
    };
    for (std::int64_t offset = 0; offset < media_size;) offset += read_at(offset);
    require(peak > 0, "RAM store unused");
    require(!node->memory->contains(40), "fixture did not exercise eviction");
    std::cout << "PASS: forward streaming, exact bytes, RAM cap and eviction\n";
    // A seek into an evicted piece must be fetched again, never served as zeros.
    node->handle.connect_peer(peer);
    read_at(40 * piece_size + 117);
    require(node->handle.have_piece(lt::piece_index_t((media_size - 1) / piece_size)), "seek recheck discarded retained index pieces");
    std::cout << "PASS: backward seek refetches evicted bytes and preserves retained pieces\n";
    require(torrent_read_bytes(client, id, 0, media_size, readbuf.data(), readbuf.size()) == 0, "EOF incorrect");
    require(torrent_read_bytes(client, id, 0, -1, readbuf.data(), readbuf.size()) == -1, "negative read accepted");
    require(torrent_checkpoint(client) == 0, "RAM stream wrote fastresume");
    require(fs::is_empty(downloads), "RAM stream wrote torrent files/cache to disk");
    auto st = node->handle.status();
    // At most the shared boundary piece may contain bytes of the other file.
    int unselected_first = int(files.map_file(lt::file_index_t(files.num_files() - 1), piece_size, 0).piece);
    require(!st.pieces.get_bit(lt::piece_index_t(unselected_first)), "unselected file downloaded");
    std::cout << "PASS: no payload/cache files, no unselected-file download\n";

    node->handle.pause();
    auto pending = std::async(std::launch::async, [&]{ return torrent_read_bytes(client, id, 0, 80 * piece_size, readbuf.data(), readbuf.size()); });
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    torrent_cancel_reads(client, id);
    require(pending.wait_for(std::chrono::seconds(1)) == std::future_status::ready, "cancel blocked");
    require(pending.get() == -2, "cancel did not interrupt missing-piece read");
    torrent_remove(client, id);
    require(node->memory->size() == 0 && !torrent_is_alive(client, id), "removal retained RAM");
    std::cout << "PASS: pending-read cancellation and immediate RAM cleanup\n";

    torrent_set_memory_storage(client, 0, 256);
    int disk_id = torrent_add_file(client, metadata.c_str(), downloads.c_str());
    require(disk_id >= 0 && !torrent_is_memory_only(client, disk_id), "toggle off didn't restore disk storage");
    auto disk_node = get_node(client, disk_id);
    disk_node->handle.connect_peer(peer);
    wait_for([&]{ return torrent_poll(client, disk_id, 0, path, sizeof(path), nullptr, nullptr, nullptr) == 1; }, "disk mode download failed");
    require(fs::exists(downloads / "fixture/selected.mkv"), "normal storage stopped writing files");
    torrent_remove(client, disk_id);
    // A magnet has no metadata when registered; it must still select RAM
    // storage when metadata arrives later (including v2-only identities).
    fs::remove_all(downloads);
    fs::create_directories(downloads);
    torrent_set_memory_storage(client, 1, 128);
    char magnet[512];
    require(torrent_get_identity_magnet(seed, sid, magnet, sizeof(magnet)) == 0, "magnet identity missing");
    int mid = torrent_add_magnet(client, magnet, downloads.c_str());
    require(mid >= 0 && torrent_is_memory_only(client, mid), "magnet didn't select RAM");
    auto mn = get_node(client, mid);
    mn->handle.connect_peer(peer);
    wait_for([&]{ return torrent_get_file_count(client, mid) > 0; }, "magnet metadata unavailable");
    torrent_set_file_priority(client, mid, 0, 7);
    wait_for([&]{ return torrent_poll(client, mid, 0, path, sizeof(path), nullptr, nullptr, nullptr) == 1; }, "magnet startup failed");
    int n = torrent_read_bytes(client, mid, 0, 0, readbuf.data(), readbuf.size());
    require(n > 0, "magnet stream read failed");
    for (int b = 0; b < n; ++b) require(readbuf[b] == byte_at(b), "magnet bytes incorrect");
    require(fs::is_empty(downloads), "magnet wrote files to disk");
    torrent_set_memory_storage(client, 0, 128);
    require(torrent_is_memory_only(client, mid), "toggle changed active torrent storage");
    torrent_remove(client, mid);
    require(mn->memory->size() == 0, "magnet cleanup retained payload");
    std::cout << "PASS: deferred magnet metadata uses RAM; active storage survives toggle\n";
    torrent_remove(seed, sid);
    torrent_destroy(client); torrent_destroy(seed);
    std::cout << "PASS: toggle off retains normal disk downloads (" << mode << ")\n";
    return 0;
} catch (std::exception const& e) { std::cerr << "FAIL: " << e.what() << '\n'; return 1; }
