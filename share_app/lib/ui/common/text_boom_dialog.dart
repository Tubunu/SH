import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../app_theme.dart';
import '../search/search_page.dart';

/// 1:1 复刻 `TextDetailActivity`（文本大爆炸 / 自由复制分词面板）：
/// 将中文按常用字词片段、英文/数字/@/话题/链接按完整 token 切分，支持点选、全选、复制选中或直接搜索。
class TextBoomDialog extends StatefulWidget {
  final String text;

  const TextBoomDialog({super.key, required this.text});

  static Future<void> show(BuildContext context, String text) {
    final plain = RichTextParser.toPlain(text).trim();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: ShareColors.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => TextBoomDialog(text: plain.isEmpty ? text : plain),
    );
  }

  @override
  State<TextBoomDialog> createState() => _TextBoomDialogState();
}

class _TextBoomDialogState extends State<TextBoomDialog> {
  late final List<String> _tokens;
  final Set<int> _selected = <int>{};

  static final _tokenizer = RegExp(
    r'https?://[^\s]+'
    r'|#[^#\s]+#'
    r'|@[\u4e00-\u9fa5A-Za-z0-9_\-]+'
    r'|\[[^\]\s]{1,16}\]'
    r'|[A-Za-z0-9_.\-]+'
    r'|[\u4e00-\u9fa5]'
    r'|[^\s]',
  );

  @override
  void initState() {
    super.initState();
    _tokens = _tokenizer
        .allMatches(widget.text)
        .map((m) => m.group(0)!)
        .where((t) => t.trim().isNotEmpty)
        .toList();
  }

  String get _joinedSelected {
    final sorted = _selected.toList()..sort();
    return sorted.map((i) => _tokens[i]).join();
  }

  void _copy(String content) {
    if (content.isEmpty) return;
    Clipboard.setData(ClipboardData(text: content));
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制：${content.length > 24 ? '${content.substring(0, 24)}…' : content}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = _joinedSelected;
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Text(
                  '文本大爆炸',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: ShareColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '已选 ${_selected.length}/${_tokens.length}',
                  style: TextStyle(fontSize: 12, color: ShareColors.textSecondary),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    if (_selected.length == _tokens.length) {
                      _selected.clear();
                    } else {
                      _selected.addAll(List.generate(_tokens.length, (i) => i));
                    }
                  }),
                  child: Text(_selected.length == _tokens.length ? '清空' : '全选'),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          if (preview.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ShareColors.repostBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                preview,
                style: TextStyle(fontSize: 13.5, color: ShareColors.textPrimary),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Wrap(
                spacing: 6,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _tokens.length; i++)
                    FilterChip(
                      selected: _selected.contains(i),
                      label: Text(_tokens[i]),
                      selectedColor: ShareColors.accent.withValues(alpha: 0.22),
                      checkmarkColor: ShareColors.accent,
                      onSelected: (on) {
                        setState(() {
                          if (on) {
                            _selected.add(i);
                          } else {
                            _selected.remove(i);
                          }
                        });
                      },
                    ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: ShareColors.divider)),
              ),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: preview.isEmpty
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => SearchPage(initialKeyword: preview),
                              ),
                            );
                          },
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('搜索'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _copy(widget.text),
                    child: const Text('复制全文'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: preview.isEmpty ? null : () => _copy(preview),
                    child: const Text('复制选中'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
