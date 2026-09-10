# Paid release

How Next Notes goes from "clone it and run `make install`" to a signed, notarized,
self-updating download that people pay for once.

**The decision this document is built on:** we sell the convenience. The source stays public
at <https://github.com/spyhack225/next-notes>, `make install` keeps working exactly as it does
today, and what money buys is the build we made — signed, notarized, stapled, auto-updating,
ready in ninety seconds instead of a toolchain and an eight-minute compile.

Everything below follows from that sentence. Read the next section before the phases, because
it is what makes several otherwise-odd choices correct.

---

## What "sell the convenience" commits us to

**A source build is never gated.** Not crippled, not nagged, not watermarked. The licence
check is compiled into release builds only, behind a `PAID_BUILD` flag that `make install`
does not pass. Someone who builds from source has no check to remove, because there is nothing
there to remove. That is not a loophole we tolerate — it is the product boundary, stated in
code.

**No obfuscation, no anti-tamper, no phone-home.** All three cost real engineering, and all
three defend a wall we have already decided not to build. Worse, a licence check that calls a
server contradicts the only claim the product actually makes: that everything happens on this
Mac. `Privacy.tsx` and the README both promise that the only network traffic is a model
download, your calendar, and a Workspace action you approved. A licence heartbeat would make
that a lie. So licence verification is **offline, cryptographic, and one function long**.

**Therefore the licence must be pleasant rather than strict.** No seat counting, no
deactivation dance, no machine fingerprint, no reactivation email when someone gets a new Mac.
The people who would be caught by strictness are the ones already paying.

**And the paid build has to be visibly better.** If the only difference is a nag screen, we
have sold nothing. The difference is: it opens without a Gatekeeper fight, it updates itself,
and it is the build we test. Phases 2, 3 and 7 are the product. Phase 4 is just the till.

---

## Phase 0 — Decisions to lock before any work starts

Each of these gates work downstream. None of them are reversible cheaply.

| # | Decision | Recommendation | Consequence if changed later |
|---|---|---|---|
| 0.1 | Apple enrolment: **individual** or **organization** | Individual, unless "Pivot Studio" needs to be the named seller | An org enrolment needs a D-U-N-S number and takes days-to-weeks. Switching later means a new Team ID, a new signature, and every existing user re-granting Accessibility. |
| 0.2 | Price | One number, $29–$49. Pick it and stop. | Trivial to change up; painful to change down. Early buyers remember. |
| 0.3 | Trial shape | 7 days from first launch, no card, no account | Baked into the licence file format if you get it wrong |
| 0.4 | Architecture | **arm64 only.** macOS 26 + a local 4B model + CoreML ASR is not an Intel experience | Adding x86_64 later is a build-flag change; dropping it later breaks buyers |
| 0.5 | Merchant of record | Lemon Squeezy or Polar (see Phase 6) | Migrating checkout means re-issuing nothing, but changing the delivery email flow |
| 0.6 | Update policy | Perpetual licence, all updates included, for v1 | "Updates for 12 months" can be added later via the licence `issued` date without invalidating v1 keys — the format in Phase 4 already carries it |
| 0.7 | What the trial gates | Dictation and meeting recording. **Never** Settings, and never access to notes already written | Holding a user's own transcripts hostage would be indefensible |

**Do 0.1 first and today.** Apple enrolment is the only item on this whole roadmap with a
queue in front of it, and Phases 2, 3, 7 and 8 all sit behind it.

---

## Phase 1 — Apple Developer Program

**Cost:** $99/year. **Blocks:** Phases 2, 3, 7, 8. **Effort:** an hour, then waiting.

1. Enrol at <https://developer.apple.com/programs/> with the identity chosen in 0.1.
2. Once approved, create a **Developer ID Application** certificate (Certificates,
   Identifiers & Profiles → Certificates → +). Generate the CSR from Keychain Access on the
   machine that will do releases, or from Xcode.
3. Export the certificate **and its private key** as a `.p12`, with a strong password. Put it
   in a password manager. This is the identity of the product; losing it means every user
   re-grants Accessibility on the next update.
