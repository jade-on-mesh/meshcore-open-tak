# Themes, Chat Backgrounds & Holiday Themes

Themes change the app's colors, icons, map markers, and (optionally) chat backgrounds. Everything here is stored on this device only; nothing is sent to the radio or the mesh.

## How to Access

**Settings → App Settings → Appearance → Color theme** opens the Themes screen. The tile's subtitle shows the theme in use ("MeshCore" for the standard theme), with a color swatch when a custom or preset theme is active.

## Chat Style and Chat Icons

Two more Appearance controls change only the chats, and work with any theme:

- **Chat style:** the tile opens a picker with a preview of each style, in light or dark as the app is now.
  - **MeshCore Open TAK** is the theme's own bubbles.
  - **Wadamesh TAK** gives frosted-glass bubbles: the chat background shows blurred through them. Yours are dark teal, and each sender's bubbles, name and avatar are in their own colour, the same colour a Wadamesh TAK standalone gives them.
  - **MeshCore Open Classic** is the app as it was before chat styles: its own bubbles, and people's colours from its six-colour palette rather than the official app's.
  - **MeshCore Classic** looks like the official MeshCore app. Everyone else's bubbles are light grey with black text, in dark mode too, with every corner rounded the same. Each person's avatar and name take the colour the official app gives them: it's worked out from the name, so a person has the same colour in both apps. The avatar shows the name's first emoji, or its initials in white. Your own bubbles are blue. As in the official app, the time, hops and path hash size go on one quiet line under each bubble instead of inside it (`5:38AM • 3 Hops • 1-byte`, with the date on an earlier day's, `22/Oct 11:07AM • 6 Hops • 1-byte`; `Direct` for a message that came straight from the sender). Under a channel message of yours it says `Heard 5 Repeats` with a tick once repeaters have been heard passing it on, and the time and the send's status until then. Each day starts under its full date (`24 October 2026`, today's too) in bold grey between two grey lines.
  - **Signal** looks like the Signal app. Your bubbles are Signal's blue with white text, and everyone else's are plain grey (light by day, dark at night) with no border. Every corner is rounded the same, a sender's name is in their colour, and their avatar is a pastel circle with their initials in a deeper shade of it.
  - **iPhone** looks like Messages on an iPhone: your bubbles iOS blue, everyone else's light grey by day and dark grey at night, every corner rounded the same, a sender's name small and grey, and avatars grey circles with white initials.
  - **Android** looks like Google Messages (Material You): your bubbles soft blue with dark blue text by day, deep blue with light text at night; others' grey; names and avatars (a white initial) in each person's colour.
  - **mIRC** is a chat log rather than bubbles: every line on the left as `<nick> message` in a monospace font, yours named too, no avatars, and each nick in one of mIRC's colours (the dark ones lifted at night, the bright ones deepened by day so they read).
  - **ICQ** is the classic ICQ message window: no bubbles, each message under its sender's `Name (time):` line, yours in red and theirs in blue, plain text beneath.
  - **Discord** has no bubbles either: each message has an avatar on the left (one of Discord's default avatar colours, with a white initial), the name in the person's colour, and the text below.

  The chat screen's header and message box follow the style too, as its app draws them:
  - **MeshCore Classic:** the MeshCore app's slate header (at night) with a round avatar, a large name and **Channel Messages** (or the channel's type and region) under it. The box is a pill with ⊕ and the send arrow inside it, the character count (`0/127`) always under it, and "Send a message...".
  - **Signal:** the header on the chat's background with an avatar, a pill-shaped box, "+" on its left, and Signal's blue round send button.
  - **iPhone:** a centred avatar with the name small under it, a round grey "+", and an outlined box with the blue ↑ inside it.
  - **Android:** an avatar and name, a filled pill box ("Text message"), and the send button as a soft blue circle.
  - **Discord:** "# name" in bold, a grey "+" circle, a filled box saying "Message #name" (or "@name"), and the blurple send button.
  - **mIRC:** a monospace title and a square monospace input line.
  - **ICQ:** a square box and a **Send** button.

  The app's own styles keep the app's header and box. Where a style's app has no microphone, the voice message button still takes the send button's place while the box is empty.

  The **New messages** line follows the style: Discord's red line with a red **NEW** tag at its end; mIRC's plain red marker line; Signal's grey chip; a small grey caption for iPhone; a grey rule for ICQ; MeshCore Classic's thin red line either side of the words in bold red, as the official app draws it; and the app's pill (in the style's accent) for the rest.
A person's colour, on their avatar and name, comes from their name, the same way the official MeshCore app and Wadamesh TAK work it out. So a person has the same colour in this app, in the official app and on a standalone, in every chat style but MeshCore Open Classic.
- **Brighter chat icons:** fills each avatar circle with its colour, with the initials or icon in black or white, in place of the faint tint.

## Light / Dark and Color Theme

Appearance has two related controls:

- **Theme** (System / Light / Dark): the brightness of the standard MeshCore theme.
- **Color theme**: the standard MeshCore theme, a built-in preset, a holiday theme, or one of your own.

A custom or preset theme sets its own brightness (a dark background makes a dark theme), so while one is active, none of the System / Light / Dark buttons is selected. Tapping one of them goes back to the standard MeshCore theme in that mode.

## Themes Screen

The screen has three sections. Tap a theme to use it right away; the active theme is marked as selected.

### My themes

Themes you created or imported. Each has a menu with **Edit**, **Copy theme code**, **Export to file**, and **Delete**. Deleting the active theme returns to the standard theme.

### Built-in

- **MeshCore**: the standard colors, following the Light / Dark setting.
- Presets: Forest, Ocean, Ember, Grape, High Contrast, Paper, Mint, and Sky.

Preset menus offer **Customize a copy** (opens the editor on a copy under "My themes") and **Copy theme code**. Presets themselves can't be edited.

### Holidays

Halloween, Thanksgiving, Christmas, and New Year's themes, each with its own colors, chat background picture, tab and send icons, and map markers. You can pick one at any time, like any other theme. This section also holds the **Switch automatically** toggle; see [Automatic holiday themes](#automatic-holiday-themes).

## Automatic Holiday Themes

**Switch automatically** is **off by default**; turn it on to get holiday themes. (It used to be on by default; updating turns it off once for everyone, so if you want it, turn it on again.) While it is on, each holiday's theme is shown in place of your own theme from **17 days before the holiday until the end of the holiday itself**:

| Holiday | Date | Automatic theme starts |
|---|---|---|
| Halloween | October 31 | October 14 |
| Thanksgiving | Fourth Thursday of November (US) | 17 days before (Nov 5–11, depending on the year) |
| Christmas | December 25 | December 8 |
| New Year's | January 1 | December 15 |

When windows overlap, the nearest upcoming holiday wins. A holiday keeps its theme through its own day, and the next holiday takes over the day after (for example, Christmas runs through December 25 and New Year's from December 26). Dates use the device's local calendar, and the app checks for a date change at midnight (and at least hourly), so the theme switches without restarting.

Your own choice is never changed: the holiday theme only covers it. When the window ends, your theme comes back by itself. While a holiday theme is on automatically, the Themes screen shows a note ("… theme is on automatically. Your own theme comes back after the holiday.") and tags that holiday's tile **On automatically**.

### Keeping your own theme

- **For the current holiday only**: pick any theme, or tap System / Light / Dark in App Settings. Your choice sticks for the rest of that holiday; the next holiday switches automatically again.
- **For all holidays**: turn off **Switch automatically** on the Themes screen. Your own theme returns immediately.

Turning **Switch automatically** back on also forgets an earlier "for this holiday only" choice, so the current holiday's theme shows again. Picking the holiday theme that is already on automatically doesn't change your saved theme, so your own theme still comes back after the holiday.

## Creating and Editing a Theme

Tap **Create theme** (or **Edit** / **Customize a copy**) to open the editor. A live preview shows chat bubbles and a switch in the new colors.

- **Name** (required)
- **Background**: the main background color. A dark background makes a dark theme. Surfaces, text, and bubbles are derived from it.
- **Accent**: buttons, highlights, and your own chat bubbles. A warning appears when the accent is hard to see on the background.
- Colors can be chosen from swatches or entered as a hex color.
- **Chat background**: none, a color, or a picture, with a fade slider. It is shown in chats that have no background of their own. Turn on **Use in every chat** to also replace backgrounds set on individual chats.
- **Icons**: swap the Contacts, Nodes, Channels, and Map tab icons, the send button, the Settings icon, and the Repeater, Room, and Sensor avatars. Tap an icon to choose another named icon or **Use a picture** from your gallery; **Use the default icon** resets it. Pictures are stored as lossless JPEG XL.
- **Map markers**: swap the map markers for chat nodes, repeaters, rooms, sensors, and your own position the same way.

**Save and use** saves the theme and makes it active.

## Sharing Themes

- **Copy theme code** copies a single theme as text. Share it any way you like; the recipient uses **Paste theme code** (Themes screen ⋮ menu) to add it.
- **Export to file** (one theme) and **Export my themes** (all of yours, ⋮ menu) write a `.jsonl` file, one theme per line. On Android and iOS it opens the share sheet, on desktop a save dialog, and on web the file downloads.
- **Import from file** (⋮ menu) accepts `.jsonl`, `.json`, or `.txt`. Invalid lines are skipped, and themes identical to one you already have aren't added twice.

Imported themes appear under "My themes"; importing doesn't switch to them.

## Map

The map follows the active theme: panels, accent color, a tint over the map tiles, and the theme's map markers. See [Map & Location](map-and-location.md).

## Chat Backgrounds

Each direct chat and channel can have its own background. Open the chat, then **⋮ → Chat background**:

- **None**, one of 12 colors, or **Picture** (**Choose a picture** from your gallery).
- **Fade** (10–90%) blends the background toward the theme's surface color so messages stay readable.

Changes apply live behind the sheet and affect only that chat. If the active theme has **Use in every chat** on, the sheet says so, and the theme's background is shown until you turn that option off in the theme. Holiday themes include a background picture that appears in chats without their own background.

Backgrounds are tied to the channel or contact, not the radio, so they follow the chat if you connect a different radio. Pictures are re-encoded as JPEG XL; on web they are kept in browser storage.

## Holiday Message Animations

When a new message containing a holiday greeting arrives in, or is sent from, the chat you have open, a short full-screen animation plays: bats for "Happy Halloween", a turkey for "Happy Thanksgiving", Santa for "Merry Christmas", and fireworks for "Happy New Year". Greetings are recognized in all of the app's languages, whatever your own language setting, and case and punctuation are ignored. Hashtags like `#HappyNewYear` also count.

- Only new messages play; messages already in the chat when you open it, and synced messages more than 2 minutes old, stay quiet.
- Animations play any day of the year, not only during the holiday windows.
- Only one animation plays at a time. A greeting that arrives while one is playing, or within 5 seconds after it ends, is skipped (not queued), so a burst of greetings plays once.
- Touches pass through the animation.
- Turn them off with **App Settings → Appearance → Holiday message animations**. They are also skipped when the system's reduce-motion / remove-animations setting is on.
