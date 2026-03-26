# instantgrep — Changelog

All changes are relative to the last published commit (`bb9fdcf` — *chore: move to homebrew repo for formulae*).

---

## Performance Improvements

### 1. ETS Sharding — 6× faster index builds (`index.ex`)

The postings table is now **sharded across N ETS tables** (one per scheduler, default 16).

- **Before**: a single `:bag` table with 32 stripe locks — 16 concurrent workers produced near-100% lock collisions.
- **After**: trigrams are routed to `rem(:erlang.phash2(trigram), N)` shard; workers batch-insert per shard per file, eliminating cross-worker contention.
- Each table uses both `write_concurrency: true` and `read_concurrency: true`.
- **Result**: index build time on a large codebase dropped from ~125s → ~21s (**6×**).

### 2. Per-shard Compressed Index Files — 5× faster cold load (`index.ex`)

Disk format changed from a single merged `postings.dat` to **16 independent `postings_N.dat` files** (format version 4).

- **Before**: one ~53 MB file, sequential `Enum.group_by` to re-shard on load.
- **After**: each shard file is written and loaded independently with `Task.async_stream`; no regrouping needed on load. Files are compressed with `[:compressed]` (53 MB → ~16 MB total).
- A new `meta.dat` file stores `format_version`, `num_shards`, `file_count`, `trigram_count`, `build_time_us`.
- **Result**: cold index load on a large codebase dropped from ~21s → ~4.3s (**5×**).

### 3. Bloom-filter Mask Pre-filtering (`query.ex`)

New `evaluate_masked/2` replaces `evaluate/2` in the hot search path.

- For `:all`-chains of consecutive trigrams (the common case for literal patterns), the `next_mask` stored per posting is used to **pre-filter candidate files before looking up the next trigram**.
- `next_mask` stores `bsl(1, band(char_at_pos+3, 7))` — a 1-bit bloom filter for the 4th character after each trigram occurrence. Files that cannot have the next trigram adjacent are excluded before any ETS lookup.
- **Bug fixed**: the pre-filter was using `first_byte` of the next trigram instead of `last_byte` (= `char_at_pos+3`), causing false negatives (e.g. `"nullptr"` returning 0 results). Fixed to `<<_, _, last_byte>> = trigram`.
- `bench.ex` updated to use `evaluate_masked` + `lookup_with_masks`.

### 4. Parallel Directory Scanner (`scanner.ex`)

- `scan/2` now calls `do_scan_parallel/3` for the root directory, distributing each top-level child to a separate `Task.async_stream` worker (`max_concurrency: schedulers_online, timeout: :infinity`).
- All recursion within each task remains **sequential** to avoid nested `async_stream` timeout issues.
- `File.ls!` replaced with `File.ls` everywhere — permission-denied directories are silently skipped (`{:error, _} -> []`) instead of crashing with `File.Error`.
- `{:exit, _} -> []` handler added in the flat_map to absorb any task failures.

### 5. Binary File Detection Moved to Indexer (`index.ex`, `scanner.ex`)

- `binary_content?/1` and `binary_heuristic?/1` removed from `scanner.ex` — they opened every file twice (once to check, once to index).
- Replaced by `binary?/1` in `index.ex`, called on the first 512 bytes of content already read for indexing. Uses `:binary.match(data, <<0>>)` (null-byte detection via a native BIF).

### 6. Faster Line Splitting (`matcher.ex`)

- `String.split(content, "\n")` replaced with `:binary.split(content, "\n", [:global])`.
- `:binary.split` is a native BIF (Boyer-Moore) vs. Elixir's UTF-8 aware `String.split`; significantly faster on large files.

---

## New Features

### Daemon Mode (`lib/instantgrep/daemon.ex` — new file)

A persistent Unix-socket search server that loads the index once and serves repeated queries with zero cold-start cost.

**Key behaviour:**
- Starts with `instantgrep --daemon <path>` (fork with `& disown` or systemd).
- Loads or builds the index at startup, then pre-loads all file content into a RAM cache (`build_content_cache/1`) — eliminates all `File.read` I/O per search.
- Binds a Unix domain socket at `<path>/.instantgrep/daemon.sock`.
- Writes PID to `<path>/.instantgrep/daemon.pid` for `--stop` support.
- Accepts concurrent connections; each query runs in its own `Task`.
- Ignores `SIGHUP` to survive terminal close.

