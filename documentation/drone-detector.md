# Drone detector

The drone detector listens for **Remote ID**, the broadcast most drones made
since 2023 send by law (ASTM F3411 / Open Drone ID). The phone hears it over
Bluetooth and shows each drone's ID, position, height, speed and heading, and
usually where its operator stands. Wadamesh TAK standalones have the same
detector (app drawer > Drones), which also hears Wi-Fi broadcasts. Both post in
the same format, so a drone found by either shows on everyone's map.

Open it from **Team > Watch > Drones** (the chip next to *Auto-zoom*).

## Listening

Turn on **Listen for drones**. The phone scans for Bluetooth service data
`0xFFFA`, whether or not a radio is connected. It keeps listening while the app
runs, and pauses while the app searches for radios. Turn it off when you don't
need it: the scan uses battery.

Each drone heard is listed, newest first, with its position, height, speed,
heading, signal and when it was last heard. Tap one for the details: its type,
description, operator ID and operator position. **Show on map** opens the map
on the drone and its operator. A drone not heard for a minute is greyed; after
five minutes it's dropped.

A new drone plays a chime (turn it off with **Sound when a new drone
appears**). Drones with a position also appear in the Watch feed and on the
map, under *This phone*, like reports from watched channels: an orange marker
with the drone's label, its operator, and its direction of travel.

## Posting to the mesh

Pick an **Alert channel** (for example `#dronewatch`; Public isn't offered) and
turn on **Post drones there**. Each drone is posted at most once a minute, and
again only after it moves 200 m:

```
DRONE 1581F9DEV26590296G6G h120m 7.0m/s hdg90
https://maps.google.com/?q=47.60378,-122.34052
Op https://maps.google.com/?q=47.60531,-122.34016
```

Anyone watching that channel (Team > Watch here, Team > Watch on Wadamesh TAK
standalones) sees the drone on their map with its operator. A drone's card also
has **Post to the alert channel** for posting one by hand. Posting needs a
connected radio.

## Limits

- **Cooperative only.** Drones without Remote ID (older, home-built, or with it
  turned off) aren't detected.
- **Bluetooth only on the phone.** Phones can't capture the Wi-Fi beacons some
  drones use. A Wadamesh TAK standalone hears those, and its posts show up here.
- Bluetooth 5 long-range broadcasts are heard only where the phone's Bluetooth
  and operating system pass them on.
- Remote ID positions are what the drone reports; nothing here verifies them.

An operator's location is a person's location: keep your local rules about
recording and sharing it in mind.

## For developers

`lib/team/remote_id.dart` decodes the F3411 messages (Basic ID, Location,
Self ID, System, Operator ID and Message Packs). It keeps one track per drone,
lending each Bluetooth address's UAS ID to its other adverts, since legacy
adverts carry one message each. It also writes the post. The service is
`lib/team/drone_detector.dart`; local reports go into the Watch feed with
`WatchFeedService.putLocal`. `test/team/remote_id_test.dart` checks the same
broadcasts and post strings as Wadamesh TAK's `test/test_drone_core.cpp`.
