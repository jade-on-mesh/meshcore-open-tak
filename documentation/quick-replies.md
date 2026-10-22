# Quick replies

One-tap answers, tied to the thing they answer, so "did anyone see that?"
gets an answer without typing. Wadamesh TAK standalones send and show the same
replies.

## Where

| Item | Answers | Where to tap |
| --- | --- | --- |
| A teammate's alert (SOS and the rest) | Copy, On my way, ETA…, Can't help | The full-screen alarm (answering also acknowledges it), or the teammate's sheet on the map while the alert is on |
| A teammate's report or pin | Seen it, On my way, Need backup, All clear | The report's or pin's sheet on the map |
| A watched report (#icewatch, #dronewatch…) | Seen it, On my way, Need backup, All clear | Tap the report in the Watch tab to open it |

*ETA…* asks for 5, 10, 20 or 30 minutes. Each person has one answer per item:
a new tap replaces their last one.

The answers show under the item: who, what, and how long ago. A collapsed
watch card shows a line such as "2 answered: Sam On my way, Lee Seen it". While
your own alert is on, your teammates' answers appear under the red *ALERT
ACTIVE* bar on the map, and each answer to your alert, report or pin also
comes as a notification.

## On the air

**Team items** go on the team channel as a small team message
(`[0x51]`, see `lib/team/team_reply_wire.dart`): the item's author and id, the
answer and an ETA in minutes. Older versions of the app ignore it.

**Watched reports** are answered on the report's own channel in plain text, so
every MeshCore client can read the answer:

```
On my way ↩3fa1
ETA 10 min ↩3fa1
```

`3fa1` is the report's reaction hash, the same 4-character id this app's emoji
reactions use (from the report's time, sender and first five characters), so
the answer is tied to that one report even when a bot posts many. Clients that
know the mark fold the answer into the report instead of listing it as a new
message; others show the line as written. Keep in mind that a watched channel
is usually public: everyone on it sees the answer and your name.
