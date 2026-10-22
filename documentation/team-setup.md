# Sharing a team in one scan

Getting someone onto your team usually means sharing a channel, picking it as the team channel, adding the channels you watch, and setting MediaMesh to the right frequency. **Share team setup** puts all of that in one QR code, which can also be played by Sound link for a standalone that has no camera.

## Sharing

Team › Setup › **Share team setup** (once a team channel is picked) shows a QR code with:

- the **team channel** (its name and secret),
- the **channels you watch** (hashtag channels by name, private ones with their secret),
- your radio's **MediaMesh profile** (frequency, bandwidth, SF, CR), when radio2 is on.

**Play by sound** plays the same setup for Sound link. A long setup goes as two or three short parts, one after the other. Anyone who scans or hears it can join your team channel and see your positions, so mind where you show or play it.

Callsigns aren't in it (each person picks their own), and neither are roles: the team's role names come over the team channel once you've joined.

## Joining

Team › Setup › **Join a team**: scan the code on a teammate's phone or standalone, or tap the **ear** to listen for one played by sound. A sheet lists what joining does, each on its own switch:

- **Team channel**: added if this radio hasn't it, and team mode turned on with it.
- **Watch**: the channels added if needed, and their reports shown on the map.
- **MediaMesh**: this radio's radio2 set to the team's profile, for photos, voice and push-to-talk.

Wadamesh TAK standalones share and join the same codes (Team › Setup › Share team setup, and Sound link hears a team setup played nearby).

## The code

```
meshcore://team/join?n=<team channel>&s=<32 hex>[&w=<watched>,...][&m=<MHz × 1000>,<bandwidth Hz>,<sf>,<cr>]
```

A watched hashtag channel is its name (`%23icewatch`), a private one `name:<32 hex>`; names are percent-encoded so `,` and `:` only separate. Over sound, a link longer than one 140-byte message goes as `MCT:<id>:<i>/<n>:<piece>` parts.

Code: `lib/team/team_setup.dart` (the link and the parts; tested in `test/team/team_setup_test.dart` with golden strings Wadamesh TAK's test checks too) and `lib/team/team_setup_ui.dart`.
