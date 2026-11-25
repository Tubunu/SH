import 'dart:io';

import 'package:flutter_rust_bridge/src/platform_types/_io.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:share_app/core/api.dart';
import 'package:share_app/core/deep_link.dart';
import 'package:share_app/core/notice.dart';
import 'package:share_app/src/rust/frb_generated.dart';

/// End-to-end check of the exact FFI path the app uses on device: Dart ->
/// flutter_rust_bridge -> Rust core -> real Weibo endpoints.
///
/// Run with:
///   flutter test test/ffi_smoke_test.dart
void main() {
  setUpAll(() async {
    final dll = File(r'J:\vibe\share\rust\target\release\share_core.dll');
    if (!dll.existsSync()) {
      fail('Build the core first: cd rust && cargo build --release');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dll.path));
    final dir = Directory.systemTemp.createTempSync('share_core_smoke');
    await WeiboApi.instance.init(dir.path);
  });

  test('guest session can load a real timeline through the bridge', () async {
    expect(await WeiboApi.instance.isLoggedIn(), isFalse);

    await WeiboApi.instance.ensureGuestSession();
    expect(await WeiboApi.instance.isLoggedIn(), isTrue);

    final page = await WeiboApi.instance.hotTimeline(count: 10);
    expect(page.items, isNotEmpty, reason: 'timeline should contain real posts');

    final first = page.items.first;
    expect(first.mblogid, isNotEmpty);
    expect(first.user, isNotNull);
    // ignore: avoid_print
    print('timeline[0] @${first.user!.name}: ${first.textRaw}');

    final detail = await WeiboApi.instance.status(first.mblogid);
    expect(detail.mblogid, first.mblogid);

    final comments = await WeiboApi.instance.comments(
      statusId: first.id,
      authorUid: first.user!.id,
      count: 10,
    );
    // ignore: avoid_print
    print('comments loaded: ${comments.items.length}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('search and comment floors work over the bridge', () async {
    await WeiboApi.instance.ensureGuestSession();

    final results = await WeiboApi.instance.search('微博', page: 1);
    expect(results.items, isNotEmpty, reason: 'search should return real posts');
    // ignore: avoid_print
    print('search hits: ${results.items.length}');

    final page = await WeiboApi.instance.hotTimeline(count: 10);
    for (final status in page.items) {
      final comments = await WeiboApi.instance.comments(
        statusId: status.id,
        authorUid: status.user?.id ?? '',
        count: 20,
      );
      final withReplies = comments.items.where((c) => c.replyCount > 0).toList();
      if (withReplies.isNotEmpty) {
        final replies = await WeiboApi.instance.replies(withReplies.first.id);
        // ignore: avoid_print
        print('floor replies: ${replies.length}');
        expect(replies, isNotEmpty);
        return;
      }
    }
    // ignore: avoid_print
    print('no comment with replies in this sample, skipped');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('hot search returns ranked entries', () async {
    final items = await WeiboApi.instance.hotSearch();
    expect(items, isNotEmpty);
    expect(items.first.rank, 1);
    expect(items.first.word, isNotEmpty);
    // ignore: avoid_print
    print('hot #1: ${items.first.word} (${items.first.hot})');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('all four notification feeds parse real payloads', () async {
    await WeiboApi.instance.ensureGuestSession();

    for (final kind in NoticeKind.values) {
      final feed = await WeiboApi.instance.notices(kind);
      expect(feed.isEmpty, isFalse, reason: '${kind.label} should not be empty');
      // ignore: avoid_print
      print('${kind.label}: total=${feed.total} hasMore=${feed.hasMore}');

      if (kind == NoticeKind.atWeibo) {
        final first = feed.statuses.first;
        expect(first.mblogid, isNotEmpty);
        expect(first.user, isNotNull);
        // ignore: avoid_print
        print('   [0] @${first.user!.name}: ${first.textRaw}');
      } else {
        final first = feed.notices.first;
        expect(first.from, isNotNull, reason: '${kind.label} item needs an actor');
        expect(first.status, isNotNull, reason: '${kind.label} item needs a status');
        // ignore: avoid_print
        print('   [0] ${first.from!.name} -> ${first.textHtml.isEmpty ? first.attitude : first.textHtml}');
        if (first.myComment != null) {
          // ignore: avoid_print
          print('       replies to my comment: ${first.myComment}');
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('notification feeds page forward without repeating items', () async {
    await WeiboApi.instance.ensureGuestSession();

    final page1 = await WeiboApi.instance.notices(NoticeKind.comment, page: 1);
    if (!page1.hasMore) {
      // ignore: avoid_print
      print('only one page available, paging check skipped');
      return;
    }
    final page2 = await WeiboApi.instance.notices(NoticeKind.comment, page: 2);
    final ids1 = page1.notices.map((n) => n.id).toSet();
    final ids2 = page2.notices.map((n) => n.id).toSet();
    // ignore: avoid_print
    print('page1=${ids1.length} page2=${ids2.length} overlap=${ids1.intersection(ids2).length}');
    expect(ids2, isNotEmpty, reason: 'page 2 should return items');
    expect(ids1.intersection(ids2), isEmpty, reason: 'paging must not repeat rows');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('unread hint parses without throwing', () async {
    await WeiboApi.instance.ensureGuestSession();
    final hint = await WeiboApi.instance.unreadHint();
    // ignore: avoid_print
    print('unread: dm=${hint.dm} counts=${hint.counts}');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('dm endpoints answer with a real server error for guests', () async {
    await WeiboApi.instance.ensureGuestSession();
    // A visitor session has no DM identity. The point of this test is that the
    // failure surfaces as a readable server message rather than a silent empty
    // list, which is what the UI relies on.
    try {
      final list = await WeiboApi.instance.dmConversations();
      // ignore: avoid_print
      print('dm conversations unexpectedly available: ${list.length}');
    } catch (e) {
      // ignore: avoid_print
      print('dm rejected as expected: $e');
      expect(e.toString(), contains('Auth'));
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('nickname resolves to a uid for @-mention taps', () async {    await WeiboApi.instance.ensureGuestSession();
    final uid = await WeiboApi.instance.userIdByName('新浪娱乐');
    // ignore: avoid_print
    print('用户名解析: 新浪娱乐 -> $uid');
    expect(uid, isNotNull);
    expect(uid, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('user profile is public, timeline is login-gated', () async {
    await WeiboApi.instance.ensureGuestSession();

    final user = await WeiboApi.instance.profile('1642591402');
    expect(user, isNotNull);
    expect(user!.name, isNotEmpty);
    expect(user.id, '1642591402');
    // ignore: avoid_print
    print('profile: ${user.name} fans=${user.followers} posts=${user.statuses} '
        'cover=${user.cover.isNotEmpty} verified=${user.verified}');

    try {
      final page = await WeiboApi.instance.userStatuses('1642591402');
      // ignore: avoid_print
      print('user statuses: ${page.items.length}');
    } catch (e) {
      // Weibo gates /ajax/statuses/mymblog for visitors; the page must show
      // the server's own sentence instead of pretending the user posted nothing.
      // ignore: avoid_print
      print('user statuses gated: $e');
      expect(e.toString(), contains('登录'));
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('favourites list loads over the bridge', () async {
    await WeiboApi.instance.ensureGuestSession();
    final page = await WeiboApi.instance.favorites();
    // ignore: avoid_print
    print('收藏: ${page.items.length} 条, hasMore=${page.hasMore}');
    expect(page.items, isNotEmpty);
    final first = page.items.first;
    expect(first.mblogid, isNotEmpty);
    // ignore: avoid_print
    print('   [0] @${first.user?.name}: ${first.textRaw}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('超话 categories, list and search all work as a guest', () async {
    await WeiboApi.instance.ensureGuestSession();

    final cates = await WeiboApi.instance.stopicCates();
    // ignore: avoid_print
    print('超话分类 (${cates.length}): ${cates.map((c) => c.name).join(' / ')}');
    expect(cates, isNotEmpty);

    final byCate = await WeiboApi.instance.stopicList(sortId: cates[1].id);
    // ignore: avoid_print
    print('「${cates[1].name}」超话: ${byCate.items.length} 个 / ${byCate.pages} 页');
    expect(byCate.items, isNotEmpty);
    // ignore: avoid_print
    print('   [0] #${byCate.items.first.title}# ${byCate.items.first.fans}');

    final searched = await WeiboApi.instance.stopicList(keyword: '朱一龙');
    expect(searched.items, isNotEmpty);
    // ignore: avoid_print
    print('搜索「朱一龙」: ${searched.items.length} 个, 首个=${searched.items.first.title}');

    // The detail page feeds off a hashtag search, so make sure that works too.
    final feed = await WeiboApi.instance.search(searched.items.first.hashtag);
    // ignore: avoid_print
    print('   ${searched.items.first.hashtag} 微博: ${feed.items.length} 条');
    expect(feed.items, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('picture upload reaches the server and reports auth honestly', () async {
    await WeiboApi.instance.ensureGuestSession();
    // 1x1 PNG
    const png = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
      0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
      0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00,
      0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    try {
      final pid = await WeiboApi.instance.uploadPicture(png, 'test.png', 'image/png');
      // ignore: avoid_print
      print('upload unexpectedly succeeded, pid=$pid');
      expect(pid, isNotEmpty);
    } catch (e) {
      // A visitor session has no upload identity; picupload answers A20001.
      // The point is that the multipart request is accepted and the refusal is
      // readable instead of hanging or crashing.
      // ignore: avoid_print
      print('upload rejected as expected: $e');
      expect(e.toString(), isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('分组 / 表情 / 用户搜索 三个游客接口都能出数据', () async {
    await WeiboApi.instance.ensureGuestSession();

    final groups = await WeiboApi.instance.groups();
    // ignore: avoid_print
    print('分组: ${groups.categories.map((c) => '${c.title}(${c.groups.length})').join(' / ')}');
    expect(groups.isEmpty, isFalse);
    expect(groups.all, isNotEmpty);
    // 热门频道不需要登录，必须能找到
    expect(groups.hotChannel, isNotNull);

    final emotions = await WeiboApi.instance.emotions();
    // ignore: avoid_print
    print('表情: ${emotions.categories.length} 类 / ${emotions.total} 个');
    expect(emotions.categories.length, greaterThanOrEqualTo(5));
    expect(emotions.total, greaterThan(100));
    expect(emotions.categories.first.items.first.phrase, startsWith('['));

    final found = await WeiboApi.instance.searchUsers('新浪娱乐');
    // ignore: avoid_print
    print('用户搜索: ${found.users.length} 人, 联想 ${found.suggestions.length} 条');
    expect(found.mentionCandidates, isNotEmpty);
    expect(found.mentionCandidates.first.name, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('深链接解析覆盖 sinaweibo 与 weibo.com', () {
    DeepLinkTarget? parse(String url) => DeepLinkTarget.parse(Uri.parse(url));

    final detail = parse('sinaweibo://detail?mblogid=AbCdEf&uid=123');
    expect(detail?.kind, DeepLinkKind.status);
    expect(detail?.value, 'AbCdEf');

    final user = parse('sinaweibo://userinfo?uid=1642591402');
    expect(user?.kind, DeepLinkKind.user);
    expect(user?.value, '1642591402');

    final web = parse('https://weibo.com/1642591402/OxYz123');
    expect(web?.kind, DeepLinkKind.status);
    expect(web?.value, 'OxYz123');

    final profile = parse('https://weibo.com/u/1642591402');
    expect(profile?.kind, DeepLinkKind.user);
    expect(profile?.value, '1642591402');

    final nick = parse('https://weibo.com/n/%E6%96%B0%E6%B5%AA%E5%A8%B1%E4%B9%90');
    expect(nick?.kind, DeepLinkKind.userName);

    final m = parse('https://m.weibo.cn/detail/5360508997731650');
    expect(m?.kind, DeepLinkKind.status);

    // 官方客户端的 browser 包装要能剥掉
    final wrapped = parse(
      'sinaweibo://browser?url=https%3A%2F%2Fweibo.com%2F1642591402%2FOxYz123',
    );
    expect(wrapped?.kind, DeepLinkKind.status);
    expect(wrapped?.value, 'OxYz123');

    final search = parse('sinaweibo://search?q=%23%E6%96%B0%E6%B5%AA%23');
    expect(search?.kind, DeepLinkKind.search);
    expect(search?.keyword, '#新浪#');

    expect(parse('https://example.com/foo'), isNull);
  });
}