4. Create an **App Store Connect API key** (Users and Access → Integrations → App Store
   Connect API) with the *Developer* role. Download the `.p8` — you get exactly one chance.
   Note the **Key ID** and **Issuer ID**. This is what `notarytool` will authenticate with,
   and it is better than an app-specific password because it can be revoked independently.

### Gotcha, written down now so it is not a surprise later

The `Makefile` already knows that TCC keys the Accessibility grant to the code signature, and
that is why `LOCAL_SIGN_CN` exists. Switching from `Next Notes Local Signing` to a real
Developer ID **changes the signature**, so every machine that already runs a locally built
copy — yours, and anyone else's — will need to re-grant Accessibility, Microphone and
Notifications exactly once after installing the first Developer ID build. That is correct and
unavoidable. It happens once, and never again after that, because the Developer ID identity is
stable for the life of the certificate.

**Acceptance:** `security find-identity -v -p codesigning` lists a
`Developer ID Application: … (TEAMID)` identity, and the existing `SIGN_ID` detection in the
`Makefile` picks it up with no edit — it already prefers Developer ID over the local cert.

---

## Phase 2 — A release build target

**Blocks:** everything downstream. **Effort:** half a day.

The debug path in `Makefile` is already close to right: it stages outside the synced tree, it
strips xattrs, it signs the framework before the app, and it applies the hardened runtime. The
release path differs in four specific ways.

### 2.1 Secure timestamp

`make app` signs with `--timestamp=none`. **Notarization refuses a signature without a secure
timestamp.** The release target must use plain `--timestamp` (which contacts Apple's timestamp
server, so it needs network and is a little slow — that is the whole point of it).

### 2.2 Drop `disable-library-validation`

`Resources/NextNotes.entitlements` carries
`com.apple.security.cs.disable-library-validation`, and the comment beside it explains exactly
why: ad-hoc development builds have no stable Team ID, so hardened-runtime library validation
rejects the bundled `llama.framework`.

That reason **evaporates in a Developer ID build**, because we re-sign `llama.framework` with
the same Developer ID as the app, and library validation is satisfied by matching Team IDs.
Ship the release with a second entitlements file that omits it:

- `Resources/NextNotes.entitlements` — unchanged, used by `make app`
- `Resources/NextNotes.release.entitlements` — audio input + Apple events only

If the release build then fails to load `llama.framework`, the cause is a signing order or
Team ID mismatch, not a missing entitlement. Fix that rather than putting the entitlement back.

### 2.3 Release configuration and version stamping

`CONFIG := debug` is the default and `CFBundleShortVersionString` is a hand-edited `0.1.0`. The
release target builds `-c release`, and stamps the version from the git tag:

```bash
VERSION=$(git describe --tags --abbrev=0 | sed 's/^v//')
BUILD_NUMBER=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"
```

`CFBundleVersion` as a monotonic commit count matters for Sparkle (Phase 7), which compares it
to decide whether an update is newer.

### 2.4 The `PAID_BUILD` flag

The release target passes `-DPAID_BUILD` through SwiftPM:

```bash
swift build -c release --scratch-path "$SCRATCH" -Xswiftc -DPAID_BUILD
```

`make build`, `make app`, `make run` and `make install` do not. That single flag is the entire
difference between the free source build and the paid one, and it should stay that small.

### 2.5 If we ever do want a universal binary

Not for v1 (decision 0.4), but write the trap down: a multi-arch SwiftPM build changes the
product path. `swift build --arch arm64 --arch x86_64` does **not** leave the binary at
`$(SCRATCH)/release/NextNotes`; it lands under `$(SCRATCH)/apple/Products/Release/NextNotes`.
The `BUILD` variable in the `Makefile` would need to follow. `llama.framework` is already
universal (`lipo -info` shows `x86_64 arm64`), so it needs no change.

**Acceptance:**

```bash
codesign --verify --deep --strict --verbose=2 "$HOME/Library/Caches/NextNotesBuild/Next Notes.app"
```

passes, and `codesign -dv --verbose=2` on the bundle reports `TeamIdentifier=<your team>`
rather than `not set`, plus `flags=0x10000(runtime)`.

---

## Phase 3 — Package, notarize, staple

**Effort:** half a day, most of it waiting on the first submission.

### 3.1 Store notarization credentials once

```bash
xcrun notarytool store-credentials nextnotes --key ~/private/AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
```

