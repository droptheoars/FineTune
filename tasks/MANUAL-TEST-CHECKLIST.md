# Phase 1 manual listening checklist — AU plugin hosting

**Build**: `~/Desktop/FineTune-AU.app` (Debug, signed with your Apple Development cert)
**Branch**: `feat/au-plugin-hosting` · all automated gates green (1000+ tests, 39 of them AU-chain)

Everything below is **unverified by machine**. No agent launched this app. Types compile, tests
pass, and the realtime diff survived an adversarial review, but nothing here has been heard by
anyone. That is what you are for.

---

## 0. Before you launch (do not skip — protects your settings)

1. **Quit the running FineTune.** Yours is running from `/Volumes/FineTune` (the mounted DMG).
   Two instances share one settings file and will fight over audio taps.
2. Your settings are already backed up to the session scratchpad. If you want your own copy:
   `cp ~/Library/Application\ Support/FineTune/settings.json ~/Desktop/finetune-settings-backup.json`
3. Launch `~/Desktop/FineTune-AU.app`. **Click Allow** on the audio-recording prompt (this build
   has a different signature from the release one, so macOS asks again).
4. Play something in Spotify. Open the popup — Spotify should show a moving VU meter.

> **Schema warning**: this build writes settings v13. If you later run the released v1.9.0, it
> will rewrite the file as v12 and **silently drop every plugin chain**. Keep the backup.

---

## 1. RC-20 on Spotify
*Proves: add → instantiate → real plugin UI → audible processing → survives relaunch.*

1. Click Spotify's expand button (slider icon). The expanded row now has an **`EQ | Effects`** toggle.
2. Click **Effects**. Expect header `Default chain` and `No effects. Audio passes through unchanged.`
3. Click **Add Effect**. The picker opens with a **`For listening`** group pinned above everything else:
   RC-20, Cassette, Pro-R, Timeless 3, Saturn 2, OTT. Valhalla and soothe are further down under
   `All effects` — present, just not promoted.
4. Click **RC-20 Retro Color**. Expect: picker closes, row appears with a spinner, spinner clears
   within a second or two, header flips to `Custom chain`, and a one-time note appears beneath it.
5. **LISTEN.** Spotify should be audibly coloured. If it sounds untouched, the chain is not
   rendering — that is a hard fail, not a subtlety. Stop and tell me.
6. Click the **`macwindow`** icon on the row. RC-20's own UI opens in a floating window titled
   `RC-20 Retro Color — Spotify`.
7. Turn **Magnetic** and **Noise** well up. You should hear it immediately.
8. Click Finder to move focus away. The window must stay visible and on top.
9. Close the plugin window. The row must still be there, still enabled, still processing.
10. **Quit FineTune from the menu** (not force-quit — force-quit is the documented ≤60s tweak-loss window).
11. Relaunch → expand Spotify → Effects. Expect RC-20 present, `Custom chain`, same coloured sound,
    and clicking `macwindow` reopens it **with your knob positions**. The knobs are the real proof;
    matching audio alone could be coincidence.

## 2. Cassette on browser audio
*Proves the same cycle on a second vendor and a different tap.*

12. Play a YouTube video in Chrome or Safari. The browser appears in the app list.
13. Expand it → **Effects** → **Add Effect** → search `Cassette` → click it.
14. Listen for wow/flutter. Then repeat steps 6–11 for it.

## 3. TimePitch (speed without pitch)
*Proves a rate-changing plugin hosts cleanly at normal speed and degrades politely, not violently.*

15. On any playing app: **Add Effect** → scroll to the **`Speed`** group at the bottom. Confirm the
    footnote: `Speed plugins work fully in a later update. At speeds other than 1.0, audio will glitch.`
16. Click **AUNewTimePitch**. It should reach ready and audio should be **clean** — at rate 1.0 it
    should be inaudible. Note the latency reading in the header: expect roughly `≈ 85 ms` with the
    yellow lip-sync warning, which is correct, not a bug.
