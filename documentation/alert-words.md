# Alert words

Words or phrases that make a channel message count like an @mention. Set them for one channel, for every channel, or both. They live on this phone only: nothing about them goes over the air, and other apps and standalones don't see them.

## Where to set them

- **One channel:** the channel's ⋮ menu › **Alert words**. Add a word or phrase, tap ✕ on a chip to remove it, or **Clear all**. **Also use my global alert words** (on by default) adds the App Settings list to this channel's; turn it off to use only the channel's own.
- **Every channel:** App Settings › Messaging › **Alert words in all channels**, the same chips and field. **Notify for alert words** (on by default) sends a notification for a message with an alert word even in a channel set to **Mentions only**. A muted channel stays silent.

Up to 30 words per list, 40 characters each.

## How a word matches

- A word matches whole, with any capitals: `ice` matches "ICE" and "Ice," but not "nice", "icecream" or "ice2".
- A phrase matches as written, its words in order (any spacing between them): `unmarked vans` matches "two unmarked vans", not "vans unmarked".
- Punctuation in a word is matched literally (`5th & Main`).
- The text you see is checked (an OTP message's plaintext, a translation), and the untranslated original too.
- Your own messages and filtered messages never alert.

## What you see

- **Channels tab:** a dark-blue badge at the icon's top left counts unread channel messages with an alert word, opposite the red unread count.
- **Channel list:** the same dark-blue badge with a bell, next to the channel's red unread count.
- **In the chat:** the message gets a dark-blue frame, a bell chip naming the word (beside the sender's name), and the word highlighted in white on blue.

The count covers unread messages only: reading the channel clears it, as with the red count.

## For contributors

`AlertWordsService` (`lib/services/alert_words_service.dart`) holds the lists (a singleton, saved under the preference `alert_words_v1`) and builds the match pattern (`alertPattern`, `matchIn`). `MeshCoreConnector.getChannelAlertCount` / `getTotalChannelsAlertCount` count the unread matches; `_maybeNotifyChannelMessage` lets an alert word through Mentions only. The UI is `lib/widgets/alert_words_editor.dart` (the sheet and the App Settings section) and `lib/widgets/alert_word_badge.dart` (badge and chip); the highlight is `AlertWordHighlight`, read by LinkHandler's message text.
