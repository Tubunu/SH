import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../app_theme.dart';
import '../common/segment_actions.dart';
import '../widgets/weibo_rich_text.dart';

/// 微博编辑历史 —— `/ajax/statuses/editHistory?mid=&page=`。
///
/// 原版从卡片菜单「编辑历史」进入，按版本倒序列出每一次修改的正文。
class EditHistoryPage extends ConsumerStatefulWidget {
  final Status status;

  const EditHistoryPage({super.key, required this.status});

  @override
  ConsumerState<EditHistoryPage> createState() => _EditHistoryPageState();
}

class _EditHistoryPageState extends ConsumerState<EditHistoryPage> {
  final List<Status> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await WeiboApi.instance.editHistory(widget.status.mblogid);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _humanize(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('编辑历史')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history_toggle_off, size: 40, color: ShareColors.textHint),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text('这条微博没有编辑记录',
            style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
      );
    }

    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, _) => Divider(
        height: 8,
        thickness: 8,
        color: ShareColors.pageBg,
      ),
      itemBuilder: (context, index) {
        final item = _items[index];
        final version = _items.length - index;
        return Container(
          color: ShareColors.cardBg,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: ShareColors.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      '第 $version 版',
                      style: TextStyle(fontSize: 11, color: ShareColors.accent),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    formatWeiboTime(item.createdAt),
                    style: TextStyle(fontSize: 11.5, color: ShareColors.textSecondary),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              WeiboRichText(
                html: item.textHtml,
                fontSize: 15,
                height: 1.45,
                color: ShareColors.textPrimary,
                linkColor: ShareColors.link,
                onTapSegment: (segment) => openRichSegment(context, segment),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _humanize(Object error) {
  final text = error.toString();
  final marker = text.indexOf('AnyhowException(');
  if (marker >= 0) {
    return text
        .substring(marker + 'AnyhowException('.length)
        .replaceAll(RegExp(r'\)+$'), '')
        .trim();
  }
  return text;
}