17. Open its window, move rate away from 1.0.
18. Within a few seconds a **`speedometer`** badge appears on the row. Audio degrades (jump-cuts if
    slower, stutter if faster) — that is expected and ruled to Phase 2. What must NOT happen: a crash,
    or memory growth. Watch Activity Monitor for a minute; it should stay flat.
19. Return rate to 1.0 — badge clears, audio recovers. Remove the slot.

## 4. Varispeed (speed with pitch)
20. Repeat 15–19 with **AUVarispeed**. Same expectations, except pitch rises and falls with speed.

## 5. Default chain + device switch
*Proves one default drives per-app instances and survives a device switch with plugin state intact.
**This is the test that was broken until the review caught it.***

21. Take an app you already gave a chain (Spotify with RC-20 from test 1). Add **Apple AUDelay**
    to it as well and set an obvious delay time in its window — its effect is unmistakable across a
    device switch, which is what step 23 tests.
22. Open that row's **`ellipsis.circle`** menu → **Save as Default Chain**. Nothing visibly changes
    here: Spotify keeps its own chain and still reads `Custom chain`.
23. Now play a **different** app with no custom chain (a browser tab). Its Effects tab should read
    `Default chain`, list RC-20 + AUDelay, and you should hear both. It is running its **own**
    instances, not sharing Spotify's.
24. Switch output **built-in → Bluetooth headphones**. Expect a brief dry window (roughly a third of
    a second), then the delay resumes **with its tail carrying through**, not restarting.
    *This is the bug the review caught: before the fix it went silent instead, and could falsely
    disable a healthy plugin.*
25. Switch back **Bluetooth → built-in**. Same expectation.
26. On the browser (the default-following app), choose **Remove All Effects**. Expect: that app loses
    its effects and flips to `Custom chain` with the fork note. **Spotify must be unaffected**, and any
    third default-following app must still hear RC-20 + AUDelay.
27. Then choose **Use Default Chain** on the browser — the default comes back and it plays through
    RC-20 + AUDelay again. That round trip is the fix for the destroy-everything menu: the destructive
    action is scoped to one app, and it is undoable.

## 6. Failure drill
*Proves a missing plugin degrades politely and its settings survive.*

28. Quit FineTune. Move RC-20's or Cassette's `.component` out of `/Library/Audio/Plug-Ins/Components`
    to your Desktop. (Use a third-party one — leave the Apple AUs alone.)
29. Relaunch, play the app that used it, open Effects. Expect the slot **still in its original
    position** with badge `Not installed`, and any other plugin in that chain still audible.
30. Quit, move the plugin back, relaunch. The slot revives — open its window and confirm the knobs
    are **your old settings**, not defaults.

## 7. Regression — the things that must not have broken
31. EQ still works per app, AutoEQ still applies, loudness compensation still works, VU meters move.
32. Switch devices with the chain **bypassed** and with **no chain at all** — behaviour identical to before.
33. Take or simulate a Bluetooth phone call (A2DP↔SCO transition) with a chain active — no crash.

## 8. Inactive apps
34. Pin an app, quit that app, expand it → **Effects**. The panel is there and edits persist across a
    FineTune relaunch. **Known limit**: "Open plugin window" does nothing until the app plays again —
    with no audio there is no sample rate, so no plugin instance exists yet.

---

## Known limitations (by design, not bugs)

- **Post-fader chain**: FineTune's volume slider feeds the plugins, so moving volume will pump
  compressor-style plugins. Documented, revisit only if it annoys you in practice.
- **Speed at rate ≠ 1.0** glitches. Real speed control needs the Phase 2 ring buffer.
- **Plugins run in-process** — a plugin that crashes takes FineTune with it. Same deal as every DAW.
  An unlicensed plugin (your soothe3, iLok) can throw a modal alert when *added to a chain*; browsing
  the picker never triggers it.
- **Device switch** leaves the incoming device dry for up to ~350ms, and the outgoing 50ms crossfade
  is unprocessed. Rare and brief.

## What to tell me

For any failure: which step, what you expected, what you heard, and whether the badge/UI said
anything. If audio breaks in a way that sounds like a *dropout or click* rather than a wrong effect,
say so explicitly — that points at the realtime path rather than the wiring.