### 3.2 Build the disk image

For v1, plain `hdiutil` is enough:

```bash
hdiutil create -srcfolder "$BUNDLE" -volname "Next Notes" -fs HFS+ -format UDZO -ov "$OUT/NextNotes-$VERSION.dmg"
```

Later, `create-dmg` gives the drag-to-Applications window with a background image, which is
what people expect from a paid Mac app. Worth doing before launch if there is time; not worth
blocking on.

The bundle is 52 MB — the models are downloaded at first use (484 MB for s1-mini, 2.7 GB for
Qwen3.5-4B), so the DMG stays small and the download is fast. Say so on the download page:
people should not be ambushed by a 2.7 GB fetch after install.

### 3.3 Sign the DMG, submit, staple

```bash
codesign --force --sign "$SIGN_ID" --timestamp "$OUT/NextNotes-$VERSION.dmg"
xcrun notarytool submit "$OUT/NextNotes-$VERSION.dmg" --keychain-profile nextnotes --wait
xcrun stapler staple "$OUT/NextNotes-$VERSION.dmg"
```

When notarization is rejected — and the first one usually is — the log is the whole story:

```bash
xcrun notarytool log <submission-id> --keychain-profile nextnotes
```

### 3.4 Verify it the way a buyer will experience it

Signature checks pass on things that still fail for a real download, because a real download
carries a quarantine flag. Reproduce that:

```bash
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$OUT/NextNotes-$VERSION.dmg"
xcrun stapler validate "$OUT/NextNotes-$VERSION.dmg"
spctl -a -vvv -t exec "/Volumes/Next Notes/Next Notes.app"
```

`spctl` must say **`source=Notarized Developer ID`**. Anything else and the download is not
finished, whatever the earlier steps printed.

Best of all, test the DMG on a Mac that has never seen this project. A first launch on the
build machine proves almost nothing.

**Acceptance:** on a clean Mac, double-clicking the downloaded DMG and dragging to
Applications produces an app that opens with the ordinary "downloaded from the Internet"
confirmation and nothing else — no "unidentified developer", no System Settings detour.

---

## Phase 4 — Licensing in the app

**Effort:** two days. **Depends on:** nothing. Can be built in parallel with Phases 1–3.

### 4.1 Format

A licence is a signed payload, delivered as one line of text:

```
NN1.<base64url(payload)>.<base64url(signature)>
```

The payload is JSON:

```json
{"v":1,"name":"Ada Lovelace","email":"ada@example.com","order":"ls_9f2c…","issued":"2026-09-14"}
```

The signature is Ed25519 over **the base64url payload string exactly as delivered**, not over a
re-serialization of the parsed JSON. This removes canonicalization from the problem entirely:
there is no key ordering or whitespace question, because the bytes that were signed are the
bytes that arrive.

`issued` is carried from day one even though v1 licences are perpetual, so that a future
"updates included for 12 months" policy (decision 0.6) can be introduced without invalidating
anything already sold.

### 4.2 Verification

`CryptoKit` has everything needed, so no dependency is added:

```swift
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Self.publicKeyBytes)
guard key.isValidSignature(signature, for: Data(payloadString.utf8)) else { return .invalid }
```

The public key is a 32-byte literal in the source. It is public — that is what "public key"
means — and it being visible in a public repo costs nothing.

### 4.3 Files to add

| File | Purpose |
|---|---|
| `Sources/NextNotes/Licensing/License.swift` | The payload type, parsing, Ed25519 verification |
| `Sources/NextNotes/Licensing/LicenseStore.swift` | Reads/writes the licence and the trial start date. Follow the existing Application Support convention — see `DictionaryStore.fileURL` |
| `Sources/NextNotes/Licensing/Entitlement.swift` | The single `enum { licensed, trial(daysLeft:), expired }` the UI asks. Returns `.licensed` unconditionally when `PAID_BUILD` is not defined |
| `Sources/NextNotes/UI/Settings/LicenseSettingsTab.swift` | Paste-a-key field, status, purchase link. Sits alongside the existing nine tabs in `Sources/NextNotes/UI/Settings/` |

`Entitlement.swift` is where the whole "sell the convenience" decision becomes code, and it is
worth a comment in the house style saying so — the next person to read it should understand
that the `#if PAID_BUILD` is a product boundary, not an oversight.

