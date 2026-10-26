# Walkie-talkie (push to talk)

Hold a button and talk: everyone on the channel who has MediaMesh hears you
about two seconds later, while you're still talking. When you let go, the talk
is saved in the chat as an ordinary voice message, so anyone who missed it can
play it later. Wadamesh TAK standalones take part too: they hear talks and can
talk back.

## Using it

1. Turn on **MediaMesh** (Settings → MediaMesh Settings): talks go out on
   radio2 only, like Open TAK's photos and voice. See [MediaMesh](media-mesh.md).
2. In a channel chat, or the team chat on the map, tap the **walkie-talkie**
   button next to the microphone.
3. **Hold to talk.** Let go to finish. On a computer, hold **Space** instead.
   A talk can be up to 20 seconds.

A talk goes only to the channel it's on: only people with that channel hear
it.

## In a DM

The walkie-talkie button is in DMs too. A talk there goes to that contact
alone: each second is sent straight to them along the route your radio knows,
on MediaMesh, as you speak, and they hear it as it arrives. When you let go it
is also sent to them as a voice message, so it's in the chat for both of you,
and they can fetch any second they missed.

- With no route to them yet, each second goes only to radios in range of
  yours, so they hear it live only if they're nearby. The voice message gets
  there either way. Send them a message first to learn a route.
- A DM talk plays as it arrives when voice DMs auto-play (Settings), or while
  that DM or its walkie-talkie is open.
- Like the packets of a voice message, a talk's audio isn't encrypted on the
  air: radios along the way could listen. The voice message itself is a DM.
- Apps and radios without DM talks just get the voice message.

Talks play by themselves as they arrive in the channel whose chat or
walkie-talkie you have open. **Play talks on every channel** (off by default)
plays every channel's talks while the app is running, like a scanner. The
status line shows who is talking. While someone is talking, the button
waits until they finish, as on a real radio. It's half duplex: while you talk,
nothing plays.

- **Reach: Repeaters** (the default) floods each second of speech through the
  MediaMesh repeaters, so the whole MediaMesh hears it. Expect 2–3 seconds of
  delay, more with each hop.
- **Reach: Direct** sends radio to radio, with no repeaters: only radios in
  range hear it live. It's a little faster and adds no repeater traffic. People
  out of range still get the voice message and can fetch it as usual.
- **Play talks on every channel** (off by default) plays talks from every
  channel as they arrive, not just the one you have open.
- **Mute voice in this channel** (also in the channel's ⋮ menu as **Mute
  voice**): its talks don't play live, even with its chat open (only with its
  walkie-talkie open), and its voice messages don't play by themselves. They
  wait in the chat for a tap.

A talk heard live isn't played again when its voice message arrives.

## In the chat

A talk shows in the chat as **Talk**, with the walkie-talkie icon and a
waveform of the speech instead of a plain voice message. The waveform appears
once the talk is on your radio (straight away when it was heard live; a flat
line until it's downloaded otherwise) and fills in with the accent colour as
it plays. Wadamesh TAK standalones show talks the same way.

## Airtime

A talk is Codec2 at 1200 bps: one packet per 1.04 seconds of speech, the same
packets a voice message uses. At MediaMesh's 250 kHz preset a packet takes
about 0.16 s on air, so each hop uses about a sixth of the channel while
someone talks. At the 125 kHz preset, packets through repeaters can't quite
keep up with speech: the talk still arrives, a little later the longer it
runs. Use **Direct** there for live talk.

The voice message announcing the talk is a normal channel message on the main
mesh, as for any voice message.

## On the air

Talk packets are channel data (GRP_DATA) of type `0x5643`, the same type as
Open TAK's channel photos and voice, so Wadamesh and keymindCascade send them
on radio2 only and MediaMesh repeaters relay them there:

| Packet | Bytes |
| --- | --- |
| Talk start | `[0x53][session id: 4, big-endian][mode: 1][name: UTF-8, up to 32]` |
| Talk audio | `[0x54][session id: 4][index: 1][flags: 1][Codec2 frames]` |

- `flags`: bit 7 is set on the talk's last packet (which may carry no audio);
  bits 0–4 are the VE3 mode (1 = Codec2 1200).
- Audio packet *i* is exactly packet *i* of the talk's VE3 voice message: 156
  bytes (26 frames), fewer in the last. Packets heard live complete the voice
  message, so playing it later needs no download.
- After the last packet, the talk is announced with
  `VE3:<id>:1:<packets>:<seconds> PTT` on the channel, with the same session
  id. The `PTT` caption marks it as a talk; versions that don't know it show
  "Voice message: PTT". A talk announced without it still shows as a talk to
  anyone who heard its packets live. The sender keeps it, and answers
  requests for missing packets like any voice message.

Listeners wait about half a second after the first packet before playing, so
a late packet doesn't leave a gap. A packet that hasn't come by the time it's
needed is skipped. A talk with nothing heard for 3.5 seconds has ended.

## Platforms

Talks play through the platform's own audio output: AudioTrack on Android,
AVAudioEngine on iOS and macOS. On Windows and Linux each second plays as a
short clip, so there can be a tiny gap between seconds. Recording uses the same
microphone setup as voice messages (Linux needs `pulseaudio-utils`).

Code: `lib/vox/walkie_wire.dart` (packets, jitter buffer, resampler),
`lib/vox/walkie_service.dart`, `lib/vox/walkie_sheet.dart`,
`lib/vox/walkie_audio.dart`, `PcmStreamChannel.kt`, and `MeshPcmStream` in
`AppDelegate.swift` / `MainFlutterWindow.swift`. Tests:
`test/vox/walkie_wire_test.dart` (golden bytes shared with Wadamesh TAK's
`test/test_walkie.cpp`).
