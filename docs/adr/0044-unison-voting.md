# ADR-0044: Voting on Unison Lyrics

## Status

Accepted

## Context

Unison's lyrics carry a community score: listeners upvote or downvote a
version, and the score decides which version a lookup serves and how the
variant picker ranks it. Kaset already showed those versions (ADR-0024) but
treated the score as decoration — `voteCount` was decoded and then dropped.

Voting is not a plain write. Every Unison write uses an ECDSA P-256 signed
envelope:

```json
{
  "payload": { "keyId": "<sha256 of the public key>", "timestamp": 1703520000000, "nonce": "...", "vote": 1 },
  "signature": "<base64 r‖s>",
  "publicKey": { "kty": "EC", "crv": "P-256", "x": "...", "y": "..." }
}
```

The server verifies the signature over the canonical JSON of the payload,
rejects timestamps outside ±5 minutes, refuses reused nonces, and registers the
carried public key on its first sight. The Better Lyrics browser extension owns
a keypair for its users, but Kaset is not an extension and has no extension to
ask for one.

## Decision

Let the listener vote on the Unison version that is on screen:

- **Kaset owns its own key.** `UnisonVoteSigner` generates a P-256 keypair on
  the first vote, keeps the private scalar in the Keychain
  (`com.sertacozercan.Kaset.unisonVoteKey`, `kSecAttrAccessibleAfterFirstUnlock`)
  and sends the public key with every signed body, which is how Unison
  registers a key it has not seen. The key is cached in memory for the
  session; nothing derived from it is logged.
- **Reads ask for the listener's own vote.** `GET /lyrics/:id` with
  `x-key-id: <keyId>` answers `voteCount` and `userVote` together, so the footer
  can show a filled arrow for a vote cast in an earlier session. Reads still
  need no signature, so nothing is signed to display a count.
- **The API's own write endpoints are used as documented.**
  `POST /lyrics/:id/vote` with `{"vote": 1}` or `{"vote": -1}`, and
  `DELETE /lyrics/:id/vote` to take the vote back. A non-2xx response surfaces
  the API's `error` message (`UnisonRequestError`).
- **The record id travels with the result.** `LyricsAttribution.recordID` carries
  Unison's lyrics id through parsing, display conversion and the per-song cache,
  because attribution is the metadata a result already keeps. A record with no
  credited submitter still has an id, so `attribution(for:)` now returns a value
  for it (with `hasSubmitter == false`, so no credit is drawn).
- **`LyricsVoteProvider`** is the provider capability, beside
  `LyricsVariantProvider`: `voteState(lyricsID:)` and `vote(_:lyricsID:)`.
  `SyncedLyricsService` holds the state for the version on screen
  (`currentVote`, `isVoting`, `voteErrorMessage`) and only talks to the
  provider that supplied the displayed lyrics.
- **Taps are optimistic.** `toggleVote` applies the change immediately, then
  reads the record back for the authoritative count and reverts on failure.
  Pressing the direction already chosen removes the vote; pressing the other
  one switches it.
- **Voting sits with the credit, counts sit with the versions.** The controls
  render beside `Lyrics by …` at the end of the sheet (`LyricsSubmitterCredit`),
  so the sidebar's lyric page, the classic panel and the fullscreen player all
  offer the same thing at the same place, and a vote sits next to the record's
  identity rather than in chrome. The filled glyph is the listener's own vote.
  The footer's version picker carries each version's count in its menu row,
  because choosing between versions is what those counts are for. Catalog
  providers have no vote state, so neither appears for them.

## Consequences

- A listener gets a stable Unison identity from the app, but it is not the same
  identity as their Better Lyrics browser extension: votes cast here are not
  votes cast there, and the profile page is public but not signed into.
- The identity is per-machine, since the key is in that Mac's Keychain.
- Voting adds at most one signed write and two reads (the variant list and the
  record) per displayed song; Unison rate limits writes per key and reads per
  IP, and the service fetches the record only when Unison supplied the lyrics.
- A record with no credited submitter has no credit row, so it offers nowhere
  to vote; anonymous records can be read but not voted on here.
- The key is a credential and is treated as one: Keychain storage, no logging,
  and no Keychain access in UI-test mode (the same rule scrobbling follows).
