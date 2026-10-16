# Further algorithmic optimization (October 16, 2026)

Two later runs of this source measured the standard 100-ticket case at 13.72
and 12.44 ms, close to the 13.42 ms recorded here. The tables below are the
original round-two results, before forward-page discovery was added. See the [latest results](README.md#latest-results)
and [saved comparison](recheck-20261016-170742/comparison.json) for the reruns.

Comparison point: the previous optimized standard 100-ticket scan at 82.469 ms. The final unchanged-source confirmation measured 13.420 ms, 6.14 times faster. Host timing varies; see raw JSON for samples.

## Algorithm changes

- **Bounded search pruning:** adding members cannot reduce the built-in nonnegative rule penalty. Compare that lower bound, exact accumulated queue time, and exact lexicographic extension order against a full beam bucket before checking compatibility, scoring or allocating. Discard only proposals that cannot enter the existing best-eight bucket. No reduction in beam width or early first-match shortcut. Arbitrary custom scorers bypass these bounds.
- **Scan-local compatibility summaries:** validate each ticket and evaluate relaxation schedules once per scan. Numeric cross-party maximum distance uses opposing extrema; equality uses a representative and mixed-party flag. Category matrices retain cross-member checks. Fresh-player limits apply to cross-party distances, not the older party's internal diameter.
- **Incremental sufficient statistics:** beam states carry numeric extrema and equality flags for active preferences. Appending a ticket updates scores in O(active fields), replacing repeated O(active fields × group members) rescans. Accumulate weighted penalties in the original sorted field order and queue times in original ticket order. Arbitrary string-distance preferences use the general scorer. Only retained proposals copy indexes and score summaries.
- **Prove dense compatibility once:** a conservative scan-wide envelope can certify that all valid tickets are mutually compatible. Then the beam needs no member-pair walk. If the proof fails, normal exact pair checks apply. Invalid tickets remain excluded.
- Preparation is scoped to one Matcher.select call, so mutation, new arrivals and changed queue ages are reevaluated on the next scan. Weak metadata registries recognize only built-in scorer/pair functions and avoid retaining destroyed queues.

## Profile evidence

The sandbox profiler instruments a loaded source copy, with production files unchanged. Times include instrumentation overhead and are not benchmark medians. Before/final counters for the same standard 100-ticket fixture:

| Work | Previous | Final |
|---|---:|---:|
| Beam states visited | 29,364 | 29,364 |
| Full or incremental score evaluations | 29,364 | 4,483 |
| Index copies | 29,364 | 2,160 |
| Insertion comparisons | 35,119 | 7,915 |
| Pair-cache probes | 130,204 | 1,360 |
| Uncached pair evaluations | 5,024 | 766 |

Beam states still visited: 29,364. The optimization removes expensive work inside the search; it does not claim a new asymptotic bound for the whole beam search. A previous profile found roughly 39–41% of instrumented time in scoring.

## All pure matcher medians (ms)

| Scenario | Tickets | Seats | Party | Previous | Bound pruning | Summaries + incremental | Dense proof | Final confirmation | Speedup vs previous |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| compatible | 8 | 8 | 1 | 0.468 | 0.311 | 0.251 | 0.205 | 0.153 | 3.06x |
| mixed | 8 | 8 | 1 | 0.127 | 0.081 | 0.070 | 0.103 | 0.070 | 1.81x |
| incompatible | 8 | 8 | 1 | 0.153 | 0.087 | 0.069 | 0.071 | 0.074 | 2.07x |
| near-fill | 8 | 8 | 1 | 0.186 | 0.090 | 0.073 | 0.078 | 0.074 | 2.50x |
| constraints | 8 | 8 | 1 | 0.430 | 0.195 | 0.169 | 0.138 | 0.130 | 3.32x |
| compatible | 16 | 8 | 1 | 2.918 | 1.281 | 0.958 | 0.689 | 0.622 | 4.69x |
| mixed | 16 | 8 | 1 | 0.653 | 0.581 | 0.426 | 0.470 | 0.419 | 1.56x |
| incompatible | 16 | 8 | 1 | 0.392 | 0.511 | 0.198 | 0.195 | 0.203 | 1.93x |
| near-fill | 16 | 8 | 1 | 0.269 | 0.480 | 0.189 | 0.194 | 0.191 | 1.41x |
| constraints | 16 | 8 | 1 | 1.441 | 1.193 | 0.607 | 0.433 | 0.434 | 3.32x |
| compatible | 25 | 8 | 1 | 6.882 | 3.018 | 2.064 | 1.591 | 1.637 | 4.20x |
| mixed | 25 | 8 | 1 | 2.546 | 1.529 | 1.154 | 1.390 | 1.144 | 2.23x |
| incompatible | 25 | 8 | 1 | 1.328 | 0.764 | 0.452 | 0.564 | 0.508 | 2.61x |
| near-fill | 25 | 8 | 1 | 0.625 | 0.592 | 0.399 | 0.666 | 0.413 | 1.51x |
| constraints | 25 | 8 | 1 | 4.273 | 1.429 | 1.189 | 0.885 | 0.856 | 4.99x |
| compatible | 50 | 8 | 1 | 20.128 | 8.639 | 6.489 | 4.699 | 4.276 | 4.71x |
| mixed | 50 | 8 | 1 | 10.291 | 5.910 | 4.393 | 4.807 | 4.588 | 2.24x |
| incompatible | 50 | 8 | 1 | 3.266 | 2.989 | 1.634 | 1.655 | 1.718 | 1.90x |
| near-fill | 50 | 8 | 1 | 2.759 | 2.050 | 1.477 | 1.486 | 1.470 | 1.88x |
| constraints | 50 | 8 | 1 | 38.070 | 4.039 | 3.702 | 3.211 | 3.165 | 12.03x |
| compatible | 75 | 8 | 1 | 81.574 | 16.753 | 13.500 | 11.598 | 7.810 | 10.45x |
| mixed | 75 | 8 | 1 | 34.542 | 13.149 | 8.716 | 9.582 | 8.252 | 4.19x |
| incompatible | 75 | 8 | 1 | 8.625 | 6.854 | 3.887 | 3.913 | 3.767 | 2.29x |
| near-fill | 75 | 8 | 1 | 4.682 | 4.700 | 3.350 | 3.101 | 3.238 | 1.45x |
| constraints | 75 | 8 | 1 | 39.810 | 7.981 | 7.840 | 6.102 | 6.088 | 6.54x |
| compatible | 100 | 8 | 1 | 82.469 | 23.984 | 18.864 | 15.569 | 13.420 | 6.14x |
| mixed | 100 | 8 | 1 | 42.918 | 18.253 | 13.170 | 14.496 | 13.482 | 3.18x |
| incompatible | 100 | 8 | 1 | 12.664 | 11.960 | 6.520 | 6.492 | 6.491 | 1.95x |
| near-fill | 100 | 8 | 1 | 8.398 | 7.853 | 5.999 | 6.081 | 5.540 | 1.52x |
| constraints | 100 | 8 | 1 | 56.243 | 12.876 | 11.853 | 10.880 | 10.165 | 5.53x |
| large-match | 25 | 16 | 1 | 9.702 | 3.904 | 3.005 | 1.991 | 1.701 | 5.70x |
| large-match | 50 | 16 | 1 | 37.185 | 13.722 | 10.167 | 6.320 | 5.839 | 6.37x |
| large-match | 100 | 16 | 1 | 187.343 | 37.714 | 28.072 | 20.586 | 18.474 | 10.14x |
| large-match | 25 | 32 | 1 | 0.960 | 0.853 | 0.484 | 0.584 | 0.372 | 2.58x |
| large-match | 50 | 32 | 1 | 56.452 | 17.824 | 12.489 | 8.030 | 6.979 | 8.09x |
| large-match | 100 | 32 | 1 | 269.098 | 61.511 | 43.879 | 31.692 | 26.074 | 10.32x |
| parties | 25 | 8 | 2 | 4.422 | 3.105 | 1.370 | 1.143 | 1.016 | 4.35x |
| parties | 50 | 8 | 2 | 18.681 | 9.691 | 4.212 | 3.210 | 2.975 | 6.28x |
| parties | 100 | 8 | 2 | 75.143 | 27.898 | 11.835 | 9.579 | 8.997 | 8.35x |
| parties | 25 | 8 | 4 | 4.664 | 4.354 | 0.981 | 1.018 | 0.944 | 4.94x |
| parties | 50 | 8 | 4 | 17.285 | 16.083 | 2.599 | 2.273 | 2.233 | 7.74x |
| parties | 100 | 8 | 4 | 65.999 | 60.719 | 6.876 | 5.929 | 5.808 | 11.36x |
| sixteen-rules | 100 | 8 | 1 | 407.407 | 287.202 | 90.392 | 70.261 | 64.968 | 6.27x |
| legacy | 100 | 8 | 1 | 0.291 | 0.254 | 0.306 | 0.338 | 0.315 | 0.92x |

## Queue scan medians (ms)

| Burst players | Previous | Final | Speedup |
|---|---:|---:|---:|
| 100 | 2.976 | 1.318 | 2.26x |
| 1000 | 83.640 | 14.550 | 5.75x |
| 5000 | 91.617 | 19.698 | 4.65x |

## Validation and boundaries

- Full Lune test suite: 524 passed, zero failures/crashes.
- Expanded differential verifier: 2,400 exact reference scores, 1,188 incremental scores, 28,210 prepared pair comparisons, and 276 exact ordered match selections against original pre-optimization sources. Includes matrix preferences, numeric/equality preferences, differing party sizes, waits, fallback, and fractional/zero weights. Additional regression cases cover unequal fresh/old windows, invalid tickets, changed inputs between scans, and custom decreasing scorers.
- Every saved 44-case run preserves match counts; burst virtual waits/drains and arrival backlogs are unchanged.
- Selene, StyLua, luau-lsp and git whitespace checks pass.
- Timed benchmark uses actual shipped source in the existing @lune/luau sandbox. Adaptive 3–9 samples after warmup, no IO latency/throttling; final confirmation follows the full test suite without concurrent test work. Host noise and a small sample size limit precision.
- The benchmark's existing policy-wrapper counters force a general callback path, so they do not represent optimized internal work. Use profile.luau counters for that. This distinction is now documented in benchmark method metadata.
- The oldest-100 discovery window, single lane, beam width, preferences and tie breaking are unchanged. The blocked-head fixture still hides eight compatible players. Incompatible scans improve through preparation but remain quadratic in visible ticket pairs. No production server capacity claim.

## Reproduce

```powershell
lune run test/run
lune run bench/optimization/verify
lune run bench/optimization/profile bench/optimization/profile-current.json
lune run bench/optimization/profile bench/optimization/profile-previous.json bench/optimization/Matcher.round2-baseline.luau
lune run bench/attributes
```

Raw JSON, source snapshots, final O2 bytecode and source/compiler/host metadata are in this directory. `round2-final.json` is the final confirmation; `round2-baseline.json` preserves the previous answer's run. Original earlier results remain in `prior.json`, `baseline.json`, and `final.json`.
