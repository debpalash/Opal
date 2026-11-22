// Seek-aware deadline FFI and transfer-policy inputs, exercised through Opal's
// C API against a real loopback seed. Legal generated fixture, no public swarm.
// Built/run by test_torrent_deadline.py.
#include "../src/torrent_wrapper.cpp"
#include <filesystem>
#include <functional>

namespace fs = std::filesystem;
static constexpr int piece_size = 64 * 1024;
static constexpr std::int64_t size_a = 300 * 1024 + 123;      // ends mid-piece
static constexpr std::int64_t size_b = 4 * 1024 * 1024 + 317; // short last piece
static char byte_at(std::int64_t n) { return char((n * 31 + n / 997 + 17) & 255); }
static void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
static void wait_for(std::function<bool()> ready, const char* message, int seconds = 20) {
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
    require(argc == 2, "expected temporary directory");
    const fs::path root(argv[1]);
    const auto seed_dir = root / "seed";
    const auto client_dir = root / "client";
    fs::create_directories(seed_dir);
    fs::create_directories(client_dir);

    lt::file_storage files;
    files.add_file("fixture/a.bin", size_a);
    files.add_file("fixture/b.mkv", size_b);
    lt::create_torrent creator(files, piece_size, lt::create_torrent::v1_only);
    auto piece_bytes = [&](int p) {
        std::vector<char> bytes(files.piece_size(lt::piece_index_t(p)));
        for (int b = 0; b < int(bytes.size()); ++b) bytes[b] = byte_at(std::int64_t(p) * piece_size + b);
        return bytes;
    };
    for (int p = 0; p < files.num_pieces(); ++p) {
        auto bytes = piece_bytes(p);
        creator.set_hash(lt::piece_index_t(p), lt::hasher(lt::span<char const>(bytes)).final());
    }
    std::vector<char> encoded;
    lt::bencode(std::back_inserter(encoded), creator.generate());
    const auto metadata = root / "fixture.torrent";
    { std::ofstream out(metadata, std::ios::binary); out.write(encoded.data(), encoded.size()); }

    auto seed = static_cast<SessionContext*>(torrent_init());
    auto client = static_cast<SessionContext*>(torrent_init());
    local_only(seed); local_only(client);
    int sid = torrent_add_file(seed, metadata.c_str(), seed_dir.c_str());
    int id = torrent_add_file(client, metadata.c_str(), client_dir.c_str());
    require(sid >= 0 && id >= 0, "add failed");
    auto sn = get_node(seed, sid);
    auto node = get_node(client, id);
    wait_for([&]{ return sn->handle.status().state != lt::torrent_status::checking_resume_data; }, "seed init");
    for (int p = 0; p < files.num_pieces(); ++p) {
        auto bytes = piece_bytes(p);
        sn->handle.add_piece(lt::piece_index_t(p), bytes.data());
    }
    wait_for([&]{ return sn->handle.status().is_seeding; }, "seed did not hash all pieces");
    wait_for([&]{ return seed->ses->listen_port() != 0; }, "seed listener");

    // ── Geometry ──
    long long off = -1, fsize = -1; int psize = -1, npieces = -1;
    require(torrent_get_piece_geometry(client, id, 1, &off, &fsize, &psize, &npieces) == 0, "geometry failed");
    require(off == size_a && fsize == size_b, "file offset/size wrong");
    require(psize == piece_size && npieces == files.num_pieces(), "piece size/count wrong");
    require(torrent_get_piece_geometry(client, id, 2, &off, &fsize, &psize, &npieces) == -1, "out-of-range file accepted");
    require(torrent_get_piece_geometry(client, 999, 0, &off, &fsize, &psize, &npieces) == -1, "stale id accepted");
    require(torrent_get_piece_geometry(client, id, 0, nullptr, &fsize, &psize, &npieces) == -1, "null out accepted");
    std::cout << "PASS: piece geometry (multi-file offset, short last piece, stale id)\n";

    // Nothing is wanted until a deadline asks for it.
    wait_for([&]{ auto st = node->handle.status().state; return st != lt::torrent_status::checking_resume_data && st != lt::torrent_status::checking_files; }, "client init");
    for (int f = 0; f < files.num_files(); ++f) torrent_set_file_priority(client, id, f, 0);
    // File priorities are applied asynchronously (via the disk thread) and then
    // rewrite piece priorities; wait so they can't overwrite the deadlines.
    wait_for([&]{
        for (int p = 0; p < files.num_pieces(); ++p)
            if (node->handle.piece_priority(lt::piece_index_t(p)) != lt::dont_download) return false;
        return true;
    }, "file priorities not applied");
    const auto seed_ep = lt::tcp::endpoint(lt::make_address("127.0.0.1"), seed->ses->listen_port());

    // ── Jump: seek into file b at 2 MiB ──
    const int target = int((size_a + 2 * 1024 * 1024) / piece_size);
    std::vector<int> win, dl;
    for (int i = 0; i < 6; ++i) { win.push_back(target + i); dl.push_back(i * 10); }
    int applied = torrent_apply_piece_deadlines(client, id, 1, nullptr, 0, win.data(), dl.data(), int(win.size()), target);
    require(applied == int(win.size()), "jump did not apply every deadline");
    require(node->last_deadline_piece == target, "target not recorded");
    // A torrent with nothing wanted counts as finished and drops its seed, so
    // connect only now and re-dial while waiting.
    int spins = 0;
    wait_for([&]{
        if (spins++ % 50 == 0) node->handle.connect_peer(seed_ep);
        for (int p : win) if (!node->handle.have_piece(lt::piece_index_t(p))) {
            if (spins % 200 == 199) {
                auto st = node->handle.status();
                auto ss = sn->handle.status();
                std::cerr << "client state=" << st.state << " peers=" << st.num_peers << " paused=" << bool(st.flags & lt::torrent_flags::paused)
                          << " prio=" << int(static_cast<std::uint8_t>(node->handle.piece_priority(lt::piece_index_t(p))))
                          << " err=" << st.errc.message() << " seed state=" << ss.state << " seed peers=" << ss.num_peers
                          << " seed paused=" << bool(ss.flags & lt::torrent_flags::paused) << " port=" << seed->ses->listen_port() << '\n';
                std::vector<lt::alert*> alerts; client->ses->pop_alerts(&alerts);
                for (auto a : alerts) std::cerr << "  c: " << a->message() << '\n';
                seed->ses->pop_alerts(&alerts);
                for (auto a : alerts) std::cerr << "  s: " << a->message() << '\n';
            }
            return false;
        }
        return true;
    }, "deadlined window not fetched");
    const int far = files.num_pieces() - 3;
    require(!node->handle.have_piece(lt::piece_index_t(far)), "undeadlined piece downloaded");
    std::cout << "PASS: jump fetches the deadlined window first and nothing else\n";

    // ── Slide: release stale pieces, arm the new front ──
    // libtorrent drops a completed deadline piece's priority on its own, so
    // "untouched" is the invariant for pieces still inside the window.
    const auto live_before = node->handle.piece_priority(lt::piece_index_t(target + 3));
    std::vector<int> stale{target, target + 1};
    std::vector<int> front{target + 6, target + 7};
    std::vector<int> front_dl{0, 10};
    applied = torrent_apply_piece_deadlines(client, id, 0, stale.data(), int(stale.size()), front.data(), front_dl.data(), int(front.size()), target + 2);
    require(applied == 2, "slide did not apply");
    require(node->handle.piece_priority(lt::piece_index_t(target)) == lt::default_priority, "stale piece kept top priority");
    require(node->handle.piece_priority(lt::piece_index_t(target + 6)) == lt::top_priority, "front not top priority");
    require(node->handle.piece_priority(lt::piece_index_t(target + 3)) == live_before, "slide touched a live window piece");
    std::cout << "PASS: slide releases only stale pieces\n";

    // ── Bounds ──
    std::vector<int> bad{-1, npieces, npieces + 50};
    std::vector<int> bad_dl{0, 0, 0};
    require(torrent_apply_piece_deadlines(client, id, 0, bad.data(), 3, bad.data(), bad_dl.data(), 3, -1) == 0, "out-of-range pieces not skipped");
    require(torrent_apply_piece_deadlines(client, 999, 1, nullptr, 0, nullptr, nullptr, 0, 0) == -1, "stale id accepted");
    require(torrent_apply_piece_deadlines(client, id, 0, nullptr, 2, nullptr, nullptr, 0, 0) == -1, "null reset list accepted");
    std::cout << "PASS: out-of-range and stale inputs rejected\n";

    // ── Transfer facts + disk guard input ──
    TorrentTransferFacts tf;
    require(torrent_get_transfer_facts(client, id, &tf) == 0, "facts failed");
    require(tf.has_metadata == 1 && tf.is_memory == 0 && tf.paused == 0 && tf.has_error == 0, "facts flags wrong");
    require(tf.total_wanted_done > 0 && tf.total_wanted_done <= tf.total_wanted, "wanted bytes wrong");
    torrent_pause(client, id);
    wait_for([&]{ return torrent_get_transfer_facts(client, id, &tf) == 0 && tf.paused == 1; }, "pause not reflected");
    require(torrent_get_transfer_facts(client, 999, &tf) == -1, "stale id facts");
    wait_for([&]{ return torrent_get_transfer_facts(seed, sid, &tf) == 0 && tf.all_time_upload > 0; }, "seed upload not counted");
    require(torrent_disk_free_bytes(root.c_str()) > 0, "free space unknown");
    require(torrent_disk_free_bytes((root / "missing" / "dir").c_str()) == -1, "missing dir reported space");
    require(torrent_disk_free_bytes("") == -1 && torrent_disk_free_bytes(nullptr) == -1, "empty path reported space");
    std::cout << "PASS: transfer facts, pause flag, upload counter, disk free\n";

    // ── RAM streams refuse the disk-window call ──
    auto ram_ses = static_cast<SessionContext*>(torrent_init());
    local_only(ram_ses);
    torrent_set_memory_storage(ram_ses, 1, 128);
    const auto ram_dir = root / "ram";
    fs::create_directories(ram_dir);
    int ram = torrent_add_file(ram_ses, metadata.c_str(), ram_dir.c_str());
    require(ram >= 0 && torrent_is_memory_only(ram_ses, ram), "RAM add failed");
    require(torrent_apply_piece_deadlines(ram_ses, ram, 1, nullptr, 0, win.data(), dl.data(), 1, target) == -1, "RAM stream accepted disk window");
    require(torrent_get_transfer_facts(ram_ses, ram, &tf) == 0 && tf.is_memory == 1, "RAM facts flag");
    std::cout << "PASS: RAM stream refuses the disk window (Zig falls back to the seek hint)\n";
    std::cout << "ALL PASS" << std::endl;
    std::_Exit(0); // skip session teardown (torrent_destroy is unwired in the app too)
} catch (const std::exception& e) {
    std::cerr << "FAIL: " << e.what() << '\n';
    return 1;
}
