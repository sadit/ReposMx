#=
Phase-1 (clustering) candidate replacement using SimilaritySearch's own parallel machinery
(DictInvertedFile + exact Jaccard, via `allknn`) instead of a hand-rolled O(bucket^2) loop.
STATUS: prototype, NOT integrated. See `qgram_oracle_clustering.jl` in this same directory for
the currently-integrated design (`AuthorConsolidation.compute_name_clusters`) this is meant to
eventually replace ONLY at phase 1 -- the oracle (`AC._name_cluster_contradiction` /
`AC._name_cluster_split`) is reused UNCHANGED here, exactly as-is from production.

## Why this exists

`compute_name_clusters`'s phase 1 is a hand-written nested loop, O(bucket^2), single-threaded (see
GitHub issue #2's performance follow-up comment) -- confirmed via a real full-93-repo rebuild that
this does not scale well (a bucket of 12,615-17,789 names costs tens of minutes on its own, even
after memoization). SimilaritySearch's `allknn`/`searchbatch` parallelize automatically across
however many Julia threads are available (verified: `Threads.@threads`-style batching inside
`allknn!`, generic across any `AbstractSearchIndex`). This file rebuilds phase-1 candidate
generation on top of that, keeping everything else (bucketing, the oracle) exactly as validated in
production.

## Design: sets, not pairwise alignment -- and why that's fine now

Earlier this session, a bag-of-q-grams (role-tagged, boundary-marked, `Set`+Jaccard) design was
tried and REJECTED as the FINAL name-matching decision: it let false positives through that the
current pairwise-alignment design (`AC._name_match_score`) correctly rejects (e.g. "MANUEL ALBERTO
CHAVEZ GONZALEZ"/"MARIA ANTONIETA CHAVEZ GONZALEZ" -- identical double surname, different given
name -- scored HIGHER via bag-Jaccard than several genuine truncation matches; verified again here
with the exact same numbers: 0.48 with enrichment, 0.43 without, both above multiple true-positive
scores). That rejection was about using it as the ONLY signal.

The point of *this* file is different: split responsibilities the way the rest of the pipeline
already does -- **phase 1 unites what's plausible (recall), the oracle divides with hard evidence
(precision)**. The Manuel/Maria case is EXACTLY what `AC._name_cluster_contradiction` already
catches (validated, unchanged, real production code) -- letting phase 1 connect them is fine as
long as the oracle still separates them afterward, which it does, because the oracle re-examines
the connected COMPONENT with its own (unchanged, exact, per-token) logic regardless of how that
component was assembled. So `enrich=true` (synthesizing a bare-initial element for every given
token) is used freely here -- it can ONLY help recall at phase 1, since anything it over-connects
is the oracle's job to undo.

The real, still-open question this file's validation targets: does bag-of-q-grams UNDER-connect
anything the current exact pairwise method catches (a recall regression at phase 1), and can the
oracle keep up with whatever (likely larger) components result?

## The stopword problem (why DictInvertedFile specifically needs DF-pruning)

