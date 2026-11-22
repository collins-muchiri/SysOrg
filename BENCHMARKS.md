# SysOrg Benchmarks (v3.0)

All claims in the v3.0 work are measured against the numbers in this file. Every number
comes from `SysOrg.ps1 -Benchmark` on the synthetic corpus produced by
`Tools/New-SysOrgCorpus.ps1` (deterministic, seed 42) - identical inputs produce
byte-identical corpora, so runs are reproducible.

## Measurement environment (read this first)

| Item | Value |
|------|-------|
| OS / runtime | Linux container, PowerShell 7.7.0 (the portable pwsh build in this sandbox) |
| Hardware | 2 vCPU, 4 GB RAM, single logical volume |
| Corpus | **20,000 unique files** + 5% exact duplicates (1,000 copies, padded to >= 300 KB) |
| Peak memory | Process-wide PeakWorkingSet64 sampled after each step - cumulative by nature, not per-step |

**Honest deviations from the task spec:**

1. The task asks for a 100,000-file corpus baseline. This sandbox has 2 cores, 4 GB RAM
   and ~6 GB free disk; a 100k corpus (several GB plus its organized copy) does not fit.
   The baseline below uses **20,000 files**. `Tools/New-SysOrgCorpus.ps1` itself defaults
   to `-FileCount 100000` as specified; `-Benchmark` accepts `-BenchmarkFiles` to size the
   run. Relative speedups (Phase 3) are claimed only on identical corpus + hardware.
2. Windows PowerShell 5.1 is not runnable here (Linux host). Timings on Windows will
   differ; the ratios are what the design targets. All behaviour is written for 5.1
   compatibility and CI still runs the full suite on `windows-latest` for both runtimes.
3. Everything in this sandbox is one volume, so execute moves are same-volume atomic
   renames; cross-volume (copy + hash + verify) execute timing is NOT measured here.

## Baseline - v2.1.1 code, v2.1 layout (Phase 0, recorded 2026-11-22)

Corpus: 20k unique + 1,000 duplicate copies = 21,002 files scanned; 919 duplicate groups;
1,881 plan actions (most corpus directories are "already organized" per the v2.1
preservation heuristic, so few files are planned - see note on the score below).

| Step | Seconds | Peak WS (MB) |
|------|---------|--------------|
| corpus-generate | 91.811 | 591.2 |
| cold-scan (no cache) | **3.809** | 654.9 |
| warm-scan (JSON inventory cache hit) | **0.279** | 723.6 |
| duplicate-detect (size -> 64 KB header -> full SHA256) | **2.317** | 812.9 |
| plan-build | **8.752** | 820.0 |
| execute-plan (1,881 same-volume moves, journal per row) | **8.971** | 987.2 |

Phase 3 targets on this corpus and hardware: warm rescan >= 3x faster (<= 0.093 s via the
persistent file-state cache path), cold plan-build >= 2x faster (<= 4.376 s), execute
>= 2x faster (<= 4.486 s). Report the real numbers either way.

## Baseline findability score - v2.1 layout (Phase 0.3)

`Get-SysOrgFindabilityScore` over the executed v2.1 destination tree
(`/tmp/bench-corpus/_Organized`, 1,881 moved files, 100 folders):

| Metric | v2.1 layout | Config target |
|--------|-------------|---------------|
| Score (0-100) | **74.4** | >= 85 for the Findable layout (aspirational) |
| Avg depth / browse-distance (folder opens) | 2.69 | <= 3.0 |
| Max depth | 3 | <= 4 |
| Files per folder p50 / p90 / p99 | 2 / 3 / **310** | p99 bounded by MaxFilesPerFolder (150) |
| Subfolders per folder p50 / p90 | 10 / 24 | top-level <= 10 (Findable) |
| Files in over-cap folders (>150) | **78.4%** | <= 5% |
| Files in near-empty folders (<8) | 10.5% | <= 10% |
| Confidence shares / dup byte share | n/a in v2.1 (no Decision records); dup share measured per run | confident >= 80% |

The headline: **78% of organized files sit in folders that exceed the 150-file cap**
(the p99 folder holds 310 files). This is the concrete problem the Findable layout's
adaptive date granularity fixes.

Note: only the 1,881 planned files are scored above; the ~19k files the v2.1
preservation heuristic left in already-organized directories are not part of the
destination tree. The Findable-layout comparison in Phase 5 uses the same corpus and
the same scoring function over its own destination tree.

## Final - v3.0 (to be filled after Phase 3 / Phase 5)

TBD - filled with the same corpus, same seed, same machine, same scoring function.
