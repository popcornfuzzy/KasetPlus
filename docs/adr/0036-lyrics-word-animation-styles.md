# ADR-0036: Selectable Word-by-Word Lyrics Animations

## Status

Accepted

## Context

[ADR-0018](0018-karaoke-lyrics-animation.md) built one word animation and deliberately shipped it
without a setting: a softly feathered gradient swept each word, a blurred copy of the sung text
bloomed behind the edge, and one "crest" of characters rose by `0.02em` at a time. Its job was to
make a line look sung rather than blinking, and it does that well.

It also reads as nearly still. The lift is a fraction of a pixel at the panel's size, and the
decorations are scaled down further by the panel's `0.55` emphasis, so a word moves almost not at
all as it is sung — and a syllable held for a second looks exactly like a short one, because the
emphasis is measured per word and never reflects how long the word lasts.

The [Better Lyrics](https://github.com/better-lyrics/better-lyrics) lyric renderer takes the other
approach. Its rich-sync look (engine in
[`better-lyrics/braccato`](https://github.com/better-lyrics/braccato),
`packages/core/src/engine.ts` and `packages/core/src/styles/variables.css`) is one fixed
combination, not a menu:

- **A crisp swipe that overshoots the word.** The highlight's gradient band is a tenth of the word
  wide and travels from `-0.2` to `1.4`, starting `0.1 ×` the word's duration early and running
  `1.6 ×` its duration. The band only ever moves forwards, so a line reads as one continuous sweep.
- **A word pop.** The whole word travels `0.05em` to the trailing edge and widens to `scaleX(1.025)`
  at 12.5% of a one-second animation, and is back at rest by 75%.
- **A staggered per-letter wave.** Each letter floats to `-0.05em` and eases back to `-0.02em`, its
  crest landing exactly when the swipe finishes lighting it. When a word is held long enough that
  the swipe lights a letter slower than the float's own rise, the float is **stretched** to keep
  that alignment — which is what makes a held word look different from a short one.
- **A long-word swell.** A word held past `900 ms` (`blyrics-long-word-threshold`) swells each letter
  to `1.11` at its crest.
- **A glow** over the longer of `1.2 ×` the word and `1.2 s`.

A reader asked for that look instead, and for the two to be selectable rather than a swap.

## Decision

Add a persisted `LyricsAnimationStyle` setting (`SettingsManager.lyricsAnimationStyle`, default
`.betterLyrics`) with a picker in Lyrics settings, and keep the ADR-0018 animation as
`.appleMusic`. Both styles are driven by the same words, the same fill windows and the same
measured layout; only the envelopes and the layers differ.

1. **`RichLyricsAnimation` is a pure model** (`Sources/Kaset/Models/RichLyricsAnimation.swift`) with
   Better Lyrics' constants in `RichLyricsTiming`, plus the CSS easings as `RichLyricsCurve`
   (`ease`, `ease-in-out`, `ease-out` as cubic Béziers). The swipe band, the pop, the per-letter
   float and the bloom are asserted directly in `RichLyricsAnimationTests`, without rendering.

2. **`RichLyricsWordView` draws a word of the new style.** A letter must be its own layer, because
   the wave puts every letter at a different height at the same moment and no single text layer can
   do that. The cost is bounded by drawing a word that has nothing in flight as the one `Text` it was
   before — a line is per-letter only around the word being sung — and by deriving each word's wave
   schedule **once per line** in `KaraokeLineLayout` rather than once per frame.

3. **`KaraokeLyricsLineView.isSettled`** lets a line say it is no longer being sung. A float can
   outlast its own word (that is what keeps a held word moving), so a finished row would otherwise
   hold its last word slightly above the baseline forever. With the flag, a settled row draws every
   letter on the baseline, which is what Better Lyrics gets by cancelling the line's animations.

4. **The motion is not scaled by `emphasis`; the bloom is.** Better Lyrics moves a letter by a share
   of the font size, so the panel's smaller text already moves less than the player's. Scaling that
   again for the panel's `0.55` emphasis would put the wave back under a point. Reduce Motion
   (`emphasis == 0`) still turns all of it off, leaving the sweep.

5. **The word does not travel sideways by default.** Better Lyrics slides the whole word `0.05em`
   towards its trailing edge as it widens. Across a sheet where every word is being sung in turn,
   that slide reads as a jitter around the text rather than as a word being sung, so
   `wobbleTravelEm` is `0`: the word still widens to `1.025` and its letters still rise, but the
   words do not slide. A reader who wants that look back turns on **Word Slide**
   (`SettingsManager.lyricsWordSlideEnabled`), which swaps in `RichLyricsTiming.withWordSlide` — the
   same animation with Better Lyrics' own `0.05em` and nothing else changed. The amount is not a
   setting: it is their value, not a range.

   The switch resolves to that value in one place (`SettingsManager.richLyricsTiming`), and the only
   sideways motion in either timing is that travel. A word whose letters are collapsed onto one layer
   (`RichLyricsAnimation.sharedFloat`) keeps no scale, because scaling one layer widens the whole word
   about its centre and carries every glyph sideways — the movement the switch is for, which a
   per-letter layer never had.

6. **What is not ported.** Better Lyrics' theme variables, its per-letter mask-sweep easing, and any
   of its line-level motion (line scale, autoscroll) are left alone: this app owns those. The glow
   is drawn as a fixed-radius blur whose opacity settles, not a blur radius that shrinks every
   frame, because a radius that changes per frame re-rasterises the blurred layer per frame; the
   shape and the moment it settles are the same.

## Consequences

- A reader can choose the look, and the default is the one that was asked for. Existing installs
  move to `.betterLyrics` on next launch (the setting had no previous value). **Word Slide** is a
  second, off-by-default switch for the one part of the port that was turned off.
- The new style costs more per frame than the old one on the word being sung, and no more on a
  settled or upcoming line. `KaraokeLyricsPerformanceTests` prices both: in the panel the classic
  word-by-word line is ~1.6 ms/frame against ~3.8 ms/frame for Better Lyrics, and both are inside
  the suite's 6 ms structure budget. A row still redraws at the same rates (`KaraokeFrameBudget`).
- Both styles keep every existing guarantee: backing vocals, duets, pause dots, RTL fills,
  Reduce Motion, and the settled frame of a finished line being the frame it was already showing.
- A third style would be another `LyricsAnimationStyle` case and another envelope model; the
  picker, the setting and the row plumbing already carry it.