**Wire protocol (line-oriented):**
```
Client → Server:  <pattern>\t<0|1>\n        (0=case-sensitive, 1=ignore-case)
Server → Client:  <file>:<line>:<content>\n  (one per match)
                  \DONE\t<ms>\t<candidates>\t<matches>\n
                  \ERROR\t<message>\n
```

**Search fast-paths** (ordered by speed):
1. `:literal` — no regex metacharacters → `:binary.matches(content, pattern)` (Boyer-Moore NIF)
2. `{:alts, list}` — pure `A|B|C` alternation of literals → `:binary.matches(content, [list])`
3. `:regex` — fallback to `:re.run(content, compiled_re, [:global, capture: :first])` (PCRE)

All paths use a **pre-computed newline offset tuple** (built once at cache load time) and **binary search** (`bisect/4`) for O(log N) line number resolution — no per-line scanning.

**Performance vs rg:**
- ig wins on patterns ≥ ~15 characters found in few files (trigram index prunes to 1–10 candidates out of many thousands):
  - Long rare identifiers → **4–6ms** vs rg's 99–126ms (**20–23× faster**)
- rg wins on broad patterns (`"#include"`, `"nullptr"`) where the index has low selectivity and rg's SIMD scan dominates.

### Thin Python Client (`ig.py` — new file)

A 184-line Python 3 script that connects to the daemon socket directly, **bypassing BEAM VM startup (~3s per invocation)**.

```bash
python3 ig.py "some_rare_identifier" /path/to/codebase/
python3 ig.py -i "TODO" .
python3 ig.py --time "pattern"
```

- Falls back to the full `instantgrep` escript if no daemon is running (with a warning).
- Streams results directly to stdout via `os.write(stdout_fd, ...)` — avoids Python `print()` overhead per line.
- Supports `-i`/`--ignore-case`, `-t`/`--time`, `-h`/`--help`.
- Resolves path from CLI arg → `IG_PATH` env var → `$CWD`.

### `--daemon` / `--stop` CLI flags (`cli.ex`)

- `--daemon <path>` starts the daemon (delegates to `Daemon.start/1`).
- `--stop <path>` sends `SIGTERM` to the PID file and removes the socket.
- `execute_indexed` now **auto-detects a running daemon** and routes queries through it; falls back to direct index load on `{:error, _}`.
- Positional argument parsing fixed: for `--build`, `--stats`, `--daemon`, `--stop`, the first positional is the **directory** (not the pattern).

### `--time` Flag (`cli.ex`)

Prints a per-phase timing breakdown to stderr after each search:

```
--- timing (pattern: "my_pattern") ---
  index load:       10.678s
  trigram eval:     108.49ms  (617/1884 files candidates)
  regex verify:     2.151s    (1602 matches)
  total (in VM):    12.937s
```

When used via daemon, reports `index load: 0ms` and includes the daemon's internal elapsed time.

---

## Bug Fixes

| # | File | Description |
|---|------|-------------|
| 1 | `cli.ex` | `--build`/`--stats` treated the directory path as the search pattern. Fixed by checking the `build \|\| stats \|\| daemon \|\| stop` flag before splitting positional arguments. |
| 2 | `query.ex` | `evaluate_masked` used `first_byte` of the next trigram to check `next_mask`, but `next_mask` stores a bit for `char_at_pos+3` = **last byte** of the next overlapping trigram. Fix: `<<_, _, last_byte>> = trigram`. This caused false negatives (e.g. `"nullptr"` returning 0 results). |
| 3 | `scanner.ex` | `File.ls!` raised `File.Error` on permission-denied subdirectories, crashing the parallel scanner. Fixed to `File.ls` with `{:error, _} -> []`. |
| 4 | `scanner.ex` | Nested `Task.async_stream` (root task spawning child tasks) triggered the default 5s timeout. Fixed by splitting into `do_scan_parallel` (root, `timeout: :infinity`) and `do_scan` (fully sequential recursion). |

---

## Index Format Changes

| Version | Format | Notes |
|---------|--------|-------|
| ≤3 | Single `postings.dat` (uncompressed) | Incompatible — triggers automatic rebuild |
| **4** | `meta.dat` + `files.dat` + `postings_0.dat` … `postings_N.dat` (compressed) | Current |

Indexes built with an older format version are automatically detected and rebuilt on next use.

