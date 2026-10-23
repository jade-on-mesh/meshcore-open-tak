# AR view

*Map › Tools › AR View*: hold the phone up and look through the camera.
Teammates, team pins, watched reports with a position, and the Bloodhound
target float over the picture where they are, each with its distance. Nearer
ones sit lowest, by the faint horizon line; ones out of view are listed at the
left or right edge with an arrow. The heading is at the top. Tap a label to
start Bloodhound to it.

The screen stays in portrait while it is open.

## How it works and how good it is

It is a compass overlay, not ARCore/ARKit tracking: where the camera points
comes from gravity and the magnetic field (corrected for magnetic declination
where you are), and each label goes where its bearing from your GPS position
lies. Expect it to be off by a few degrees, more near steel, cars or magnets,
and the camera's field of view is an estimate, so far-off labels sit roughly
rather than exactly over things. Heights aren't used: everything sits near the
horizon. If the phone has no compass, the screen says so.

The camera picture uses the same camera as the QR scanner, so there's no new
permission. On the web, and if the camera can't start, the labels show over a
black background.
