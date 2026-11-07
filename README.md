# Agora Call Recorder — Theos Tweak

Local-only call recording for an Agora-based app **you own**, with a
Settings menu to toggle recording, listen to past recordings, and
optionally upload a finished recording to your own backend / Twilio
**after** the call has ended. This tweak never streams or forwards
audio live to anywhere — it only ever touches a file that is already
closed and saved on disk.

## 1. Required: restrict the tweak to YOUR app

Open `control` and add a `Filter` block so the tweak only loads into
the one app you control, e.g.:

```
Filter:
  Bundles = ( com.yourcompany.yourapp );
```

Without this, the tweak would attempt to inject into every process —
replace `com.yourcompany.yourapp` with your real app's bundle ID
before building.

## 2. Required: confirm Agora's real method names for your SDK version

Agora's Objective-C method names for raw-audio-frame delegates differ
slightly between SDK versions, and some apps wrap the SDK in their own
class. Before building:

1. Pull the binary of your installed app (e.g. via `scp` from a jailbroken
   device, or from the IPA you built).
2. Run `class-dump` (or `ktool`/`Hopper`) against it and the embedded
   `AgoraRtcKit` framework to find:
   - The real class implementing `AgoraAudioFrameDelegate` in your app.
   - The exact selector for raw PCM frames (commonly
     `onRecordAudioFrame:` / `onPlaybackAudioFrame:` depending on SDK
     version).
   - The `AgoraAudioFrame` layout (buffer pointer, length, sampleRate,
     channels) so `extractPCMDataFromFrame:` in `Tweak.xm` can pull real
     bytes instead of returning `nil`.
3. Update `%hook` target class name and selector signatures in
   `Tweak.xm` to match exactly what you found.

## 2b. Raw Substrate hook (no Logos)

`Tweak.xm` (the original hook) uses Theos' Logos `%hook` sugar, which
Theos preprocesses into Substrate calls for you at build time.
`Tweak.m` is the same hook, written directly against CydiaSubstrate's
`MSHookMessageEx` API, with no `%hook`/`%orig`/`%new` macros — just a
plain Objective-C file with a `__attribute__((constructor))` entry
point that installs the hooks when the dylib loads. The Makefile below
now builds from `Tweak.m`, so the normal Theos build already produces
a straight Substrate dylib.

If you don't want to use Theos' `make` machinery at all, `build_standalone.sh`
compiles `AgoraRecorder.dylib` directly with `clang` against a
CydiaSubstrate SDK you point it at, and ad-hoc signs it with `ldid`.
In that case you also need `AgoraRecorder.plist` next to the dylib on
the device (same `Filter` purpose as the `control` file's Filter block,
but in MobileSubstrate's plist format) — edit its bundle ID before
installing, for the same reason described in step 1.

## 3. Build

```
export THEOS=/opt/theos
make package
make install   # or scp the .deb and install manually
```

This builds two things:
- `AgoraRecorder.dylib` — the Logos tweak that hooks Agora and writes
  WAV files to `Documents/AgoraRecordings` inside your app's sandbox.
- `AgoraRecorderPrefs.bundle` — a Settings.app page (via PreferenceLoader)
  with:
  - **Enable Recording** switch (off by default)
  - **Listen Live While Recording** switch (off by default) — plays the
    call back through the speaker/headphones in real time, locally, while
    it's being captured (see below)
  - **Speed Up 3x While Listening** switch (off by default) — only
    matters when live listening is on; see below
  - **Auto-Upload After Call** switch (off by default)
  - **Upload Endpoint URL** field — point this at your own backend
    endpoint, which can then forward the file to Twilio's Recording/Media
    API server-side (keeping your Twilio credentials off-device).
  - **Recordings** — opens a list of saved recordings with Play /
    Upload / Delete actions.

## 4a. Live listening + real 3x speed-up

`AgoraRecorder` can build a tiny `AVAudioEngine` graph
(`AVAudioPlayerNode → AVAudioUnitVarispeed → mainMixerNode → output`) the
moment a call starts, purely in memory. Every PCM chunk handed to
`appendPCMData:` is written to the WAV file as before, and — only if
**Listen Live While Recording** is on — is also converted to float32 and
scheduled on that player node, so it comes out of the device's
speaker/headphones close to real time.

`AVAudioUnitVarispeed` changes the **actual playback rate**, not just
pitch (unlike `AVAudioUnitTimePitch`), so setting its `rate` to `3.0`
genuinely plays the monitored audio back three times faster — pitch
rises along with it, same as physically speeding up a tape or an audio
file, which is what "real" x3 means here as opposed to a pitch-shift
effect. The rate is re-read every chunk, so flipping the **Speed Up 3x**
switch mid-call takes effect immediately. Both switches are read from the
same `com.yourname.agorarecorder` defaults suite as the rest of the
tweak's settings and default to off.

Two things worth testing on a real device before you rely on this:

- **Audio session category**: local monitoring needs the app's
  `AVAudioSession` category to allow simultaneous record + playback
  (e.g. `PlayAndRecord`). Agora apps normally already set this for the
  call itself, so the tweak does not change the category — if your host
  app happens to use something more restrictive, live listening will be
  silent until that's addressed.
- **Latency/echo**: playing the local mic signal back live, especially
  through the device speaker rather than headphones, can cause an echo
  the other party hears if their audio loops back through your mic. For
  a demo/thesis setting this is fine; for real use, headphones are the
  obvious fix, and matching the speed-change to a de-noised capture path
  rather than the first-stage Agora frame is a possible refinement.

Nothing about this feature touches the upload path — both switches are
only ever read locally, by code that writes to the speaker, never to the
network.

## 4. About the Twilio upload

The upload in `AgoraRecorder.m` posts a finished WAV file as an HTTPS
request to a URL you configure. It is intentionally a plain,
after-the-fact file upload — not a live audio stream, and not a Twilio
Voice SDK call. Keeping your real Twilio Account SID / Auth Token
server-side (rather than embedding them in the tweak) is strongly
recommended, since anything shipped in a dylib can be extracted.

## Notes

- Recording defaults to **off**; a user must explicitly enable it in
  Settings.
- Recordings are stored only in the app's own sandboxed Documents
  directory.
- This project assumes you have the legal right to record calls made
  through your own app — recording-consent laws vary by jurisdiction,
  so make sure your app discloses this to anyone being recorded.