A `DictInvertedFile` degrades in *performance* (not correctness) when an element's posting list
covers most of the collection -- every query touches that whole list during the merge. Within one
surname bucket, the surname's OWN q-grams are shared by (approximately) every member BY
CONSTRUCTION (that's the bucketing key) -- exactly the "stopword" pattern IR systems prune for.
`prune_stopword_elements` drops any element whose in-bucket document frequency exceeds `max_df`
before building the index. This is a performance fix only, applied per-bucket (document frequency
is a collection-relative concept) -- it does not change correctness since a saturated element
(present in nearly everyone) carries ~zero discriminating power there anyway.

## Generic index construction (the ask: keep this swappable for SearchGraph later)

`build_name_index` takes the same `Vector{Set{String}}` representation and dispatches on
`backend`. `:dictinvfile` is implemented (exact Jaccard, see `has_exact_fastpath` in
SimilaritySearch's own docs for `InvertedFile`). `:searchgraph` is a reserved, unimplemented
extension point -- trying it would need a `SemiMetric` SearchGraph can traverse (native
`Dist.Sets.Jaccard()` should work directly, since it's already a proper `Metric`) and gives up
`DictInvertedFile`'s current exactness for approximate (faster at larger scale, unvalidated) search.

## Two real bugs found and fixed while validating this (both live in THIS file)

1. **Dual-role tagging applied without real ambiguity.** The "duda" token (the one that might be a
   middle given name OR a paternal surname) is `given[end]` -- but that's only an actual ambiguity
   when `length(given) >= 2`. With `length(given) == 1` (e.g. `"Victor Torres"`, a plain "Nombre
   Apellido" record), the one given token is unambiguously a given name, never a surname candidate
   -- tagging it `:s` too polluted the surname-side set with given-name content for no reason
   (found live: this alone made `"Victor Torres"` fail to match its own full form `"Victor Manuel
   Torres De La Cruz"`, among other truncation cases). Fixed: dual-tag only fires for
   `length(given) >= 2`.
2. **`prune_stopword_elements`'s fractional `max_df` was meaningless on small buckets.** With
   `n=2`, ANY element shared by both names has `df=1.0` -- `max_df=0.5` pruned every bit of real
   signal, including the surname q-grams that are usually the entire reason two names share a
   bucket (found live: gutted a 2-member "torres" bucket to zero overlap). Fixed: skip pruning
   entirely below `min_n` (default 50) -- small buckets are cheap enough for exact search anyway,
   so there was never a performance reason to prune them.

A third gap (NOT a bug in this file) was found via the comparison this file's validation runs
against production: `AC._name_cluster_contradiction` used to skip a pair when its direct surname
score was low, instead of treating that AS the contradiction -- see the "surname mismatch" fix in
`AuthorConsolidation.jl`'s git history (committed separately, real production hardening, unrelated
to whether this file is ever integrated).

## Validation results (real 10-repo corpus, 19,543 raw names, production oracle fix applied)

### `compute_name_clusters_v2` (EVERY bucket through DictInvertedFile — superseded by the hybrid below)

- Hand-picked regression set (the same cases in `test/runtests.jl`'s `_plausibly_same_person`
  tests, re-expressed as cluster-membership checks): 0/12 failures, matching production exactly.
- End-to-end group comparison against `AC.compute_name_clusters`: 16,697 groups (v2) vs 16,625
  (production) -- 430 groups differ (down from ~3,877 before the oracle fix above). Spot-checking
  the remaining differences surfaced a THIRD, separate, still-OPEN production bug this file did
  not introduce and does not fix: two bare initials each independently matching a different
  given-name token by coincidental shared first letter (e.g. `"ARTURO REYES RAMIREZ"` vs `"R. A.
  Smith Ramírez"` -- production merges them, matching `"R."` against `"Reyes"`'s first letter and
  `"A."` against `"Arturo"`'s, entirely coincidentally, then reinforced by an exact surname match;
  this file's bag representation does NOT make the same mistake here). Filed separately -- see
  GitHub issue #3.
- **Speed: NOT a win at this scale.** 54.1s (v2) vs 44.2s (production, phase1+oracle combined) on
  the 10-repo corpus -- v2 is SLOWER here. Root cause: building a fresh `DictInvertedFile` per
  bucket has fixed overhead (allocation, batch-scheduling setup) that only pays off for large
  buckets; with 5,835 buckets and only a handful actually large, that overhead dominates for the
  many small ones.

### `compute_name_clusters_hybrid` (route by bucket size — the actual point of this file)

Bucket-size distribution on the real corpora (see this docstring's numbers below) is extremely
Pareto-skewed: on the full 93-repo corpus, buckets >= 200 are only ~1.2% of all buckets but already
account for ~99.5% of total O(size²) work. `size_threshold=200` (the default) routes only that top
slice through `DictInvertedFile`, leaving the rest on the direct loop.

- Hand-picked regression set (forced through BOTH code paths via `size_threshold=3`): 0/12
  failures.
- 10-repo corpus, `size_threshold=200` (25 of 2,566 non-trivial buckets routed to
  `DictInvertedFile`): **33.6s vs production's 43.9s -- a real ~23% speedup**, the first time this
  approach has actually won overall. 16,650 groups (hybrid) vs 16,625 (production) -- 217 differ.
- **The 217-group difference is NOT a new correctness bug** -- traced to its actual root cause by
  direct comparison, not guessed: EVERY differing pair tested (`AC._name_cluster_edge` called
  directly) returns `true` under BOTH mechanisms, and traces back to the SAME single pre-oracle
  component (a 3,815-member blob, formed by transitive chaining across many unrelated surnames --
  entirely expected and by design, see `compute_similarity_merges`'s docstring on why bucketing
  alone over-connects). That component splits into 3,150 sane final groups either way (largest
  size 8, no residual blobs) -- but which of two DIFFERENT initial graph shapes (hybrid's
  Jaccard-routed large buckets vs production's exact-everywhere) gets fed into
  `AC._name_cluster_split`'s GREEDY, ORDER- AND THRESHOLD-SENSITIVE partitioner determines the
  exact final split, and the two mechanisms hand it different shapes. This is the SAME known,
  already-documented `_name_cluster_split` limitation (see its docstring in `AuthorConsolidation.jl`
  for the precise mechanism and a concrete example: `"VCTOR H. BALTAZAR-HERNANDEZ"` /
  `"VICTOR HUGO BALTAZAR HERNANDEZ"` score `match=0.762` -- above phase-1's generous 0.5 bar, but
  below the split's strict 0.9 reconnection bar), now made visible by comparing two different
  phase-1 mechanisms feeding the same fragile downstream step -- not a defect introduced by this
  file, and not (on the evidence checked) a sign either mechanism is more "correct" in general.
- **Not yet tested on the full 93-repo corpus** -- the scale that actually motivated this file (the
  12,615-17,789-member buckets). That run was started and intentionally stopped mid-flight (not a
  failure) to prioritize investigating the 10-repo discrepancy first; re-run it before trusting the
  hybrid design at the scale that matters.

### `name_qgram_set_hashed` -- hashing q-grams to `UInt64` instead of keeping them as `String`

Tested in isolation (same bucket, same `allknn` call, only the element type changes) at both real
scales:

| bucket size (real corpus) | STRING-keyed | HASHED (UInt64)-keyed | speedup | edges identical? |
|---|---|---|---|---|
| 874 (10-repo `"hernandez"`) | 0.080s | 0.075s | ~6% | yes (1,787/1,787) |
| 17,789 (93-repo `"hernandez"`) | 20.71s | 17.87s | ~14% | yes (490,624/490,624) |

**Real, measurable, but modest speedup — grows with bucket size, doesn't replace the hybrid
size-routing above (they compose: use the hashed representation ONLY for the buckets already
being routed to `DictInvertedFile`).** No quality loss detected at either scale: the exact same set
of edges was found both ways at both sizes -- consistent with the collision-probability math
(64-bit hash space against a per-bucket vocabulary of at most a few thousand distinct tagged
q-grams; the expected number of colliding pairs is negligible long before it would ever matter in
practice). Swap `repr=name_qgram_set` for `repr=name_qgram_set_hashed` in
`bucket_edges_invfile`/`compute_name_clusters_hybrid` to use it -- `prune_stopword_elements` and
`build_name_index` are already generic over the element type, no other change needed.

### `max_df` sweep -- pruning is a correctness lever, not just a performance one

Same two buckets, same `allknn` call, this time varying `prune_stopword_elements`'s `max_df`
(1.0 = no pruning at all, since no fraction can exceed it, down to 0.5/0.25/0.1), crossed with
STRING vs HASHED. `missing`/`extra` are measured against the UNPRUNED (`max_df=1.0`) run at the
same bucket, not against each other:

| bucket | max_df | edges | vs unpruned | STRING time | HASHED time |
|---|---|---|---|---|---|
| 874 | 1.0 (none) | 25,438 | -- | 0.18s* | -- |
| 874 | 0.5 (current default) | 1,787 | -92.98%, +0 extra | 0.077s | 0.075s |
| 874 | 0.25 | 1,263 | -95.03%, +0 extra | 0.051s | 0.048s |
| 874 | 0.10 | 1,245 | -95.11%, +0 extra | 0.036s | 0.032s |
| 17,789 | 1.0 (none) | 830,482 | -- | 54.0s | -- |
| 17,789 | 0.5 (current default) | 490,624 | -44.3%, +28,246 extra | 17.6s | 18.0s |
| 17,789 | 0.25 | 357,307 | -62.4%, +44,872 extra | 9.0s | 8.9s |
| 17,789 | 0.10 | 347,699 | -63.9%, +47,658 extra | 4.6s | 4.5s |

(*compilation-dominated, first call in process.)

Two findings, in order of importance:

1. **Leaving the bucket's own literal surname unpruned (`max_df=1.0`) is not a safe, merely-slower
   baseline -- it measurably degrades quality.** Every name in a `"hernandez"` bucket shares the
   `":s"`-tagged "hernandez" q-grams by construction (that's the bucket key), so with nothing
   pruned those elements inflate Jaccard similarity for essentially every pair in the bucket alike,
   producing 3.4x more edges at the 17,789 scale than `max_df=0.5`. Since `max_df=0.5` is the
   setting already cross-validated against production's exact pairwise loop earlier in this same
   line of work (see `compute_name_clusters_hybrid` validation above), the unpruned run is the
   outlier, almost certainly the noisier and lower-precision one, not the reverse. In other words:
   `prune_stopword_elements` is load-bearing for correctness in this design, not an optional speed
   knob layered on top of an already-correct signal.
2. **Going more aggressive than the validated 0.5 default (0.25, 0.1) is a real behavior change,
   not a free speedup.** At 17,789 scale they lose 62-64% of the edges `max_df=0.5` finds *and* gain
   45-48K edges `max_df=0.5` doesn't have -- both directions are large relative to the already
   cross-validated 0.5 point. The `extra` edges are not a bug: at large `n`, `allknn`'s fixed `k=64`
   neighbor window means unpruned (or under-pruned) similarity noise can push a genuinely close
   pair's rank past the cutoff entirely, so more pruning lets previously-hidden true neighbors
   surface within the window -- consistent with the 874-bucket showing zero `extra` edges at any
   `max_df` (`k=64` out of 873 possible neighbors is a much less binding constraint at that size).
   But more aggressive pruning almost certainly also starts discarding genuinely common GIVEN-name
   q-grams (e.g. "maria", "jose"), not just the bucket's shared surname -- so the speed win at
   0.25/0.1 (2-4x faster than 0.5) would need the same exact-loop cross-validation 0.5 already got
   before it could be trusted; it is not yet validated and should not be adopted on this benchmark
   alone.
3. **The earlier hashed-vs-string speedup did not reproduce here.** At every `max_df` level STRING
   and HASHED land within noise of each other (e.g. 17.6s vs 18.0s at `max_df=0.5`, reversed from
   the ~14% HASHED win measured in isolation above). Treat that earlier isolated result as marginal
   / possibly run-to-run variance rather than a robust effect -- it doesn't change the recommendation
   (hashed is still never worse, and composes for free), just tempers confidence in its magnitude.

### Root cause: `"A. García García"` / `"ARIADNA GARCIA GARCIA"` -- and a correction to the above

A group-level cross-validation of `max_df=0.25` against production (10-repo corpus) initially
looked reassuring in aggregate (212 differing groups vs. `max_df=0.5`'s already-accepted 217), with
one flagged casualty: production correctly groups `"A. García García"`, `"García García, A."`, and
`"ARIADNA GARCIA GARCIA"` together (`_name_match_score` gives the first two a perfect
`match=1.0`), reported at the time as lost specifically by `max_df=0.25`. Tracing it down in the
`"garcia"` bucket (n=862, keyed by the literal surname) shows that read was WRONG in an important
way:

`"A."`'s and `"ARIADNA"`'s q-gram sets are almost entirely SURNAME q-grams for the compound
"garcia garcia" -- near-universal in this bucket by construction (df 51.2%-100%, since the bucket
key IS that token). The only other element either carries is the enrichment marker `"^a$:g"`
("given name starts with a"), at df=222/862=**25.8%**.

- **At `max_df=0.5`** (this file's "validated" default): every surname q-gram is pruned from both,
  leaving `"A."` with just `{"^a$:g"}`; `"ARIADNA"` keeps extra "ariadna"-only q-grams too, so
  intersection=1, union=7, Jaccard=0.143 -- **already below the 0.3 edge threshold. This pair was
  ALREADY broken at `max_df=0.5`, not a new failure introduced by 0.25.** The tuple-level
  set-diff used to hunt for "new" 0.25-only discrepancies missed this because the SAME underlying
  pair was broken at both levels, just with different collateral damage (next point) -- comparing
  whole-group tuples across two already-flawed runs can hide a shared failure.
- **At `max_df=0.25`**: 25.8% > 25%, so `"^a$:g"` gets pruned too. `"A. García García"` and its
  format-duplicate `"García García, A."` -- pruning-immune at 0.5, since two identical sets always
  agree regardless of what's pruned -- both collapse to the EMPTY set.
  `evaluate(Jaccard(), ∅, ∅) = NaN` (confirmed directly:
  `SimilaritySearch.evaluate(Dist.Sets.Jaccard(), Int[], Int[])` returns `NaN`), and `NaN >= 0.3` is
  `false` in Julia, so even that trivial duplicate pair separates too.

**Generalizes beyond this one pair.** DF-based pruning is structurally hostile to any bucket where
the bucket-defining surname is itself compound (both surname tokens ARE the bucket key, so
virtually a member's whole representation is near-universal within its own bucket) -- it hits
initials-heavy names hardest, since they carry almost no other signal. This is a weakness of the
`DictInvertedFile` + pruning design here specifically, not of production (which never prunes
anything). Since common surnames get proportionally BIGGER at 93-repo scale, expect this to bite
harder there, at both `max_df=0.5` and `0.25` -- this tempers confidence in `max_df=0.5` itself,
not only in going more aggressive than it, and reinforces not adopting either level without the
same cross-validation rigor already applied elsewhere in this file.

### Given-name-initials fingerprint enrichment (`_given_initials_fingerprint`/`_abbrev_qgrams`) -- VALIDATED, kept

A preprocessing addition orthogonal to `max_df`: synthesize a `"_^A$_^B$_..."` string from the
first letter of each given-name token (one `"^X$"` unit per token, joined/wrapped with `"_"`), then
add ITS OWN q-grams to the representation -- UNTAGGED (no `:g`/`:s` suffix; the fingerprint's own
`"_"` markers already keep it out of the tagged namespace, since a tagged element always contains
`:` and the fingerprint never does). The point: whether a given-name token is spelled out in full
or already reduced to a bare initial makes NO difference to `first(t)` -- a fully-spelled-out
record and its all-initials counterpart for the SAME person produce the IDENTICAL fingerprint,
something no per-token q-gram can do alone (a token's own q-grams only overlap with a different
SPELLING of that same token, never with a bare initial of it).

**A first version (gated at `length(given) >= 2`) was a measured net REGRESSION, found and fixed
before landing.** Reasoning at the time: a single given token's own initial is already the
`"^X$:g"` enrichment, so gating the fingerprint at 2+ tokens looked like it just avoided
redundant work. In practice this created an ASYMMETRY that actively hurts a very common truncation
pattern -- dropping a whole given-name token rather than abbreviating it (e.g.
`"Jose Vicente Hernandez Villegas"` -> `"Vicente Hernandez"`, keeping only the second given name).
The short form (1 given token) got no fingerprint at all while the long form (2+ tokens) did,
adding elements to the long form's side alone -- growing the union without growing the
intersection, LOWERING Jaccard for exactly the pair the feature should help. Confirmed directly:
this pair's raw Jaccard dropped 0.417 -> 0.326, and its bucket-scale edge (`"hernandez"`, n=874,
`max_df=0.5`) disappeared entirely (present before this feature, gone after). Measured group-level
against production (10-repo corpus): 245 differing at `max_df=0.5` (up from a 217 no-feature
baseline) and 223 at `0.25` (up from 212) -- a real, measured regression, not a hypothetical one.

**Fix: fire the fingerprint at `length(given) >= 1` instead (any non-empty `given`), not gated
at 2+.** The `"_^X$_"` wrapping is self-similar across positions, so a short name's single-initial
fingerprint windows are the SAME windows a longer name's fingerprint produces at that same
initial's position within it (e.g. `"Vicente Hernandez"`'s fingerprint windows are a subset of
`"Jose Vicente Hernandez Villegas"`'s) -- so now BOTH sides contribute something comparable instead
of one side contributing nothing. Re-measured group-level against production: **201 differing at
`max_df=0.5`, 186 at `0.25` -- BETTER than the original no-feature baseline (217/212), not just a
reversion of the v1 regression.** All 5 previously-broken cases now connect (the Vicente/Jose
Vicente pair, both `"Salvador Gonzalez"` candidates, `"A. García García"`/`"ARIADNA GARCIA GARCIA"`,
`"Alejandro Fernando Reyes"`/`"A. F. Reyes"`), and the 14-case hand-picked regression suite still
passes 14/14.

**Also validated against the mined ground truth** (`mine_ground_truth.jl`'s cached
`mined_trivial_good.txt`/`mined_hard_good.txt`/`mined_bad_v2.txt`, 2,706/136/22,785 pairs), scoring
raw phase-1 Jaccard @ thr=0.3 (not the full pipeline -- this isolates the representation change):

| set | without feature | with feature (v2, fires at length(given)>=1) |
|---|---|---|
| trivial_good | 100.0% | 100.0% (unaffected -- exact-format duplicates connect regardless) |
| hard_good (recall) | 94.85% (129/136) | 92.65% (126/136) |
| bad (false-connect rate) | 5.99% (1365/22785) | 9.02% (2055/22785) |

Two things worth being upfront about here too:
- The 3 `hard_good` recall losses are all the SAME underlying pair
  (`"Victor Manuel Contreras Toledo"` / `"Victor Toledo"`, 3 raw-string formats), an already-
  borderline score (0.314 -> 0.289) -- a residual, smaller instance of the same asymmetric-growth
  mechanism: a name with 2+ given tokens still contributes MORE fingerprint windows than a
  single-initial short form can match, so some union-only growth on the longer side is inherent to
  a windowed-fingerprint approach and not fully eliminable without dropping the feature.
- The `bad` false-connect rate rose 51% relatively (+690 pairs) at the raw phase-1 level. Sampled 15
  of the newly-connected pairs (e.g. `"ADRIANA GONZALEZ MARTINEZ"` / `"ALICIA GOMEZ MARTINEZ"` --
  different given names, different second surnames, sharing only the very common "Martinez") --
  **all 15 are still correctly rejected by the unchanged, already-validated `_name_cluster_edge`**,
  confirming the oracle absorbs this added phase-1 noise exactly as the recall(phase1)/
  precision(oracle) split was designed to allow, consistent with the group-level result actually
  IMPROVING rather than degrading despite the raw noise increase.

**How to apply**: keep the fingerprint gated at `length(given) >= 1` (current code) -- the 2+ gate
is a validated-worse alternative, not a stylistic choice.

### `bucket_edges_searchgraph` -- SearchGraph + MaxMatchError, TRIED AND DISCARDED

[`name_qgram_vec_hashed`](@ref) and [`bucket_edges_searchgraph`](@ref) exist in this file as a
validated negative result, not a recommendation -- kept, like `compute_name_clusters_v2` above, as
a documented dead end so the question doesn't get re-asked and re-benchmarked from scratch later.

The attempt: swap `DictInvertedFile`'s exact posting-list merge for a `SearchGraph` (approximate,
beam-search-based), over sorted `Vector{UInt64}` q-gram hashes (`Dist.Sets.Jaccard`'s cheaper
sorted-merge `evaluate` path, relevant here because `SearchGraph` -- unlike `DictInvertedFile` --
calls `evaluate` directly, many times, both while building and while searching), deliberately
UNPRUNED (no `prune_stopword_elements` call), tuned with [`MaxMatchError`](@ref)`(maxerror=0.01)`
instead of `MinRecall` (both the in-band `hyperparameters_callback` and the explicit post-hoc
`optimize_index!` call). `MaxMatchError` needed a `git pull` of a local SimilaritySearch dev
checkout at the time (0.12.0 -> 1.3.2); it has since appeared in the General registry too, so the
project depends on the ordinary registered 1.3.2, not a local dev path.

Measured against `DictInvertedFile`'s exact, unpruned Jaccard (ground truth) at both real scales:

| bucket | index | edges | vs exact-unpruned ground truth | time |
|---|---|---|---|---|
| 874 | DictInvertedFile, unpruned (exact) | 25,438 | -- | 0.18s* |
| 874 | DictInvertedFile, max_df=0.5 (validated default) | 1,787 | -- | 0.073s |
| 874 | SearchGraph, unpruned, MaxMatchError=0.01 | 25,913 | missing 2,553 (10.0%), extra 3,028 | 5.2s* |
| 17,789 | DictInvertedFile, unpruned (exact) | 830,482 | -- | 52.3s |
| 17,789 | DictInvertedFile, max_df=0.5 (validated default) | 490,624 | -- | 17.9s |
| 17,789 | SearchGraph, unpruned, MaxMatchError=0.01 | 835,898 | missing 47,575 (5.7%), extra 52,991 | 30.3s |

(*874-bucket SearchGraph time is compilation-dominated -- first `SearchGraph` build in the
process; the 17,789 number is the fair, warmed-up one.)

**Discarded because it loses on both axes that matter**, not because it's broken:
1. It beats brute-force exact-UNPRUNED `DictInvertedFile` (30.3s vs 52.3s, ~1.7x) but is still
   slower than the already cross-validated PRUNED exact approach (17.9s at `max_df=0.5`) -- trading
   pruning for an approximate index doesn't pay off here, at least at `k=64` / default beam
   settings.
2. It carries real, non-trivial approximation error relative to the exact ground truth (5.7-10% of
   edges, both missed and spurious) -- expected, since `MaxMatchError(maxerror=0.01)` is an
   optimization TARGET the tuner searches for (a modest budget by default: 16 initial configs x 12
   iterations), not a guarantee it reaches, and `SearchGraph` has no exact fastpath for Jaccard the
   way `DictInvertedFile` does (`has_exact_fastpath(::Dist.Sets.Jaccard) = true` there, not here).

**How to apply**: don't reach for `SearchGraph` for this problem as configured. If revisited, the
open knobs would be a bigger optimization budget and tuning `k`/beam parameters directly -- neither
was tried, since the result was already clearly behind the existing validated path on the first try.
=#

using ReposMx
using SimilaritySearch
using SimilaritySearch.InvertedFiles: DictInvertedFile, getcontext
const AC = ReposMx.AuthorConsolidation
const Q = 4

# ============================================================
# Representation: role-tagged (:g given / :s surname), dual-tagged for the paternal-surname-
# candidate token, boundary-marked character q-grams. Reuses AC's own (unchanged) tokenization /
# compound-surname detection so this stays consistent with the production tokenizer.
# ============================================================

function _qgrams_padded(t::AbstractString; q::Int=Q)
    padded = collect("^" * t * "\$")
    length(padded) < q && return String[String(padded)]
    return [String(padded[i:i+q-1]) for i in 1:(length(padded)-q+1)]
end

"""
    _given_initials_fingerprint(given) -> String

Synthesizes a `"_^A\$_^B\$_..."` string from the first letter of each given-name token, one
`"^X\$"` unit per token, joined and wrapped with `"_"` (e.g. `["antonio","alberto"]` and
`["a","a"]` both produce `"_^A\$_^A\$_"`). Whether a given-name token is spelled out in full or
already a bare initial makes NO difference to this fingerprint -- `first(t)` gives the same letter
either way -- so a fully-spelled-out record and its all-initials counterpart for the SAME person
produce the IDENTICAL fingerprint, something no per-token q-gram can do on its own (a token's own
q-grams only overlap with a different SPELLING of that same token, never with a bare initial of
it). See [`_abbrev_qgrams`](@ref) for how this becomes q-gram elements.
"""
function _given_initials_fingerprint(given::AbstractVector{<:AbstractString})
    parts = ["^" * string(first(t)) * "\$" for t in given]
    return "_" * join(parts, "_") * "_"
end

"""
    _abbrev_qgrams(fingerprint; q=Q) -> Vector{String}

Plain sliding-window q-grams over an already self-delimited fingerprint string (see
[`_given_initials_fingerprint`](@ref)) -- no extra `^`/`\$` padding, unlike [`_qgrams_padded`](@ref),
since the fingerprint already opens and closes on its own `"_"` markers.
"""
function _abbrev_qgrams(fingerprint::AbstractString; q::Int=Q)
    chars = collect(fingerprint)
    length(chars) < q && return String[String(chars)]
    return [String(chars[i:i+q-1]) for i in 1:(length(chars)-q+1)]
end

"""
    name_qgram_set(raw; q=Q, enrich=true) -> Set{String}

See module docstring for why `enrich=true` is safe (even desirable) here, unlike when this same
representation was tried as a FINAL decision metric.

When `enrich` and there is at least 1 given-name token, also adds this name's
[`_given_initials_fingerprint`](@ref) q-grams -- UNTAGGED (no `:g`/`:s` suffix): the fingerprint's
own leading/trailing/between `"_"` already marks these as a special abbreviation namespace, kept
deliberately separate from the ordinary role-tagged q-grams above rather than layered onto either
side. Fires even at `length(given) == 1` -- NOT gated at 2+ like the dual-role block below, despite
looking like it should follow the same rule. Firing at 1 too is required for the fingerprint to
help the (very common) truncation pattern where a full name is reduced elsewhere by DROPPING a
whole given-name token rather than abbreviating it (`"Jose Vicente Hernandez Villegas"` ->
`"Vicente Hernandez"`, keeping only the second given name) -- gating this at 2+ measurably HURT
that pattern instead of helping it: only the longer name got a fingerprint, adding elements to its
side alone that the shorter name could never share, growing the union without growing the
intersection and so LOWERING Jaccard for exactly the pair it should help (confirmed live: this
exact pair's Jaccard dropped 0.417 -> 0.326, and its edge disappeared at bucket scale). Firing at
`length(given) == 1` too means a short form now contributes a (shorter) fingerprint of its own,
whose windows are directly comparable to the corresponding position of a longer name's fingerprint
-- the `"_^X\$_"` wrapping is self-similar, so e.g. `"Vicente Hernandez"`'s single-initial
fingerprint windows are the SAME two windows the longer name's fingerprint produces at Vicente's
own position within it.
"""
function name_qgram_set(raw::AbstractString; q::Int=Q, enrich::Bool=true)
    toks = AC._qgram_name_tokens(raw)
    isempty(toks) && return Set{String}()
    span = AC._surname_span(toks)
    given = toks[1:first(span)-1]
    surname = toks[span]
    elems = String[]
    for t in given
        for g in _qgrams_padded(t; q); push!(elems, g * ":g"); end
        enrich && length(t) > 1 && push!(elems, "^" * string(first(t)) * "\$:g")
    end
    surname_str = join(surname, " ")
    for g in _qgrams_padded(surname_str; q); push!(elems, g * ":s"); end
    if length(given) >= 2
        # dual-role ("duda"): only a REAL ambiguity when there's a given token besides this one --
        # a single given name (length(given) == 1, e.g. "Victor Torres") has no ambiguity at all,
        # it's unambiguously the given name, never a paternal-surname candidate. Tagging it :s too
        # in that case pollutes the surname-side set with given-name content for no reason (found
        # live: inflated a false match risk for "Victor Torres" against unrelated "victor"-sharing
        # names, and wasted signal that should have stayed on the :g side only).
        t = given[end]
        for g in _qgrams_padded(t; q); push!(elems, g * ":s"); end
        enrich && length(t) > 1 && push!(elems, "^" * string(first(t)) * "\$:s")
    end
    if enrich && !isempty(given)
        fp = _given_initials_fingerprint(given)
        for g in _abbrev_qgrams(fp; q); push!(elems, g); end
    end
    return Set(elems)
end

"""
    name_qgram_set_hashed(raw; q=Q, enrich=true) -> Set{UInt64}

Same representation as [`name_qgram_set`](@ref), but each tagged q-gram STRING is hashed down to a
`UInt64` (Julia's built-in `hash`, already a `UInt64` on 64-bit systems) before being added to the
set. The point: integer keys are cheaper to hash/compare/store than variable-length strings, so a
`DictInvertedFile{...,UInt64,...}` built from these should do less work per posting-list merge than
the string-keyed version -- at the cost of a (vanishingly small, but not exactly zero) chance that
two DIFFERENT q-grams collide onto the same 64-bit value. See this file's hashed-vs-string
benchmark for the measured speed/quality tradeoff.

Carries the same `enrich`-gated [`_given_initials_fingerprint`](@ref) q-grams as
[`name_qgram_set`](@ref) (hashed like everything else here) -- untagged strings never collide with
a `:g`/`:s`-tagged one since the fingerprint never contains a `:`, so no separate hash namespace is
needed.
"""
function name_qgram_set_hashed(raw::AbstractString; q::Int=Q, enrich::Bool=true)
    toks = AC._qgram_name_tokens(raw)
    isempty(toks) && return Set{UInt64}()
    span = AC._surname_span(toks)
    given = toks[1:first(span)-1]
    surname = toks[span]
    elems = UInt64[]
    for t in given
        for g in _qgrams_padded(t; q); push!(elems, hash(g * ":g")); end
        enrich && length(t) > 1 && push!(elems, hash("^" * string(first(t)) * "\$:g"))
    end
    surname_str = join(surname, " ")
    for g in _qgrams_padded(surname_str; q); push!(elems, hash(g * ":s")); end
    if length(given) >= 2
        t = given[end]
        for g in _qgrams_padded(t; q); push!(elems, hash(g * ":s")); end
        enrich && length(t) > 1 && push!(elems, hash("^" * string(first(t)) * "\$:s"))
    end
    if enrich && !isempty(given)
        fp = _given_initials_fingerprint(given)
        for g in _abbrev_qgrams(fp; q); push!(elems, hash(g)); end
    end
    return Set(elems)
end

"""
    name_qgram_vec_hashed(raw; q=Q, enrich=true) -> Vector{UInt64}

Same hashed elements as [`name_qgram_set_hashed`](@ref) (deduplicated), but returned SORTED as a
`Vector{UInt64}` instead of kept as a `Set`. `Dist.Sets.Jaccard`'s generic `evaluate` dispatches to
a cheap sorted-merge `intersectionsize` for `AbstractVector` args, vs. a hash-lookup
`intersectionsize` for `AbstractSet` args -- both are CORRECT, but the merge path has a much lower
constant factor per comparison. That difference is irrelevant for `DictInvertedFile` (it never
calls `evaluate` on a full pair -- it walks posting lists instead), which is why every `Set`-based
representation above was fine as-is. It matters a lot for [`bucket_edges_searchgraph`](@ref)'s
`SearchGraph`, which calls `evaluate` directly, a very large number of times, during both
construction (neighborhood search for every insertion) and querying (`allknn`'s beam search).
"""
function name_qgram_vec_hashed(raw::AbstractString; q::Int=Q, enrich::Bool=true)
    sort!(collect(name_qgram_set_hashed(raw; q, enrich)))
end

"""
    prune_stopword_elements(sets; max_df=0.5, min_n=50) -> (pruned_sets, stopword_set)

Drops any element whose document frequency (fraction of `sets` containing it) exceeds `max_df` --
see module docstring's "stopword problem" section. A PERFORMANCE fix for `DictInvertedFile`'s
posting-list merge cost, not a correctness change for a LARGE collection (a near-universal element
has ~no discriminating power there anyway) -- but a fractional threshold is meaningless on a small
one: with `n=2`, any element shared by both names already has `df=1.0`, so `max_df=0.5` would
prune every bit of real signal, including the surname q-grams that are usually the WHOLE reason
two names share a bucket (found live: gutted the only two members of a "torres" bucket down to
zero overlap). Skip pruning entirely below `min_n` -- small buckets are cheap enough for exact
search anyway, so there's no performance reason to prune them in the first place.

Generic over the element type (`String` for [`name_qgram_set`](@ref), `UInt64` for
[`name_qgram_set_hashed`](@ref)) -- document-frequency counting doesn't care what the elements
actually are.
"""
function prune_stopword_elements(sets::Vector{Set{T}}; max_df::Float64=0.5, min_n::Int=50) where T
    n = length(sets)
    (n == 0 || n < min_n) && return sets, Set{T}()
    df = Dict{T,Int}()
    for s in sets, e in s
        df[e] = get(df, e, 0) + 1
    end
    stop = Set(k for (k, v) in df if v / n > max_df)
    isempty(stop) && return sets, stop
    return [setdiff(s, stop) for s in sets], stop
end

"""
    build_name_index(sets; backend=:dictinvfile, dist=Dist.Sets.Jaccard()) -> (index, context)

Generic index construction over the same `Vector{Set{T}}` representation (`T` is `String` or
`UInt64`, see [`name_qgram_set`](@ref)/[`name_qgram_set_hashed`](@ref)), dispatched by `backend` --
kept swappable on purpose (see module docstring). Only `:dictinvfile` is implemented here; the
`SearchGraph` alternative lives as its own dedicated function,
[`bucket_edges_searchgraph`](@ref), rather than a `backend=:searchgraph` branch here, because it
needs a genuinely different item type (sorted `Vector{UInt64}`, not `Set{T}`) and a different
construction/tuning pipeline (`index!` + `optimize_index!` with `MaxMatchError`, not
`append_items!`), not just a different index constructor call.
"""
function build_name_index(sets::Vector{Set{T}}; backend::Symbol=:dictinvfile, dist=Dist.Sets.Jaccard()) where T
    if backend == :dictinvfile
        db = VectorDatabase(sets)
        idx = DictInvertedFile(T, dist)
        ctx = getcontext(idx)
        append_items!(idx, ctx, db)
        return idx, ctx
    else
        error("unknown backend $backend")
    end
end

"""
    bucket_edges_invfile(names; repr=name_qgram_set, q=Q, enrich=true, max_df=0.5, k=64, thr=0.3) -> Vector{Tuple{Int,Int}}

Phase-1 candidate edges (index pairs into `names`) within one bucket, via `allknn` over a
DictInvertedFile with exact Jaccard (parallel by default). `k` approximates a threshold/range
query (SimilaritySearch's inverted-file `search` is k-NN shaped, not radius-shaped) -- generous by
design, oversized relative to any expected true-cluster size, then filtered by `thr` afterward.
`repr` selects the element representation -- pass [`name_qgram_set_hashed`](@ref) for the
integer-keyed variant instead of the default string-keyed [`name_qgram_set`](@ref).
"""
function bucket_edges_invfile(names::Vector{String}; repr::Function=name_qgram_set, q::Int=Q, enrich::Bool=true,
                               max_df::Float64=0.5, k::Int=64, thr::Float64=0.3)
    n = length(names)
    n < 2 && return Tuple{Int,Int}[]
    sets_raw = [repr(nm; q, enrich) for nm in names]
    sets, _stop = prune_stopword_elements(sets_raw; max_df)
    idx, ctx = build_name_index(sets)
    kk = min(k, n - 1)
    ids, dists = allknn(idx, ctx, kk + 1)  # +1: each point is trivially its own nearest neighbor
    edges = Tuple{Int,Int}[]
    for j in 1:n, r in 1:size(ids, 1)
        i = ids[r, j]
        (i == 0 || Int(i) == j) && continue
        sim = 1.0 - dists[r, j]
        sim >= thr || continue
        a, b = minmax(Int(i), j)
        push!(edges, (a, b))
    end
    return unique(edges)
end

"""
    bucket_edges_searchgraph(names; repr=name_qgram_vec_hashed, q=Q, enrich=true, k=64, thr=0.3,
                              maxerror=0.01f0) -> Vector{Tuple{Int,Int}}

Same phase-1 candidate-edge contract as [`bucket_edges_invfile`](@ref), but through a `SearchGraph`
(an approximate, beam-search-based index) instead of `DictInvertedFile`'s exact posting-list merge.
Two deliberate departures, both per explicit request rather than this file's earlier default
choices:

- **No stopword pruning.** `prune_stopword_elements` is never called here -- every element,
  including the bucket's own near-universal shared surname, stays in every set. This is the
  opposite of `bucket_edges_invfile`'s validated default (`max_df=0.5`) and is expected to cost
  real search-time performance (see this file's `max_df` sweep section above for how much a large
  posting list -- or, here, a large per-node neighborhood -- costs); the point of this variant is
  to see whether `SearchGraph`'s different access pattern (approximate beam search over a graph,
  not an exact posting-list walk) tolerates that cost differently than `DictInvertedFile` did.
- **Tuned with [`MaxMatchError`](@ref) instead of `MinRecall`.** Both the in-band
  `hyperparameters_callback` (fires automatically as the graph grows during `index!`) and the
  explicit post-hoc `optimize_index!` call are set to `MaxMatchError(; maxerror)` -- no `MinRecall`
  tuning happens anywhere in this path. `MaxMatchError` compares returned-vs-gold NEIGHBOR
  DISTANCES at matching ranks (not neighbor identities, unlike `MinRecall`), so a correct distance
  tie with a different-but-equally-valid neighbor still counts as a perfect match; `maxerror=0.01`
  means "average within 1% of the gold neighborhood's own distance spread".

Unlike `DictInvertedFile` (`has_exact_fastpath(::Dist.Sets.Jaccard) = true`), `SearchGraph` is
APPROXIMATE even once tuned -- `allknn` here is not a ground truth the way it was for the invfile
path, so edge-set comparisons against this function should be read as "how close does the tuned
approximation get", not "is it exactly right".
"""
function bucket_edges_searchgraph(names::Vector{String}; repr::Function=name_qgram_vec_hashed,
                                   q::Int=Q, enrich::Bool=true, k::Int=64, thr::Float64=0.3,
                                   maxerror::Float32=0.01f0)
    n = length(names)
    n < 2 && return Tuple{Int,Int}[]
    vecs = [repr(nm; q, enrich) for nm in names]
    db = VectorDatabase(vecs)
    goal = MaxMatchError(; maxerror)
    ctx = SearchGraphContext(; hyperparameters_callback=OptimizeParameters(goal))
    G = SearchGraph(Dist.Sets.Jaccard(), db)
    index!(G, ctx)
    optimize_index!(G, ctx, goal)
    kk = min(k, n - 1)
    ids, dists = allknn(G, ctx, kk + 1)
    edges = Tuple{Int,Int}[]
    for j in 1:n, r in 1:size(ids, 1)
        i = ids[r, j]
        (i == 0 || Int(i) == j) && continue
        sim = 1.0 - dists[r, j]
        sim >= thr || continue
        a, b = minmax(Int(i), j)
        push!(edges, (a, b))
    end
    return unique(edges)
end

"""
    compute_name_clusters_v2(raw_names; kwargs...) -> Vector{Vector{String}}

Drop-in comparison for `AC.compute_name_clusters`: SAME bucketing (`AC._name_cluster_keys`), SAME
oracle (`AC._name_cluster_contradiction` / `AC._name_cluster_split`, both unmodified production
code) -- ONLY phase 1's connection mechanism differs (DictInvertedFile+allknn here vs. the
hand-rolled exact loop in production).
"""
function compute_name_clusters_v2(raw_names::Vector{String}; q::Int=Q, enrich::Bool=true,
                                   max_df::Float64=0.5, k::Int=64, thr::Float64=0.3)
    n = length(raw_names)
    n == 0 && return Vector{Vector{String}}()
    idx_of = Dict(nm => i for (i, nm) in enumerate(raw_names))

    # garbage (ORCID/URL) "names" collapse to identical degenerate tokens under this tokenizer --
    # production's _name_match_score guards against this with an explicit is_garbage check inside
    # the pairwise score itself; a set/Jaccard representation has no equivalent per-pair override
    # point, so the guard has to happen at bucket-membership time instead: never let a garbage name
    # enter a bucket at all, so it can never be compared to anything and falls through to its own
    # singleton group via the union-find's untouched-node default (same as production).
    candidate_buckets = Dict{String,Vector{String}}()
    for nm in raw_names
        AC._is_garbage_name(nm) && continue
        for key in AC._name_cluster_keys(nm)
            push!(get!(candidate_buckets, key, String[]), nm)
        end
    end

    parent = collect(1:n)
    function uf_find(x)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    function uf_union!(a, b)
        ra, rb = uf_find(a), uf_find(b)
        ra != rb && (parent[ra] = rb)
    end

    for (_, bucket) in candidate_buckets
        bucket = unique(bucket)
        length(bucket) < 2 && continue
        for (bi, bj) in bucket_edges_invfile(bucket; q, enrich, max_df, k, thr)
            uf_union!(idx_of[bucket[bi]], idx_of[bucket[bj]])
        end
    end

    by_root = Dict{Int,Vector{String}}()
    for nm in raw_names
        push!(get!(by_root, uf_find(idx_of[nm]), String[]), nm)
    end

    groups = Vector{Vector{String}}()
    for (_, comp) in by_root
        if length(comp) == 1
            push!(groups, comp)
            continue
        end
        cx = AC._name_cluster_contradiction(comp)
        if cx === nothing
            push!(groups, comp)
        else
            append!(groups, AC._name_cluster_split(comp))
        end
    end
    return groups
end

"""
    compute_name_clusters_hybrid(raw_names; size_threshold=200, kwargs...) -> Vector{Vector{String}}

The actual point of this file: route each bucket to whichever phase-1 mechanism suits its size --
`AC._name_cluster_edge`'s direct exact loop (no index-construction overhead, cheap for the
overwhelming majority of buckets) below `size_threshold`, `bucket_edges_invfile` (parallel
`allknn`, worth its fixed per-bucket setup cost only once there's enough O(size²) work to amortize
it) at or above it. Same bucketing/oracle as `compute_name_clusters_v2` -- only the routing is new.

`size_threshold` picked from the real bucket-size distribution (see this module's docstring for
the numbers): on the real 93-repo corpus, buckets >= 200 are only 1.2% of all buckets but already
account for 99.5% of the total O(size²) work -- so routing just that top slice through the
indexed path should capture nearly all the available speedup while leaving the other ~98.8% of
buckets on the cheap direct loop, avoiding the per-bucket overhead that made `compute_name_clusters_v2`
(indexed path for EVERY bucket) slower than production overall.
"""
function compute_name_clusters_hybrid(raw_names::Vector{String}; repr::Function=name_qgram_set,
                                       q::Int=Q, enrich::Bool=true,
                                       max_df::Float64=0.5, k::Int=64, thr::Float64=0.3,
                                       size_threshold::Int=200)
    n = length(raw_names)
    n == 0 && return Vector{Vector{String}}()
    idx_of = Dict(nm => i for (i, nm) in enumerate(raw_names))

    candidate_buckets = Dict{String,Vector{String}}()
    for nm in raw_names
        AC._is_garbage_name(nm) && continue
        for key in AC._name_cluster_keys(nm)
            push!(get!(candidate_buckets, key, String[]), nm)
        end
    end

    parent = collect(1:n)
    function uf_find(x)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    function uf_union!(a, b)
        ra, rb = uf_find(a), uf_find(b)
        ra != rb && (parent[ra] = rb)
    end

    n_indexed = 0
    n_direct = 0
    for (_, bucket) in candidate_buckets
        bucket = unique(bucket)
        length(bucket) < 2 && continue
        if length(bucket) >= size_threshold
            n_indexed += 1
            for (bi, bj) in bucket_edges_invfile(bucket; repr, q, enrich, max_df, k, thr)
                uf_union!(idx_of[bucket[bi]], idx_of[bucket[bj]])
            end
        else
            n_direct += 1
            for i in 1:length(bucket), j in (i+1):length(bucket)
                a, b = bucket[i], bucket[j]
                AC._name_cluster_edge(a, b) && uf_union!(idx_of[a], idx_of[b])
            end
        end
    end
    println("  compute_name_clusters_hybrid: $n_indexed bucket(s) routed to DictInvertedFile (size >= $size_threshold), $n_direct to the direct loop")

    by_root = Dict{Int,Vector{String}}()
    for nm in raw_names
        push!(get!(by_root, uf_find(idx_of[nm]), String[]), nm)
    end

    groups = Vector{Vector{String}}()
    for (_, comp) in by_root
        if length(comp) == 1
            push!(groups, comp)
            continue
        end
        cx = AC._name_cluster_contradiction(comp)
        if cx === nothing
            push!(groups, comp)
        else
            append!(groups, AC._name_cluster_split(comp))
        end
    end
    return groups
end