---

## File Summary

| File | Change |
|------|--------|
| `lib/instantgrep/index.ex` | ETS sharding, `lookup_with_masks`, `binary?`, format v4 save/load, parallel shard I/O |
| `lib/instantgrep/query.ex` | `evaluate_masked/2`, bloom-filter last-byte bug fix |
| `lib/instantgrep/cli.ex` | `--daemon`, `--stop`, `--time`, auto-daemon fallback, positional arg fix |
| `lib/instantgrep/scanner.ex` | Parallel root scan, `File.ls` safety, `binary_content?` removal |
| `lib/instantgrep/matcher.ex` | `:binary.split` instead of `String.split` |
| `lib/instantgrep/bench.ex` | Uses `evaluate_masked` + `lookup_with_masks` |
| `lib/instantgrep/daemon.ex` | **New** — Unix socket daemon with content cache and fast-path matching |
| `ig.py` | **New** — Python thin client (zero BEAM startup overhead) |

---

## Performance & Correctness — Round 2

All changes below are relative to commit `2cfbc7d` (*Add --update option for incremental index updates*).

---

### 7. C NIF for Trigram Extraction — −26% CPU, −56% syscalls (`c_src/`, `lib/instantgrep/native.ex`, `index.ex`)

Added `extract_trigrams_nif/1` to the existing PCRE2 NIF (`c_src/instantgrep_native.c`).

- **Algorithm**: single-pass open-addressing hash table (linear probing, power-of-2 capacity, 50% max load factor) over the raw byte array. Per-trigram cost is 3 integer reads + 1 hash probe — no heap allocation, no GC pressure.
- **Key encoding**: trigrams stored as 24-bit integers (`byte0<<16 | byte1<<8 | byte2`). Integer keys are immediate BEAM values — ETS lookup and `phash2` routing require zero binary allocation.
- **Returns** `[{trigram_int, next_mask, loc_mask}]` — same semantics as `Trigram.extract_with_masks/1` but as a flat list of 3-tuples instead of a map.
- Declared **non-dirty** (`flags: 0`): average file size on the target codebase is ~26 KB, worst-case NIF execution ~500 µs — well inside the safe non-preemptible window. Using `ERL_NIF_DIRTY_JOB_CPU_BOUND` added ~200 µs dispatcher overhead per file, causing a net regression.
- `lib/instantgrep/native.ex` exposes `extract_trigrams/1` with a transparent Elixir fallback to `Trigram.extract_with_masks/1` when the NIF is not loaded.
- **Result on example codebase (1884 files, 50 MB)**: build time `10.83s → 9.47s` (−12% wall clock), CPU `2m8s → 1m29s` (−26%), sys `4.5s → 2.0s` (−56%).

### 8. Integer Trigram Keys in `extract_with_masks` (`trigram.ex`)

- Old: `binary_part(binary, pos, 3)` — allocates a 3-byte heap binary per loop iteration. For a 100 KB file this is ~100K heap allocations + GC.
- New: `:binary.at/2` (returns an integer, zero allocation). Key = `a * 65536 + b * 256 + c` — a small integer, an immediate BEAM value.
- `Map.update` on integer keys uses integer comparison instead of binary hash + memcmp.
- Return type of `extract_with_masks/1` changed from `%{binary => {mask, mask}}` to `%{integer => {mask, mask}}` (format version bumped to 5 to invalidate old on-disk indexes).

### 9. `file_metas` Collection Merged into Extraction Pass (`index.ex`)

- Old: `Stream.run()` on the extraction `Task.async_stream`, then a **separate sequential** `Enum.flat_map` issuing one `File.stat` per file — O(N) sequential syscalls after the parallel phase.
- New: each extraction worker calls `File.stat` for its own file and returns the stat entry as its result value. The `Enum.flat_map` over the already-parallel stream collects metas at zero extra cost.
- Eliminates one full sequential sweep of all indexed files after every `build` and `update`.

### 10. Parallel `count_unique_keys` (`index.ex`)

- Old: `Enum.map(&count_unique_keys/1)` — counted each shard's unique trigrams sequentially.
- New: `Task.async_stream(&count_unique_keys/1, ordered: false, timeout: :infinity)` — all N shards counted concurrently.
- On a 16-core machine with 16 shards this is a ~5× speedup for the count phase (confirmed: 41ms → 8ms).

