import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/emotions.dart';
import '../../core/models.dart';
import '../../core/offline_emoticons.dart';

/// Renders Weibo rich text: plain text + offline/online emoticon images + tappable
/// #topics#, @mentions, and links.
///
/// Prioritizes Share's offline bundled emoticons (`kShareEmoticonAssets`) and
/// falls back to runtime [EmoticonRegistry] URLs so modern emojis like `[淡淡的]`
/// render seamlessly while keeping plain-text taps unobstructed.
class WeiboRichText extends StatefulWidget {
  final String html;
  final double fontSize;
  final int? maxLines;
  final Color color;
  final Color linkColor;
  final FontWeight fontWeight;
  final double height;
  final void Function(RichSegment segment)? onTapSegment;

  const WeiboRichText({
    super.key,
    required this.html,
    this.fontSize = 16,
    this.maxLines,
    this.color = const Color(0xFF1A1A1A),
    this.linkColor = const Color(0xFF507DAF),
    this.fontWeight = FontWeight.w400,
    this.height = 1.45,
    this.onTapSegment,
  });

  @override
  State<WeiboRichText> createState() => _WeiboRichTextState();
}

class _WeiboRichTextState extends State<WeiboRichText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void initState() {
    super.initState();
    EmoticonRegistry.instance.version.addListener(_onEmotionsUpdated);
  }

  @override
  void dispose() {
    EmoticonRegistry.instance.version.removeListener(_onEmotionsUpdated);
    _disposeRecognizers();
    super.dispose();
  }

  void _onEmotionsUpdated() {
    if (mounted) setState(() {});
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final segments = RichTextParser.parse(widget.html);
    final emojiSize = widget.fontSize * 1.24;

    final spans = <InlineSpan>[];
    for (final seg in segments) {
      if (seg.kind == RichKind.emoji) {
        final assetPath = seg.assetPath ??
            kShareEmoticonAssets[seg.text] ??
            kShareEmoticonAssets['[${seg.text}]'];
        final onlineUrl = seg.imageUrl ?? EmoticonRegistry.instance.urlFor(seg.text);
        if (assetPath != null) {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Image.asset(
                assetPath,
                width: emojiSize,
                height: emojiSize,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Text(
                  seg.text,
                  style: TextStyle(fontSize: widget.fontSize, color: widget.color),
                ),
              ),
            ),
          ));
          continue;
        } else if (onlineUrl != null && onlineUrl.isNotEmpty) {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Image.network(
                onlineUrl,
                width: emojiSize,
                height: emojiSize,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Text(
                  seg.text,
                  style: TextStyle(fontSize: widget.fontSize, color: widget.color),
                ),
              ),
            ),
          ));
          continue;
        }
      }

      // Only attach TapGestureRecognizer on genuine links (@mention, #topic#, URL);
      // leaving plain text without a recognizer lets card/status taps pass through cleanly.
      final isLink = seg.kind == RichKind.mention ||
          seg.kind == RichKind.topic ||
          seg.kind == RichKind.link;
      TapGestureRecognizer? recognizer;
      if (isLink && widget.onTapSegment != null) {
        recognizer = TapGestureRecognizer()..onTap = () => widget.onTapSegment!(seg);
        _recognizers.add(recognizer);
      }

      spans.add(TextSpan(
        text: seg.text,
        style: TextStyle(
          fontSize: widget.fontSize,
          height: widget.height,
          color: isLink ? widget.linkColor : widget.color,
          fontWeight: widget.fontWeight,
        ),
        recognizer: recognizer,
      ));
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}
