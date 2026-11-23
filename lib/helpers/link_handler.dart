import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/l10n.dart';
import '../utils/platform_info.dart';
import '../helpers/snack_bar_builder.dart';
import '../services/app_settings_service.dart';
import '../widgets/hashtag_channel_join.dart';

class LinkHandler {
  static TextStyle defaultLinkStyle(BuildContext context, TextStyle base) {
    final brightness = Theme.of(context).brightness;
    final orange = brightness == Brightness.dark
        ? const Color(0xFFFFB74D)
        : const Color(0xFFE65100);
    return base.copyWith(color: orange, decoration: TextDecoration.underline);
  }

  /// The system text scale as a linear factor for [style]'s size.
  ///
  /// flutter_linkify only takes a `textScaleFactor` (default 1.0, which
  /// ignores the system font size), so the ambient [TextScaler] is sampled
  /// at the style's font size to keep Android's nonlinear scaling. The
  /// in-app chat text scale is already part of `style.fontSize`.
  static double systemTextScaleFactor(BuildContext context, TextStyle style) {
    final fontSize =
        style.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14;
    if (fontSize <= 0) return 1.0;
    return MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
  }

  /// Returns a [SelectableLinkify] on desktop or a [Linkify] on mobile.
  static Widget buildLinkifyText({
    required BuildContext context,
    required String text,
    required TextStyle style,
    TextStyle? linkStyle,
    VoidCallback? onSecondaryTap,
  }) {
    final effectiveLinkStyle = linkStyle ?? defaultLinkStyle(context, style);
    const options = LinkifyOptions(humanize: false, defaultToHttps: false);
    // A #hashtag opens (or adds) that hashtag channel.
    const linkifiers = [UrlLinkifier(), EmailLinkifier(), HashtagLinkifier()];
    void onOpen(LinkableElement link) {
      if (link.url.startsWith(hashtagLinkScheme)) {
        openOrJoinHashtagChannel(
          context,
          link.url.substring(hashtagLinkScheme.length),
        );
        return;
      }
      handleLinkTap(context, link.url, text: link.text);
    }

    final textScaleFactor = systemTextScaleFactor(context, style);

    if (PlatformInfo.isDesktop) {
      final linkify = SelectableLinkify(
        text: text,
        style: style,
        linkStyle: effectiveLinkStyle,
        options: options,
        linkifiers: linkifiers,
        onOpen: onOpen,
        textScaleFactor: textScaleFactor,
      );
      if (onSecondaryTap == null) return linkify;
      return Listener(
        onPointerDown: (event) {
          if (event.buttons & kSecondaryMouseButton != 0) onSecondaryTap();
        },
        behavior: HitTestBehavior.translucent,
        child: linkify,
      );
    }
    return Linkify(
      text: text,
      style: style,
      linkStyle: effectiveLinkStyle,
      options: options,
      linkifiers: linkifiers,
      onOpen: onOpen,
      textScaleFactor: textScaleFactor,
    );
  }

  /// An obvious web link: written out in full with http:// or https://, to
  /// an ordinary host name (ASCII letters, digits, dots and dashes, with a
  /// dot, no punycode "xn--" look-alike) and no "user@" part that could hide
  /// where it really goes. [text] is what the message showed; [url] what
  /// opens. App Settings > Messaging > "Open web links without asking" opens
  /// these straight away; everything else (bare names like example.com,
  /// email, other schemes) still asks.
  static bool isObviousWebLink(String text, String url) {
    final shown = text.trim().toLowerCase();
    if (!shown.startsWith('http://') && !shown.startsWith('https://')) {
      return false;
    }
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return false;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.userInfo.isNotEmpty) return false;
    final host = uri.host.toLowerCase();
    if (!RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$').hasMatch(host)) return false;
    if (host.split('.').any((label) => label.startsWith('xn--'))) return false;
    return true;
  }

  static Future<void> handleLinkTap(
    BuildContext context,
    String url, {
    String? text,
  }) async {
    final direct =
        context.read<AppSettingsService?>()?.settings.openObviousLinksDirectly ??
        false;
    if (direct && isObviousWebLink(text ?? url, url)) {
      await _launch(context, url);
      return;
    }
    // Show confirmation dialog
    final shouldOpen = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(context.l10n.chat_openLink),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.chat_openLinkConfirmation,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                url,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.chat_open),
          ),
        ],
      ),
    );

    if (shouldOpen != true) return;
    if (!context.mounted) return;
    await _launch(context, url);
  }

  static Future<void> _launch(BuildContext context, String url) async {
    try {
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (context.mounted) {
          showDismissibleSnackBar(
            context,
            content: Text(context.l10n.chat_couldNotOpenLink(url)),
            backgroundColor: Colors.red,
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.chat_invalidLink),
          backgroundColor: Colors.red,
        );
      }
    }
  }
}