### 4.4 Behaviour

- **First launch** of a paid build records the trial start and says so plainly. No account, no
  card, no email.
- **During the trial** there is nothing modal and nothing recurring. A quiet line in the
  Settings and the menu bar is enough. A dictation app that interrupts you while you dictate
  has destroyed its own demo.
- **On expiry**, dictation and meeting recording stop; a panel offers Buy and Enter Key.
  Settings, existing meetings, existing notes, the dictionary and everything already on disk
  stay fully accessible, forever (decision 0.7).
- **Pasting a key** verifies offline and instantly. Malformed key, wrong signature and expired
  trial are three different messages, because "invalid licence" tells a paying customer
  nothing.
- **The trial is trivially resettable** by deleting a file. That is fine and expected. See the
  opening section.

**Acceptance:** with `-DPAID_BUILD`, a fresh install shows a 7-day trial, a key generated by
Phase 5 unlocks it with the network off, and a key with one character changed is refused.
Without the flag, `make install` behaves exactly as it does today.

---

## Phase 5 — Issuing licences

**Effort:** half a day for the CLI, another half for automation.

### 5.1 The signing key

Generate an Ed25519 keypair once. **The private key never touches the repo, CI, or any
server we do not control.** It lives in the password manager and on the release machine, and
that is all. Compromise means re-keying every future build and honouring every key already
issued — recoverable, but expensive, so treat it like the `.p12`.

### 5.2 `Tools/makelicense.swift`

A single-file Swift script, in the same spirit as the existing `Tools/makeicon.swift`:

```bash
swift Tools/makelicense.swift --name "Ada Lovelace" --email ada@example.com --order ls_9f2c
```

It prints the key. Nothing else. This is enough to launch with — for the first weeks, minting a
key by hand when an order email arrives is a two-minute task, and doing it manually is the
fastest way to learn what the automated version actually needs to handle.

### 5.3 Automating it later

When manual issuance stops being charming: a small Cloudflare Worker (or DO Function) that
takes the merchant's order webhook, mints the licence, and emails it. The private key lives in
the Worker's secret store. Until volume justifies it, do not build this — a webhook that is
wrong at 2am is worse than an inbox.

**Acceptance:** a key minted by the CLI unlocks a `PAID_BUILD` app with the Mac offline.

---

## Phase 6 — Checkout

**Effort:** a day, mostly account verification.

### 6.1 Merchant of record, not raw Stripe

There is already a Stripe account (`ProductFlo`), and a Payment Link would work today. But
Stripe is not a merchant of record: selling software to consumers across borders makes **us**
responsible for registering, collecting, filing and remitting VAT and sales tax in every
jurisdiction we sell into. For a one-time-purchase product from a small team, that obligation
outweighs the fee difference by a wide margin.

Use a merchant of record. It becomes the legal seller and absorbs all of it, for roughly
**5% + $0.50** per transaction:

- **Lemon Squeezy** — now part of Stripe; the most polished one-time digital product flow, with
  native licence key generation and file delivery.
- **Polar** — developer-focused, similar terms, smaller.
- **Paddle** — independent, strongest for anything that later becomes B2B or subscription.
- **Stripe Managed Payments** — Stripe's own MoR product, which keeps everything on the account
  that already exists. Worth checking first for exactly that reason.

Note that we do **not** need the merchant's licence key system, because our keys are minted in
Phase 5 and verified offline. Their key feature is a convenience for the order record, not the
mechanism.

### 6.2 Set up

1. One product, one price (decision 0.2), one currency, one-time.
2. Checkout collects name and email — nothing else. Both go into the licence payload.
3. Delivery email carries: the key, install instructions, the download link, and how to reach a
   human.
4. A stated refund policy, honoured without argument. For a $39 app, arguing costs more than
   refunding.

### 6.3 The App Store is not an option here

Worth recording so it stops being re-asked: Next Notes cannot ship on the Mac App Store,
because it cannot be sandboxed. `Resources/NextNotes.entitlements` already says why — a
system-wide `CGEventTap` and global Accessibility access are both impossible inside the App
Sandbox. That also rules out StoreKit's own one-time in-app purchase, which is why we are
building Phases 4–6 at all.

