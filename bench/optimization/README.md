# Attribute matcher benchmarks and optimization

The tables under "Round one" record an earlier version. The later algorithm
changes are in [ROUND2.md](ROUND2.md). This section covers the two latest reruns.

## Latest results

The standard 100-ticket, eight-player case measured **13.72 and 12.44 ms**,
compared with 171.97 ms before optimization. That agrees with the previous
optimized run at 13.42 ms.

| Fixture (100 tickets) | Original median | New medians, two runs |
| --- | ---: | ---: |
| Four rules, 8-player matches | 171.97 ms | 12.44-13.72 ms |
| Hard constraints only | 132.20 ms | 9.89-11.28 ms |
| Four rules, 32-player matches | 884.29 ms | 27.19-35.64 ms |
| Sixteen rules, 8-player matches | 798.27 ms | 61.53-62.00 ms |
| Four-person parties, 8-player matches | 80.66 ms | 5.40-5.82 ms |

These ranges are the two run medians, not confidence intervals. The mixed
boolean fixture varied more: 12.58-28.27 ms. Both runs used Windows, a Ryzen 5
7600X and Lune 0.10.5, with 3-9 measured samples after warmup. The timings use
the built-in policy directly. Callback counters wrap that policy and take the
general path; use `profile.luau` for optimized internal counts. Profiling times
include the cost of the instrumentation.

All 44 fixture match counts, burst drain times and arrival backlogs stayed the
same. The differential verifier passed 2,400 reference scores, 1,188 incremental
scores, 28,210 prepared pairs and 276 ordered selections, plus edge cases. This
is test coverage, not a proof for every input. The full suite last recorded
524 passing checks during optimization; it was not rerun for these two benches.

