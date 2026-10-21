# Sound link (MeshCore Open TAK)

Short messages and share links sent as tones from the speaker and heard on the
microphone, using [ggwave](https://github.com/ggerganov/ggwave) (MIT). Wadamesh
TAK does the same on a T-Deck and T-Display P4.

## Share by sound

A T-Deck has no camera, so it can't scan a QR code. Any phone or radio can
play a share link as sound instead:

- **Channels → share a channel**: **Play by sound**, under the QR code.
- **Channels → Add → Scan** and **Contacts → Scan**: the **ear** button
  listens instead of using the camera.
- **Settings → Sound link**: **Play my contact** and **Play a channel**.

The link is the one the QR code holds (`meshcore://channel/add?...`,
`meshcore://contact/add?...`), so nothing about it is new: anyone who hears a
channel link can join that channel, the same as anyone who sees its QR code.

## Messages, Wavest-compatible

**Settings → Sound link** sends and hears messages in the format of
[Wavest](https://github.com/bennjordan/Wavest), so a Wavest page in a browser,
another phone or a radio can join in:

| Heard / sent | Meaning |
|---|---|
| `U:<callsign>\|<text>` | plain |
| `E:<callsign>\|AES:<base64>` | AES-256-GCM, key = SHA-256(passkey), 12-byte IV first |
| `E:<callsign>\|XOR:<base64>` | Wavest's fallback, read only |

- **Callsign**: your node name by default.
- **Passkey**: optional. Encrypts what you send and opens messages sent with the
  same passkey. It keeps a chat unreadable to bystanders, but the key is an
  unsalted hash of the passkey, so it is not the mesh's encryption.
- **Sound**: audible normal / fast (Wavest's default) / fastest, or ultrasound
  (phones only: radio microphones and speakers can't do it).
- One message is up to 140 bytes on the air: about 120 characters plain, 60
  with a passkey, and takes a few seconds.

### Bridge to a channel

Pick a channel and everything heard is posted there as
`[Wavest] callsign: text`. With **Play this channel's new messages as sound**,
the channel's new messages are played too, so people nearby with only a
browser can follow and reply. While the phone plays, it ignores what its own
microphone hears, and it never re-plays the `[Wavest]` lines it posted, so the
bridge doesn't echo.

The bridge runs while the Sound link screen is open.

## Checking a one-time pad

An OTP Pad screen shows the pad's **check code**: the same code on two devices
means they hold the same pad. After scanning a pad by QR, tap **Play the check
code** on one device and **Listen for a check code** on the other (or read the
codes out). A code heard on the Sound link screen is compared with every pad
here. The code is the first 8 bytes of SHA-256 over a fixed label and the whole
pad, the same on Wadamesh TAK radios, and reveals nothing usable about the pad.
The pad itself is never sent by sound: anyone in earshot could record it.