---

## Phase 7 — Updates

**Effort:** a day. **Depends on:** Phase 1.

Without an updater, everyone who buys is frozen on the build they downloaded, and "we ship the
build and keep shipping it" was half of what they paid for.

Use **Sparkle 2** via SwiftPM. It is the standard, it works with Developer ID, and it does not
need the XPC service variants because this app is deliberately unsandboxed.

1. Add the dependency to `Package.swift`.
2. Generate the EdDSA (signing-for-updates) keypair with Sparkle's `generate_keys`. This is a
   **second, separate** key from the licence key in Phase 5. Do not reuse one for the other.
3. Add `SUFeedURL` and `SUPublicEDKey` to `Resources/Info.plist`.
4. Publish `appcast.xml` alongside the DMGs. It can live in `docs/` and be served by the same
   App Platform site, which keeps the whole distribution story on one domain.
5. Add a *Check for Updates…* item to the app menu — `NextNotesApp.swift` already has a
   `CommandGroup(after: .appInfo)` block that is the natural home.
6. Sign each release with `sign_update` and paste the signature into the appcast entry.
   `generate_appcast` does this for a directory of DMGs.

**Acceptance:** a build with version `1.0.0` installed from a DMG finds, downloads, verifies
and installs `1.0.1` from the appcast without the user visiting the website.

---

## Phase 8 — Release automation

**Effort:** a day. **Depends on:** Phases 1–3, 7.

`.github/workflows/macos.yml` currently runs only the dictionary contract, and its comment says
the runner image does not have macOS 26. **That comment is now stale** — `macos-26` went
generally available for GitHub-hosted runners in February 2026, on Apple silicon. The app
target can now build in CI, which means the whole release can.

Add `.github/workflows/release.yml`, triggered on `v*` tags:

1. `runs-on: macos-26`
2. Import the `.p12` into a temporary keychain
3. `make release` (Phase 2)
4. Package, notarize, staple (Phase 3)
5. `sign_update` and regenerate the appcast (Phase 7)
6. Upload the DMG to the GitHub Release for the tag
7. Commit the updated `appcast.xml` to `docs/`

Secrets required:

| Secret | From |
|---|---|
| `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` | Phase 1.3 |
| `KEYCHAIN_PASSWORD` | invented per-run |
| `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8_BASE64` | Phase 1.4 |
| `SPARKLE_ED_PRIVATE_KEY` | Phase 7.2 |

**The licence signing key from Phase 5 is not on this list and must never be added to it.** CI
signs *builds*, never licences.

Also update the existing `macos.yml`: with `macos-26` available, the app target itself can now
be built in CI, so a broken app build stops being something only discovered locally.

### Where the DMG lives

Not in `docs/`. The App Platform site serves `docs/` from git, and committing a 52 MB binary
per release will bloat the repository permanently. Use **GitHub Releases** — free, fast,
already tied to the tag, and the appcast can point straight at the asset URL. Only
`appcast.xml` goes in `docs/`.

---

## Phase 9 — The landing page

**Effort:** half a day. **Depends on:** a download existing.

`site/src/sections/CTA.tsx` currently says, accurately: *"There is no signed release yet, so
you build it yourself."* That sentence is the thing that changes.

The new CTA shows **both paths, without hiding either**:

- **Primary:** Buy — $N, one-time, macOS 26 or later, Apple silicon. Downloads the notarized
  DMG.
- **Secondary:** Build from source — links to the repo, still says `make install`, still true.

Being straightforward about the second path is not a leak, it is the pitch. This app's entire
argument is that it does not spy on you, and the source being public and buildable is the only
evidence of that anyone can actually check. Hiding the free path would trade away the reason
people trust the paid one.

Also needed:

- A short pricing line — what is included (all updates), what is not
- The disk requirement stated up front: the app is a small download, the models are 484 MB and
  2.7 GB and are fetched on first use
- `site/public/sitemap.xml` updated if a `/buy` route is added
- The `REPO_URL` constant in `site/src/lib/motion.ts` stays; a new download constant joins it

Deploy with the existing `npm run deploy`, which builds, commits `docs/`, pushes, and verifies
the live bundle — do not hand-deploy around it.

