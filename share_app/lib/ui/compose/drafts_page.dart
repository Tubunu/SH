import 'package:flutter/material.dart';

import '../../core/drafts.dart';
import '../app_theme.dart';
import '../compose/compose_page.dart';

/// 草稿箱 — local drafts, mirroring the original app's offline draft box.
class DraftsPage extends StatefulWidget {
  const DraftsPage({super.key});

  @override
  State<DraftsPage> createState() => _DraftsPageState();
}

class _DraftsPageState extends State<DraftsPage> {
  List<Draft> _drafts = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final drafts = await DraftStore.load();
    if (!mounted) return;
    setState(() {
      _drafts = drafts;
      _loading = false;
    });
  }

  Future<void> _edit(Draft draft) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ComposePage(initialText: draft.text, draftId: draft.id),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _delete(Draft draft) async {
    await DraftStore.remove(draft.id);
    if (mounted) _load();
  }

  String _formatTime(int ms) {
    if (ms <= 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    if (time.year == now.year && time.month == now.month && time.day == now.day) {
      return '今天 ${two(time.hour)}:${two(time.minute)}';
    }
    if (time.year == now.year) {
      return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
    }
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('草稿箱'),
        actions: [
          if (_drafts.isNotEmpty)
            TextButton(
              onPressed: () async {
                await DraftStore.clear();
                if (mounted) _load();
              },
              child: Text('清空', style: TextStyle(fontSize: 13, color: ShareColors.textSecondary)),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: ShareColors.accent,
        onRefresh: _load,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_drafts.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 110),
          Icon(Icons.drafts_outlined, size: 44, color: ShareColors.textHint),
          const SizedBox(height: 12),
          Text(
            '还没有草稿\n发微博时点「存草稿」就会保存到这里',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: ShareColors.textSecondary, height: 1.6),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _drafts.length,
      separatorBuilder: (_, _) => Container(height: 0.6, color: ShareColors.divider),
      itemBuilder: (context, index) {
        final draft = _drafts[index];
        return Dismissible(
          key: ValueKey(draft.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: const Color(0xFFE64545),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) => _delete(draft),
          child: InkWell(
            onTap: () => _edit(draft),
            child: Container(
              color: ShareColors.cardBg,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          draft.text.trim(),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.5,
                            height: 1.45,
                            color: ShareColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _formatTime(draft.updatedAt),
                          style: TextStyle(fontSize: 11.5, color: ShareColors.textHint),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _delete(draft),
                    icon: Icon(Icons.close, size: 18, color: ShareColors.textHint),
                    tooltip: '删除',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
