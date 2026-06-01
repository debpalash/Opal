# Contributing to Opal

Thank you for your interest in contributing! Here's how to get started.

## Development Setup

1. Install prerequisites (see README.md)
2. Clone the repository:
   ```bash
   git clone https://github.com/debpalash/Opal.git
   cd Opal
   ```
3. Build:
   ```bash
   zig build
   ```
4. Run:
   ```bash
   ./zig-out/bin/zigzag
   ```

## Making Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Make your changes following the code conventions in CLAUDE.md
4. Ensure the project builds: `zig build`
5. Run tests: `zig build test`
6. Commit with a descriptive message
7. Push and open a Pull Request

## Code Style

- Follow Zig standard conventions
- Use `@import("core/alloc.zig").allocator` for allocations
- Use `@import("core/io_global.zig")` wrappers for I/O (not `std.fs.cwd()`)
- Thread-shared bools must use `std.atomic.Value(bool)` — see CLAUDE.md for details
- Large buffers (>64KB) on spawned threads must be heap-allocated

## Reporting Issues

- Use GitHub Issues
- Include your OS, Zig version, and steps to reproduce
- For crashes, include the stack trace if available

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