---

## Phase 10 — Legal and licence hygiene

**Effort:** half a day. Do it before the first sale, not after.

- **An EULA.** Short, plain, linked from checkout and from the app's About. What is sold is a
  licence to use the binary; the source remains under its own licence.
- **Repository licence — there isn't one.** Checked: no `LICENSE` file, and GitHub reports no
  licence for the repo. Under copyright's default, that means all rights reserved: the source
  is *visible* but nobody has been granted the right to use, modify or redistribute it.

  That default quietly protects the paid build, but it also sits awkwardly next to a landing
  page that tells people to clone the repo and run `make install` — we are inviting a use we
  have not granted. Resolve it deliberately, one way or the other:

  - **Source-available, all rights reserved.** Add a short `LICENSE` that grants personal use
    and building for yourself, and withholds redistribution and resale. Keeps the audit story
    ("read the code, build it yourself, verify we don't phone home") while making the
    convenience the only thing anyone can legitimately sell.
  - **A real open-source licence** (MIT, Apache-2.0). Maximally trustworthy, and it permits
    someone else to build, sign and sell our app. In practice almost nobody does — but decide
    it on purpose rather than by omission.

  Given the strategy, the first is the better fit. Either way this stops being undecided
  before the first sale.
- **Refund policy**, stated at checkout (Phase 6.2).
- **Third-party notices.** `llama.cpp` is MIT, FluidAudio has its own terms, and the vendored
  orb geometry has a `LICENSE` beside it in
  `Sources/NextNotes/UI/Components/ThinkingOrbs/`. Collect them into one notices file shipped
  in the bundle.
- **Model licences — check these specifically.** The app points at
  `unsloth/Qwen3.5-4B-GGUF` and `superwhisper/s1-mini-GGUF`. We do not redistribute either
  (the user's own machine downloads them, per `ModelDownloader.swift`), which helps a great
  deal, but a commercial product directing users to fetch them still needs their terms read.
  `s1-mini` is the one to read first.
- **Recording consent.** The app records meetings and calls. The README already reasons about
  this properly, and Settings already defaults ad-hoc calls to *Ask before recording* for
  exactly this reason. Make sure the site and EULA say plainly that consent law varies and the
  user is responsible — a paid product invites a scrutiny a side project does not.

---

## Launch checklist

- [ ] Developer ID certificate and App Store Connect API key are in the password manager
- [ ] `make release` produces a stapled DMG
- [ ] `spctl -a -vvv -t exec` reports `source=Notarized Developer ID`
- [ ] Installed and launched on a Mac that has never built this project
- [ ] Trial starts, counts down, and expires correctly in a `PAID_BUILD`
- [ ] A CLI-minted key unlocks it with the Mac in airplane mode
- [ ] A tampered key is refused, with a message that says *which* thing was wrong
- [ ] `make install` from a clean clone still has no gate at all
- [ ] Sparkle finds and installs a newer build end to end
- [ ] Checkout completes, the delivery email arrives, and its download link works
- [ ] A refund can be issued in under a minute
- [ ] Landing page shows both paths, with the disk requirement stated
- [ ] EULA, refund policy and third-party notices are live and linked

---

## Cost summary

| Item | Cost |
|---|---|
| Apple Developer Program | $99 / year |
| Notarization | $0, unlimited |
| Merchant of record | ~5% + $0.50 per sale |
| DMG hosting (GitHub Releases) | $0 |
| Appcast hosting (existing App Platform site) | $0 |
| CI (`macos-26` runners, public repo) | $0 |
| Licence infrastructure | $0 — offline verification, no server |

Fixed cost to be able to sell at all: **$99/year.**

---

## Explicitly out of scope for v1

Recorded so they do not creep in:

- **Windows.** `windows/` builds and is exercised in CI, but per the README has not had a real
  microphone/key/injection session on Windows hardware. It is not a thing to sell yet.
- **Subscriptions, team and volume licences.** The licence format in Phase 4 does not prevent
  them later. Adding them now doubles the surface for no first-sale.
- **A customer account portal.** Losing a key is an email, and answering that email is a
  conversation with a customer — which, in the first hundred sales, is worth more than the
  portal.
- **Anti-piracy of any kind.** See the top of this document.
