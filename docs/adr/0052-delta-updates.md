# ADR-0052: Delta Updates in the Appcast Feed

## Status

Accepted. Extends [ADR-0019](0019-release-pipeline-and-appcast-publication.md) and fills in the
delta part of [ADR-0007](0007-sparkle-auto-updates.md), which described "automatic delta updates"
as a benefit of Sparkle without the pipeline ever producing one.

## Context

Every release is a universal (`arm64` + `x86_64`) Kaset build packaged into a DMG of about 13.5 MB,
published to GitHub Releases, and advertised in `appcast.xml` with a full-archive enclosure only.
Releases ship every few days.

Sparkle can patch an installed copy instead: `generate_appcast` diffs the new archive against older
archives *in the same directory* and writes a `.delta` per pair, which Sparkle downloads instead of
the full archive when one exists for the version the user actually runs. The pipeline never produced
one, because `Scripts/generate-appcast.sh` staged only the DMG being published — with a single
archive in the directory there is nothing to diff against.

Measured on two real releases (0.9.1 → 0.9.2, `BinaryDelta create --version=4`):

| | Bytes |
|---|---|
| Full DMG | 13,560,609 |
| Delta, LZMA (format 4) | 3,025,206 |

A delta is therefore ~22% of the download, and `BinaryDelta apply` of it reproduces a valid app.
Because somebody on 0.9.1 is the common case (users update within a release or two), most updates
would take that path.

## Decision

1. **Diff against prior releases, not against nothing.** The appcast job downloads up to five prior
   release DMGs — Sparkle's `--maximum-deltas` default — and passes each to the script as
   `--previous-dmg`. Only releases *older* than the tag being published qualify: a newer archive
   belongs to an item the feed already carries, and staging it would advertise that archive under
   the new release's URL.

2. **A delta is uploaded before it is advertised.** `generate_appcast` builds delta URLs from
   `--download-url-prefix`, so the files belong to the release being published. The workflow uploads
   them there (`gh release upload`, before the feed commit), which keeps the published-feed contract
   from ADR-0019: nothing in `appcast.xml` may point at a URL that is not already public.

3. **Every delta enclosure is verified, and a missing delta is a failure.** The script checks that
   each advertised delta file exists in the staging directory, matches the length the feed claims,
   points at the release being published, and carries an `sparkle:edSignature` that `sign_update
   --verify` accepts. A caller that asked for deltas (staged bases or `--delta-dir`) and got none
   fails the run instead of silently publishing a full-only item.

4. **Staged bases never become new items.** The script compares the item count of the seeded feed
   with the generated one and fails if more than the single new item appeared. Without that guard, a
   feed that had lost an old item would have it regenerated under the current release's URL.

5. **The install path is proved, not assumed.** `Scripts/test-update-flow.sh` now packages both
   builds, installs the older one from its own DMG (the delta is generated against exactly what is on
   disk, which is also how a user receives it), and passes only if the `.delta` was the request that
   was served. A silent fallback to the full archive fails the test.

6. **A patch that costs most of the archive fails the run.** When the patch from the *newest* base —
   the release most updating copies are on — is above 50% of the full archive
   (`KASET_DELTA_MAX_PERCENT`), the job stops. At that size the update has stopped being incremental:
   non-deterministic build output, a moved or renamed resource tree, or an unintended edit to every
   file, rather than a code change worth the download. The message points at `BinaryDelta --verbose`
   to see what moved; a release that genuinely replaces most of the app raises the threshold
   deliberately. Older bases are reported but never fatal: a base five releases back always needs a
   fatter patch (0.8 → 0.9.3 is already 46%), and Sparkle serves the full archive as soon as a patch
   stops being the smaller download, so failing the feed over one would block a healthy release. The
   measured 0.9.1 → 0.9.2 patch is 22% and 0.9.2 → 0.9.3 is 19%, so the limit leaves room for ordinary
   releases without letting a bad one through.

## Consequences

### Positive

- Most updates download roughly 3 MB instead of 13.5 MB, and install from a patch rather than a full
  bundle, without any new hosting: the deltas are ordinary release assets next to the DMG.
- Nothing regresses for anyone. A missing base, a mismatched build, a stripped architecture slice or
  a permissions check that fails all end in the full download, which is what users get today.
- The security model is unchanged: deltas are EdDSA-signed by the same key and the patched bundle
  still has to pass Sparkle's checksum and code-signature validation.

### Negative

- The job downloads up to five DMGs (~65 MB) and diffs each pair; the 0.9.1 → 0.9.2 diff took ~22 s
  on a developer machine, so the step costs a minute or two of runner time.
- A delta only helps a user on one of the five staged versions. Someone further behind still gets the
  full archive, and pruning the staged set trades that coverage for job time.
- Deltas are release assets that have to stay in step with the feed. Uploading after the commit, or
  deleting a base archive, leaves an enclosure that 404s until the next run.

### Neutral

- Delta format 4 requires Sparkle 2.7 or later in the client being patched. Every 0.9.x build pins a
  newer Sparkle, so bases within that line are fine; older clients fall back.
- Delta size follows change locality: a release that renames files or rewrites resources produces a
  fatter patch. `BinaryDelta --verbose` still shows what changed if one looks unexpectedly large.
- The size limit is a judgement, not a measurement: a deliberate release that touches most of the
  bundle has to raise `KASET_DELTA_MAX_PERCENT`, which is one more thing to remember at publish time.
