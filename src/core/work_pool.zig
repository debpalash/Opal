const std = @import("std");
const sync = @import("sync.zig");
const io_global = @import("io_global.zig");

// ══════════════════════════════════════════════════════════
// WorkPool — fixed-size worker thread pool with bounded queue.
//
// Replaces the scattered `std.Thread.spawn(...) catch {}` pattern
// (detached, unbounded, unjoinable) used throughout the codebase.
// Callers submit work items; N workers drain a bounded ring buffer.
//
// Queue strategy: mutex + 10ms sleep-loop, not a condvar.
// Why: std.Thread.Condition was removed in 0.16 (same fate as
// std.Thread.Mutex — see core/sync.zig). pthread_cond_t directly
// works but adds a second pthread dependency for marginal gain.
// 10ms wakeup latency is fine for our use cases (UI worker, IO,
// background fetches). If a hot path ever needs sub-ms wakeups
// we can swap the backoff for a real condvar wrapper here.
// ══════════════════════════════════════════════════════════

pub const WorkFn = *const fn (ctx: *anyopaque) void;

pub const WorkItem = struct {
    func: WorkFn,
    ctx: *anyopaque,
};

const MAX_WORKERS: usize = 8;
const WORKER_BACKOFF_NS: u64 = 10 * std.time.ns_per_ms;
const SUBMIT_BACKOFF_NS: u64 = 1 * std.time.ns_per_ms;

pub const WorkPool = struct {
    allocator: std.mem.Allocator,
    queue: []WorkItem,
    head: usize, // next slot to pop (under mu)
    tail: usize, // next slot to push (under mu)
    count: usize, // items currently in queue (under mu)
    mu: sync.Mutex,
    workers: []std.Thread,
    running: std.atomic.Value(bool),

    /// Spawn `n_workers` threads (clamped to [1, MAX_WORKERS] and CPU count)
    /// with a ring buffer of `queue_capacity` slots.
    pub fn init(
        allocator: std.mem.Allocator,
        n_workers: usize,
        queue_capacity: usize,
    ) !*WorkPool {
        const cpu = std.Thread.getCpuCount() catch 4;
        const requested = if (n_workers == 0) cpu else n_workers;
        const n = @max(@as(usize, 1), @min(requested, @min(cpu, MAX_WORKERS)));
        const cap = @max(@as(usize, 1), queue_capacity);

        const pool = try allocator.create(WorkPool);
        errdefer allocator.destroy(pool);

        const queue = try allocator.alloc(WorkItem, cap);
        errdefer allocator.free(queue);

        const workers = try allocator.alloc(std.Thread, n);
        errdefer allocator.free(workers);

        pool.* = .{
            .allocator = allocator,
            .queue = queue,
            .head = 0,
            .tail = 0,
            .count = 0,
            .mu = .{},
            .workers = workers,
            .running = std.atomic.Value(bool).init(true),
        };

        // Spawn workers. If any spawn fails, signal stop, join those that
        // started, free resources, return the error.
        var spawned: usize = 0;
        errdefer {
            pool.running.store(false, .seq_cst);
            for (workers[0..spawned]) |t| t.join();
        }
        while (spawned < n) : (spawned += 1) {
            workers[spawned] = try std.Thread.spawn(.{}, workerLoop, .{pool});
        }

        return pool;
    }

    /// Try to enqueue work without blocking. Returns false if queue is full
    /// or pool is shutting down.
    pub fn submit(self: *WorkPool, work: WorkItem) bool {
        if (!self.running.load(.seq_cst)) return false;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.count == self.queue.len) return false;
        self.queue[self.tail] = work;
        self.tail = (self.tail + 1) % self.queue.len;
        self.count += 1;
        return true;
    }

    /// Enqueue work, blocking with 1ms backoff while queue is full.
    /// Returns once accepted, or immediately if the pool is shutting down.
    pub fn submitBlocking(self: *WorkPool, work: WorkItem) void {
        while (self.running.load(.seq_cst)) {
            if (self.submit(work)) return;
            io_global.sleep(SUBMIT_BACKOFF_NS);
        }
    }

    /// Signal stop, drain in-flight items, join all workers, free memory.
    /// Pool pointer is invalid after this call.
    pub fn shutdown(self: *WorkPool) void {
        self.running.store(false, .seq_cst);
        for (self.workers) |t| t.join();
        self.allocator.free(self.workers);
        self.allocator.free(self.queue);
        self.allocator.destroy(self);
    }

    fn workerLoop(self: *WorkPool) void {
        while (true) {
            // Pop one item under the lock, then run it unlocked.
            self.mu.lock();
            if (self.count == 0) {
                self.mu.unlock();
                if (!self.running.load(.seq_cst)) return;
                io_global.sleep(WORKER_BACKOFF_NS);
                continue;
            }
            const item = self.queue[self.head];
            self.head = (self.head + 1) % self.queue.len;
            self.count -= 1;
            const shutting_down = !self.running.load(.seq_cst);
            self.mu.unlock();

            item.func(item.ctx);

            // If shutting down, drain remaining items then exit.
            if (shutting_down) {
                self.drainRemaining();
                return;
            }
        }
    }

    fn drainRemaining(self: *WorkPool) void {
        while (true) {
            self.mu.lock();
            if (self.count == 0) {
                self.mu.unlock();
                return;
            }
            const item = self.queue[self.head];
            self.head = (self.head + 1) % self.queue.len;
            self.count -= 1;
            self.mu.unlock();
            item.func(item.ctx);
        }
    }
};

// ══════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════

// TODO: cross-boundary test, run manually until MockIo lands.
// Uses io_global.sleep transitively via workerLoop, which initializes
// the threaded Io; safe in a test binary but not pure.
test "WorkPool: 100 submissions hit shared atomic" {
    const TestCtx = struct {
        var counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn bump(_: *anyopaque) void {
            _ = counter.fetchAdd(1, .seq_cst);
        }
    };
    TestCtx.counter.store(0, .seq_cst);

    var pool = try WorkPool.init(std.testing.allocator, 2, 16);
    var dummy: u8 = 0;
    const dummy_ptr: *anyopaque = @ptrCast(&dummy);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        pool.submitBlocking(.{ .func = TestCtx.bump, .ctx = dummy_ptr });
    }

    // Wait for the queue to fully drain before shutting down — shutdown
    // joins workers immediately on the running=false signal, so any items
    // still queued would be skipped.
    while (true) {
        pool.mu.lock();
        const remaining = pool.count;
        pool.mu.unlock();
        if (remaining == 0) break;
        io_global.sleep(1 * std.time.ns_per_ms);
    }
    // Even with queue empty, the last worker may still be executing the
    // final item. Brief grace period before signalling stop.
    io_global.sleep(20 * std.time.ns_per_ms);

    pool.shutdown();
    try std.testing.expectEqual(@as(u32, 100), TestCtx.counter.load(.seq_cst));
}