The blocked-head result below describes the earlier discovery loop. Rule queues
now alternate oldest-first reads with overlapping forward pages, using at most
100 requested entries and two range calls per scan. See the
[README](../../README.md#attribute-matching-performance) and
[latest results](../attributes-results.json) for that change. The saved reruns in
this directory remain historical; their zero-match result has not been rewritten.

The simulation omits backend latency and quotas, and its clock excludes CPU
time. The original 50-ticket CPU warning is outdated for the standard fixture.

Saved results: [prior run](recheck-20261016-170742/prior.json),
[first rerun](recheck-20261016-170742/run1.json),
[confirmation](recheck-20261016-170742/run2.json),
[comparison](recheck-20261016-170742/comparison.json) and
[source hashes](recheck-20261016-170742/sources-before.json).
The historical results and snapshots below have not been changed.

## Forward discovery fix

The old blocked-head fixture was a real bug, not just a capacity warning. The
same eight players now match after 3.25 virtual seconds rather than staying
unmatched for 100 seconds. Rule queues use bounded forward pages alongside
oldest-first scans; see the [README](../../README.md#attribute-matching-performance)
for the read budget, overlap and limits. Custom stores need the optional
exclusive cursor argument on `sortedRange`.

The updated benchmark keeps all 44 pure matcher counts and the normal burst and
arrival outcomes unchanged. The standard 100-ticket case measured 12.82 ms in
this run. Forward scans can add a second range call, so actual backend costs
still need live measurements. The full suite now passes 590 checks, including
66 new checks for blocked/deep queues, page boundaries, cursors, retries and
old-player access. The differential matcher verifier also passed again.

[Latest results](../attributes-results.json) include the first-match time;
[pre-fix results](../discovery-before.json) are saved separately. Earlier runs
and their zero-match assertions remain historical evidence.

## Round one (historical)


Three measured source iterations, followed by an unchanged-source confirmation run. Original workspace source and prior benchmark results are preserved here. Existing uncommitted attribute-rule work was retained.

## Changes

1. Compile the sorted preference list once per policy; omit inactive/zero-weight preferences. Numeric maximum pair distance becomes max minus min, equality becomes a linear scan. String cost matrices retain pairwise evaluation. Keep sorted field accumulation and ticket queue-time addition order.
2. Maintain sorted best-eight beam buckets by bounded insertion. Descending positive sizes permit in-place updates without state snapshots or bucket clones. Beam width and deterministic tie breaking are unchanged.
3. Precompute anchor-compatible candidates; stop before beam expansion if their total size cannot reach the required minimum/target. This is an upper-bound rejection, not a change to match quality.

## Measurement and bytecode

Execution uses the existing test loader, which loads actual shipped source in the `@lune/luau` sandbox. Disassembly uses the local `luau-compile.exe`: preserved baseline and iteration dumps use `-O2 --text`; final dumps also include `-O1 --text`. These are standalone compiler observations, not a disassembly of the exact Lune binary or proof of Roblox native-code performance. Compiler hash, host details, and source hashes are in environment.json.

Baseline bytecode shows per-score name-table allocation and table.sort, plus nested numeric member-pair FORN loops. Iteration 1 moves sorting into scorer creation and replaces numeric pair loops with a member scan. Matcher dumps confirm snapshot clones and bucket sorts disappear from the rules path after iteration 2. Total module bytecode size is not a useful performance score: added setup/early-exit code can increase size while reducing executed work.

Timings are host-dependent medians, with 3–9 samples per case after warmup. Raw samples are retained in each JSON. The full fixture suite was rerun per iteration; final is a confirmation without concurrent test work. Machine activity and adaptive sample counts introduce noise; these are descriptive results, not confidence bounds.

## Pure matcher medians (milliseconds)

| Scenario | Tickets | Seats | Party | Prior | Fresh baseline | Iter 1 | Iter 2 | Iter 3 | Final | Baseline/final |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| compatible | 8 | 8 | 1 | 0.546 | 0.581 | 0.356 | 0.278 | 0.298 | 0.468 | 1.24x |
| mixed | 8 | 8 | 1 | 0.251 | 0.266 | 0.194 | 0.282 | 0.098 | 0.127 | 2.11x |
| incompatible | 8 | 8 | 1 | 0.100 | 0.095 | 0.086 | 0.099 | 0.087 | 0.153 | 0.62x |
| near-fill | 8 | 8 | 1 | 1.708 | 1.850 | 1.218 | 0.895 | 0.112 | 0.186 | 9.96x |
| constraints | 8 | 8 | 1 | 0.382 | 0.381 | 0.320 | 0.193 | 0.199 | 0.430 | 0.88x |
| compatible | 16 | 8 | 1 | 3.324 | 3.695 | 2.246 | 1.853 | 1.657 | 2.918 | 1.27x |
| mixed | 16 | 8 | 1 | 0.990 | 1.018 | 0.718 | 0.640 | 0.637 | 0.653 | 1.56x |
| incompatible | 16 | 8 | 1 | 0.325 | 0.346 | 0.341 | 0.343 | 0.314 | 0.392 | 0.88x |
| near-fill | 16 | 8 | 1 | 3.605 | 3.834 | 2.582 | 1.974 | 0.280 | 0.269 | 14.25x |
| constraints | 16 | 8 | 1 | 2.456 | 2.834 | 1.940 | 1.211 | 1.195 | 1.441 | 1.97x |
| compatible | 25 | 8 | 1 | 9.323 | 10.247 | 6.298 | 4.531 | 4.557 | 6.882 | 1.49x |
| mixed | 25 | 8 | 1 | 4.098 | 4.424 | 2.969 | 2.194 | 1.966 | 2.546 | 1.74x |
| incompatible | 25 | 8 | 1 | 0.766 | 0.760 | 0.772 | 0.765 | 0.760 | 1.328 | 0.57x |
| near-fill | 25 | 8 | 1 | 5.627 | 6.197 | 3.946 | 3.431 | 0.610 | 0.625 | 9.92x |
| constraints | 25 | 8 | 1 | 7.257 | 7.722 | 5.540 | 3.180 | 3.241 | 4.273 | 1.81x |
| compatible | 50 | 8 | 1 | 41.235 | 45.944 | 29.404 | 22.228 | 18.374 | 20.128 | 2.28x |
| mixed | 50 | 8 | 1 | 19.714 | 20.809 | 13.580 | 12.238 | 10.315 | 10.291 | 2.02x |
| incompatible | 50 | 8 | 1 | 3.383 | 3.498 | 3.113 | 3.420 | 3.727 | 3.266 | 1.07x |
| near-fill | 50 | 8 | 1 | 15.052 | 14.820 | 9.785 | 9.047 | 2.228 | 2.759 | 5.37x |
| constraints | 50 | 8 | 1 | 31.799 | 34.485 | 24.764 | 13.130 | 14.175 | 38.070 | 0.91x |
| compatible | 75 | 8 | 1 | 95.517 | 104.607 | 70.500 | 50.993 | 52.182 | 81.574 | 1.28x |
| mixed | 75 | 8 | 1 | 47.047 | 51.926 | 34.023 | 57.538 | 22.976 | 34.542 | 1.50x |
| incompatible | 75 | 8 | 1 | 6.606 | 7.016 | 7.103 | 10.305 | 7.560 | 8.625 | 0.81x |
| near-fill | 75 | 8 | 1 | 21.487 | 23.156 | 15.948 | 19.373 | 4.906 | 4.682 | 4.95x |
| constraints | 75 | 8 | 1 | 73.171 | 82.940 | 57.003 | 44.438 | 33.485 | 39.810 | 2.08x |
| compatible | 100 | 8 | 1 | 171.973 | 188.511 | 123.440 | 93.257 | 81.255 | 82.469 | 2.29x |
| mixed | 100 | 8 | 1 | 84.448 | 93.024 | 59.684 | 51.214 | 41.295 | 42.918 | 2.17x |
| incompatible | 100 | 8 | 1 | 11.726 | 12.909 | 12.115 | 15.467 | 13.121 | 12.664 | 1.02x |
| near-fill | 100 | 8 | 1 | 30.796 | 34.306 | 23.818 | 25.655 | 9.397 | 8.398 | 4.09x |
| constraints | 100 | 8 | 1 | 132.196 | 146.797 | 104.444 | 54.180 | 58.456 | 56.243 | 2.61x |
| large-match | 25 | 16 | 1 | 23.714 | 26.074 | 14.057 | 10.814 | 7.477 | 9.702 | 2.69x |
| large-match | 50 | 16 | 1 | 83.168 | 95.841 | 49.230 | 33.908 | 33.406 | 37.185 | 2.58x |
| large-match | 100 | 16 | 1 | 353.296 | 391.701 | 200.668 | 138.810 | 149.563 | 187.343 | 2.09x |
| large-match | 25 | 32 | 1 | 659.956 | 772.346 | 299.263 | 220.683 | 0.923 | 0.960 | 804.28x |
| large-match | 50 | 32 | 1 | 326.785 | 380.885 | 151.376 | 108.710 | 53.848 | 56.452 | 6.75x |
| large-match | 100 | 32 | 1 | 884.287 | 970.252 | 333.986 | 243.976 | 256.711 | 269.098 | 3.61x |
| parties | 25 | 8 | 2 | 8.196 | 8.983 | 5.704 | 4.383 | 5.343 | 4.422 | 2.03x |
| parties | 50 | 8 | 2 | 35.169 | 39.145 | 24.391 | 18.178 | 23.807 | 18.681 | 2.10x |
| parties | 100 | 8 | 2 | 149.173 | 165.736 | 104.161 | 74.305 | 88.726 | 75.143 | 2.21x |
| parties | 25 | 8 | 4 | 5.185 | 5.663 | 4.931 | 4.848 | 4.584 | 4.664 | 1.21x |
| parties | 50 | 8 | 4 | 23.170 | 22.043 | 22.201 | 17.885 | 18.444 | 17.285 | 1.28x |
| parties | 100 | 8 | 4 | 80.662 | 88.903 | 76.493 | 68.238 | 75.118 | 65.999 | 1.35x |
| sixteen-rules | 100 | 8 | 1 | 798.271 | 877.696 | 436.900 | 420.596 | 459.335 | 407.407 | 2.15x |
| legacy | 100 | 8 | 1 | 0.301 | 0.319 | 0.378 | 0.265 | 0.292 | 0.291 | 1.10x |

## Queue scan medians (milliseconds)

| Burst players | Prior | Baseline | Final | Baseline/final |
|---|---:|---:|---:|---:|
| 100 | 7.896 | 6.940 | 2.976 | 2.33x |
| 1000 | 185.709 | 203.443 | 83.640 | 2.43x |
| 5000 | 196.130 | 225.353 | 91.617 | 2.46x |

## Verification and limits

- Full Lune suite: 524 passed, 0 failed, 0 crashed.
- `lune run bench/optimization/verify`: 2,400 exact score comparisons and 276 exact ordered match-selection comparisons against preserved baseline source. Includes numeric/equality/string matrix rules, zero weights, fractional weights, relaxation, fallback, dense queues and indivisible parties. This is broad differential evidence, not exhaustive equivalence proof.
- All 44 benchmark fixtures preserve matched counts; burst wait/drain outcomes and arrival backlogs are unchanged across all saved runs.
- Selene, StyLua, luau-lsp analysis, Wally package listing and git whitespace checks pass.
- Single lane, beam width 8, oldest-visible 100-ticket limit remain unchanged. The hidden compatible group behind 100 incompatible tickets still makes zero matches after 393 scans.
- Incompatible queues mostly spend their time on pair validation and show little improvement. Some small fixtures fluctuate or regress; inspect raw samples.
- InMemory has no real backend latency/throttling; virtual queue time excludes CPU duration. No production throughput or Roblox-server CPU claim is implied.

## Reproduce

Run from repository root:

```powershell
lune run test/run
lune run bench/optimization/verify
lune run bench/attributes
```

The benchmark writes bench/attributes-results.json. Archived JSON files here remain unchanged. verify.luau loads the preserved baseline sources directly; do not update those snapshots when changing production code. Iteration source snapshots and bytecode dumps document the measured intermediate versions.

## Follow-up optimization

See [ROUND2.md](ROUND2.md) for the subsequent algorithmic optimization and comparisons against this round.