### 11. Removed Redundant Per-Directory Sort in Scanner (`scanner.ex`)

- Old: `do_scan` called `Enum.sort()` on the file list returned from every directory recursion, then `do_scan_parallel` sorted the combined list again at the top level. For a tree M levels deep total sort work was O(N log N × M).
- New: intermediate per-directory sorts removed; a single `Enum.sort()` at the top of `do_scan_parallel` produces the same deterministic file ordering at O(N log N) total cost.

### 12. `save/2` Compression Level 6 → 1 (`index.ex`)

- `:erlang.term_to_binary(data, [:compressed])` uses zlib level 6 by default — good compression ratio but slow to write.
- Changed to `[{:compressed, 1}]` (zlib fastest) — ~3× faster write speed at ~10–15% larger files on disk.

### 13. `save/2` and `load/1` Timeout: `120_000` → `:infinity` (`index.ex`)

- `Task.await` in `save/2` had a hardcoded 120-second ceiling. For a large codebase (e.g. 195K files), writing `file_metas.dat` after the shard files could hit the limit, leaving `file_metas.dat` absent on disk.
- `Task.async_stream` in `load/1` had the same 120s limit — caused the reported `** (exit) exited in: Task.Supervised.stream(120000)` crash on `--update` for large codebases.
- Both changed to `:infinity`.

### 14. Daemon Stale-Index Detection (`daemon.ex`)

- Old: `{:ok, idx} ->` branch always used a loaded index regardless of whether `file_metas` was populated — if `file_metas.dat` was missing (e.g. after the 120s timeout bug), the daemon served the index without ever writing it, making `--update` permanently broken.
- New: pattern-matches on `file_metas` size: `{:ok, %Index{file_metas: metas} = idx} when map_size(metas) > 0` serves the cached index; a zero-meta index triggers a full rebuild + save.

### 15. Daemon Uses PCRE2-JIT NIF for Search (`daemon.ex`)

- Old: `daemon.ex` used `:re.compile` / `:re.run` (PCRE1, no JIT) for all search requests.
- New: uses `Native.compile_pattern/2` / `Native.scan_content/2` — routes through the PCRE2-JIT NIF where available, falling back to `:re` automatically.

---

## Index Format Changes (updated)

| Version | Format | Notes |
|---------|--------|-------|
| ≤3 | Single `postings.dat` (uncompressed) | Incompatible — triggers automatic rebuild |
| 4 | `meta.dat` + `files.dat` + `postings_0.dat` … `postings_N.dat` (zlib level 6) | Superseded |
| **5** | Same layout, integer trigram keys, zlib level 1 | Current |

---

## File Summary (updated)

| File | Change |
|------|--------|
| `lib/instantgrep/index.ex` | ETS sharding, `lookup_with_masks`, `binary?`, format v5 save/load, parallel shard I/O, NIF extraction, merged stat pass, parallel count, `:infinity` timeouts, fast compression |
| `lib/instantgrep/query.ex` | `evaluate_masked/2`, bloom-filter last-byte bug fix |
| `lib/instantgrep/cli.ex` | `--daemon`, `--stop`, `--time`, auto-daemon fallback, positional arg fix |
| `lib/instantgrep/scanner.ex` | Parallel root scan, `File.ls` safety, `binary_content?` removal, single top-level sort |
| `lib/instantgrep/matcher.ex` | `:binary.split` instead of `String.split` |
| `lib/instantgrep/bench.ex` | Uses `evaluate_masked` + `lookup_with_masks` |
| `lib/instantgrep/trigram.ex` | Integer trigram keys in `extract_with_masks/1` |
| `lib/instantgrep/daemon.ex` | Unix socket daemon; PCRE2-JIT NIF search; stale index detection |
| `lib/instantgrep/native.ex` | **New** — `extract_trigrams/1`, `compile_pattern/2`, `scan_content/2` wrappers with NIF + Elixir fallback |
| `c_src/instantgrep_native.c` | **New** — PCRE2-JIT NIF + `extract_trigrams_nif` (open-addressing hash table) |
| `Makefile` | **New** — NIF build rules (`make all` / `make clean`) |
| `build.sh` | Updated — added `make all` step before `mix compile` to build the PCRE2-JIT NIF |
| `ig.py` | **New** — Python thin client (zero BEAM startup overhead) |
