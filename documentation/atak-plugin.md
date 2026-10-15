# ATAK Plugin

The MeshCore ATAK plugin (source and build steps in [`atak-plugin/`](../atak-plugin/README.md)) puts ATAK on the same team as MeshCore Open TAK. ATAK users appear on the team map with their callsign, team colour and role; app users, pins, SALUTE reports and alerts appear in ATAK.

## Letting the plugin use this app

With the plugin installed in ATAK on the same phone, it binds to this app the way the Meshtastic ATAK plugin binds to the Meshtastic app:

- The app keeps the radio connection. Keep it connected and team mode on, with a private team channel.
- Your position is beaconed once, by the app, using ATAK's callsign, team colour, role and fix while ATAK is running (Team screen shows **ATAK position**).
- Voice clips and photos sent from ATAK are encoded here (Mimi or Codec2, AV1), so they need the same models and libraries as sending from the app.
- Only ATAK can connect. Turn it off under **Team → TAK interop → ATAK plugin on this phone**.

The app must be running (it can be in the background). If it isn't, the plugin's mesh icon turns amber and asks you to open it.

The app also passes the radio's contacts, with their positions and last-advert times, and every channel's messages, so the plugin can show the wider mesh in ATAK: nodes on the map, and each channel other than the team channel as a contact to chat on. In app mode, direct messages from ATAK are sent and retried by the app as usual.

## Items shared from ATAK

ATAK users can share markers, 2525 units, shapes, routes and other CoT. The app shows them on the team map:

| Shared from ATAK | Shown in the app |
|---|---|
| Spot marker, waypoint, 2525 unit, SPI | A point coloured by affiliation (hostile diamond, friendly square...), with any attached photo |
| Line, route | A line (routes dashed) |
| Polygon, rectangle, circle | An outlined, lightly filled area |
| Casevac and other CoT relayed whole | Passed to your TAK server or local ATAK through the TAK gateway |

Tap a point or a shape's label for details, Bloodhound, or **Hide on this phone**. Items reach the TAK gateway with the same uids the plugin uses in ATAK, so a phone running both doesn't show duplicates.

## Wire format

The plugin adds three team message types (point `0x43`, shape `0x47`, chunk `0x58`), documented in `lib/team/team_wire_atak.dart`. Both implementations are checked against shared byte vectors in `test/team/atak_wire_test.dart` and the plugin's `TeamWireTest`.
