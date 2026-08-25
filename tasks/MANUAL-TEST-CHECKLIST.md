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

---

# Phase 2 manual listening checklist — the tape transport

**Build**: rebuild `~/Desktop/FineTune-AU.app` from `feat/au-plugin-hosting` after T9.
**Gate**: 912 automated tests green (18 of them the transport wiring added in T9).

Same warning as Phase 1, and it matters more here: **nothing below has been heard by anyone.**
The tape has been proven offline against synthesized signals and a real ring buffer. Whether a
rewind sounds like a rewind is a question only your ears can answer.

The tape is **off by default and per app**. Arm it in the expanded row under **Tape**. It records
into memory only, never to disk, and turning it off throws the recording away.

---

## HEAR IT EARLY (five minutes, do this first)

*If any of these three fails, stop and tell me. Everything after them assumes they work.*

35. Play Spotify, expand its row, click **Tape**, turn the **Tape** switch on. Expect: a transport
    strip appears under the row header (visible collapsed too), the time slot starts counting up
    from `0:00`, and `LIVE` sits there as plain grey text, not a button.
36. Let it record 30 seconds, then drag the scrub thumb left by roughly a third of the bar.
    Expect: audio jumps back to what you heard ten-ish seconds ago, **without a click**, the time
    slot flips to an amber `−0:10`, and `LIVE` becomes a coloured button.
37. Press **LIVE**. Expect: you are back at present-time audio through a short crossfade, again
    **without a click or a gap**, and the slot goes back to counting recorded time.

---

## 9. Rewind and scrub
*Proves the ring, the read head, and the jump crossfade.*

38. With about a minute recorded, drag back 30 seconds and listen for a while. Expect: the right
    content, and quality **identical** to live. Any graininess, pitch wobble, or metallic edge
    is a bug, not a tape effect.
39. Drag the thumb all the way to the left. Expect: it stops at the oldest audio the tape still
    holds and keeps playing. It must never go silent or start clicking.
40. Drag to just short of the right end and release. Expect: it snaps back to `LIVE` rather than
    leaving you half a second behind.

## 10. Brake and speed
*Proves the rate ramp, which is the part most likely to sound wrong rather than broken.*

41. While rewound, press the **stop** button. Expect a **tape brake**: over about a second the
    audio slows and its pitch falls away to silence, like a deck spinning down. The amber
    `Stopped` chip appears the moment you press, while the ramp is still running (by design).
42. Press **play**. Expect it spins back up to speed, again over a ramp, not a hard cut.
43. Open **Tape** and set **Speed** to `0.5×`. Expect: half speed, pitch an octave down, and a
    `0.5×` chip on the strip. It should be smooth, not stuttery: stutter means the read head is
    skipping and is a hard fail.
44. Set `2.0×` while behind live. Expect: it fast-forwards, pitch rises, and when it catches up
    with live it returns to live on its own.
45. Set a speed while you are **at** live. Expect: nothing audible until you rewind. That is
    correct, not a broken slider: live is passthrough.

## 11. Loop
46. Rewind to a chorus, then press the **loop** button. Expect: the last ten seconds are marked on
    the bar, playback drops to the start of that region and loops it. The wrap point must be
    **click-free**.
47. Drag each loop handle. Expect: the region follows your finger, the loop keeps playing, and
    dragging one handle past the other pushes the other one along instead of crossing it.
48. Press the loop button again to clear it. Expect: playback carries on forwards from where it
    was, still behind live.

## 12. Save the tape (retro-record)
49. Press the **save** icon on the strip (or **Save** in the Tape panel). Expect: a brief spinner,
    then a tick, then Finder opens on `~/Music/FineTune/` with `Spotify <timestamp>.wav` selected.
    Open it in QuickTime. It must play the tape's audio, at the right speed and pitch, with no
    tearing or garbage at either end.
50. What the file contains is **volume and EQ only**: no plugin chain, no headphone correction, no
    loudness or limiter. If it sounds unprocessed compared to what you were hearing, that is why.
51. Press save twice in quick succession. Expect: exactly one file, and no error dialog. Music
    must keep playing normally throughout the save.

## 13. Device switches with the tape running
*Proves the tape survives what taps do not. Taps are rebuilt constantly, tapes are not.*

52. Rewind 20 seconds, then, **while it is playing the past**, switch output to another device at
    the same sample rate (built-in to another wired device). Expect: your position and the whole
    recording survive the switch. A brief dry window is fine, losing your place is not.
53. Now switch to **Bluetooth headphones**, which usually change the sample rate. Expect: the tape
    is **cleared**, a `Tape restarted` note appears for about ten seconds, you are back live, and
    recording starts over from zero. This is deliberate: recorded audio is in the old rate's time
    and there is no resampler.
54. Take or simulate a **phone call** (A2DP to SCO) with the tape armed and rewound. Expect the
    same clear-and-restart as step 53, no crash, and normal audio when the call ends.
55. Sleep the Mac with the tape armed, wake it. Expect: FineTune still works, the tape either
    survives or restarts cleanly, and no dropouts follow.
56. Rewind, then **pause Spotify entirely**. Expect: the past keeps playing out of FineTune even
    though the app is silent. This is the whole point of the feature and it has a specific
    mechanism behind it, so if playback dies when you pause, say so.

## 14. Length and persistence
57. Change **Tape length** to 1 minute while armed. Expect: the tape clears (the panel says so),
    and it now holds only a minute.
58. Set 15 minutes and watch memory in Activity Monitor. Expect roughly 350 MB and then **flat**.
    Growth over time is a leak and is a hard fail.
59. Quit FineTune, relaunch, play Spotify. Expect: the tape is still armed, at the same length,
    and empty. It lives in memory only, so an empty tape after relaunch is correct.

## 15. Regression: the tape must be inaudible when it is not being used
*The most important test in this file. An armed tape sitting at live is passthrough, so it must be
impossible to hear.*

60. Arm the tape on Spotify and **leave it at live**. Now re-run Phase 1 steps 31 to 33: EQ per
    app, AutoEQ, loudness compensation, VU meters, plugin chains, device switching, bypass.
    Everything must behave exactly as it did in Phase 1.
61. A/B it: with music playing, toggle the tape off and on a few times. Expect **no** change in
    level, tone, timing, or stereo image at the switch, and no click. Any audible difference at
    all means the passthrough path is not bit-exact and I want to know immediately.
62. Leave the tape armed and idle for ten minutes with music playing. Expect: no drift, no
    dropouts, CPU unchanged from Phase 1.

---

## Known limitations of the tape (by design, not bugs)

- **Keep pitch** is not built yet. The row is hidden, and speed always moves pitch, like real tape.
- **Pinned inactive apps have no Tape panel.** An app that is not playing has no tap, so there is
  nothing to record. Arm the tape once it is playing.
- **Memory only.** 1 minute is about 23 MB, 5 minutes 115 MB, 15 minutes 346 MB, per armed app.
  Turning the tape off or changing its length throws the recording away.
- **The save contains volume and EQ only** (step 50).
- **The `Stopped` chip leads the sound** by the length of the brake ramp: it appears on press, the
  audio takes about a second to stop.
- **The strip only moves while the popup is open.** It updates at the same rate as the VU meters.

## What to tell me

Same as Phase 1, plus one thing specific to the tape: if something sounds wrong, say whether it is
**a click** (a jump or crossfade problem), **a stutter** (the read head skipping), or **wrong
pitch or speed** (the rate path). Those three point at different code and the distinction saves a
whole debugging round.
