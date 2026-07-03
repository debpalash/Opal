## What & why

<!-- One or two sentences. Link the issue if there is one. -->

## Test evidence

<!-- House rule: every feature/fix ships with a test (see CONTRIBUTING.md). -->

- [ ] `zig build test` passes
- [ ] `just test-all` — tally: `___ passed / 0 failed / ___ skipped`
- [ ] New/updated test covering this change: <!-- name it, or say why GUI-only -->

## Checklist

- [ ] No new allocator, no `std.fs.cwd()`/`std.time`/`std.posix.getenv` (use `io_global`)
- [ ] Shared state mutations follow the thread-safety conventions in CONTRIBUTING.md
- [ ] No content-source/scraping code in the core (CONTENT_POLICY.md)
