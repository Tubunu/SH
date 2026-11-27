import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_app/core/api.dart';
import 'package:share_app/core/dm.dart';
import 'package:share_app/core/emotions.dart';
import 'package:share_app/core/feed_cache.dart';
import 'package:share_app/core/groups.dart';
import 'package:share_app/core/models.dart';
import 'package:share_app/core/notice.dart';
import 'package:share_app/core/offline_emoticons.dart';
import 'package:share_app/core/session.dart';
import 'package:share_app/core/settings.dart';
import 'package:share_app/core/share_core.dart';
import 'package:share_app/src/rust/api/share_api.dart';
import 'package:share_app/src/rust/frb_generated.dart';
import 'package:share_app/ui/app_theme.dart';
import 'package:share_app/ui/common/long_image_page.dart';
import 'package:share_app/ui/common/share_actions.dart';
import 'package:share_app/ui/common/status_action_sheet.dart';
import 'package:share_app/ui/common/text_boom_dialog.dart';
import 'package:share_app/ui/compose/compose_page.dart';
import 'package:share_app/ui/detail/comment_floor_page.dart';
import 'package:share_app/ui/detail/likers_list.dart';
import 'package:share_app/ui/detail/repost_list_page.dart';
import 'package:share_app/ui/detail/status_detail_page.dart';
import 'package:share_app/ui/feed/feed_page.dart';
import 'package:share_app/ui/feed/status_card.dart';
import 'package:share_app/ui/login/login_page.dart';
import 'package:share_app/ui/media/gallery_page.dart';
import 'package:share_app/ui/profile/user_page.dart';
import 'package:share_app/ui/search/search_page.dart';
import 'package:share_app/ui/settings/about_page.dart';
import 'package:share_app/ui/shell/main_shell.dart';
import 'package:share_app/ui/shell/share_drawer.dart';
import 'package:share_app/ui/theme/theme_page.dart';
import 'package:share_app/ui/widgets/pic_grid.dart';
import 'package:share_app/ui/widgets/qr_code_box.dart';
import 'package:share_app/ui/widgets/weibo_rich_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    initialSettings = await AppSettings.load();
    await RustLib.init();
    tempDir = await Directory.systemTemp.createTemp('share_1to1_test_');
  });

  tearDownAll(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {
      // Windows keeps the active SQLite handle until test process exit.
    }
  });

  test('offline emoticons stage all 174+246 codes and 396 unicode emojis', () {
    expect(kSharePrimaryEmoticonCodes.length, 174);
    expect(kShareEmoticonAssets.length, greaterThanOrEqualTo(240));
    expect(kShareUnicodeEmojis.length, 396);
    expect(kShareEmoticonAssets['[微笑]'], isNotNull);

    final segs = RichTextParser.parse('你好[微笑] #测试[超话]# @测试员 https://t.cn/abc');
    expect(segs.any((s) => s.kind == RichKind.emoji && s.assetPath != null), isTrue);
    expect(segs.any((s) => s.kind == RichKind.topic && s.text == '#测试[超话]#'), isTrue);
    expect(segs.any((s) => s.kind == RichKind.mention && s.text == '@测试员'), isTrue);
    expect(segs.any((s) => s.kind == RichKind.link), isTrue);
  });

  test('21+1 theme palette and toolbar toggle rules match Share.apk', () {
    expect(ShareThemePreset.all.length, 22); // 21 visible + night_green_black
    final def = ShareThemePreset.byKey('elegant_purple');
    expect(def.themeColor, const Color(0xFFB693AE));
    expect(def.accent, const Color(0xFFDDA5AD));

    // Default tool_bar_color_theme=false keeps daylight toolbar white with #525252 icons
    ShareColors.apply(def, settings: const AppSettings(themeKey: 'elegant_purple'));
    expect(ShareColors.toolbarBg, const Color(0xFFFFFFFF));
    expect(ShareColors.toolbarFg, const Color(0xFF525252));

    // Enabling tool_bar_color_theme=true tints toolbar with themeColor
    ShareColors.apply(
      def,
      settings: const AppSettings(
        themeKey: 'elegant_purple',
        prefs: {'tool_bar_color_theme': true, 'accent_color_theme': true},
      ),
    );
    expect(ShareColors.toolbarBg, const Color(0xFFB693AE));
    expect(ShareColors.toolbarFg, const Color(0xFFFFFFFF));
    expect(ShareColors.accent, const Color(0xFFB693AE));
  });

  test('ShareCore SQLite 9-table persistence, .share_backup, WeSync & guest /2/* live API', () async {
    final initRes = await ShareCore.instance.init(customDataDir: tempDir.path);
    if (initRes.guestAid.isEmpty || initRes.guestGsid.isEmpty) {
      await ShareCore.instance.guestLogin();
    }
    final refreshed = await ShareCore.instance.init(customDataDir: tempDir.path);
    expect(refreshed.guestAid.isNotEmpty, isTrue);
    expect(refreshed.guestGsid.isNotEmpty, isTrue);

    // SQLite BLACK_LIST CRUD + .share_backup export/import
    final ruleId = await ShareCore.instance.blacklistUpsert(
      uid: 'u_test',
      key: '广告测试词',
      info: 'test',
      ruleType: 1,
    );
    expect(ruleId, greaterThan(0));
    final backup = await ShareCore.instance.blacklistExportBackup('u_test');
    expect(backup.contains('广告测试词'), isTrue);
    await ShareCore.instance.blacklistDelete(ruleId);
    final imported = await ShareCore.instance.blacklistImportBackup('u_test', backup);
    expect(imported, 1);

    // SQLite Drafts & History & Followers Pinyin
    final did = await ShareCore.instance.draftSave(
      const DraftDto(
        id: 0,
        uid: 'u_test',
        content: 'Rust SQLite 草稿测试',
        date: 1700000000000,
        urlsJson: '',
        targetStatusId: '',
        targetStatusJson: '',
        targetCommentId: '',
        targetCommentUserName: '',
        targetCommentContent: '',
        assignGroupIdStr: '',
        assignGroupType: 0,
        address: '',
        publishTiming: 0,
        isCommentOrigin: false,
        status: 0,
        isMention: false,
        state: 0,
        typeCode: 0,
        parentType: 0,
        extraJson: '',
      ),
    );
    expect(did, greaterThan(0));
    final drafts = await ShareCore.instance.draftList('u_test');
    expect(drafts.first.content, 'Rust SQLite 草稿测试');

    await ShareCore.instance.followersReplaceBatch(
      'u_test',
      '[{"id":"2001","screen_name":"王小明","pinyin_name":"wangxiaoming"}]',
    );
    final found = await ShareCore.instance.followersSearch('u_test', query: 'wxm');
    final foundFull = await ShareCore.instance.followersSearch('u_test', query: 'wang');
    expect(found.length + foundFull.length, greaterThanOrEqualTo(1));

    // WeSync roundtrip
    final frame = ShareCore.instance.wesyncEncode(11, 7, [123, 125]);
    final decoded = ShareCore.instance.wesyncDecode(frame);
    expect(decoded['cmd'], 11);
    expect(decoded['seq'], 7);

    // Live mobile /2/statuses/unread_hot_timeline with guest gsid + cum signature
    final hot = await ShareCore.instance.hotTimelineDual(count: 10);
    final statuses = hot['statuses'] as List?;
    expect(statuses, isNotNull);
    expect(statuses!.isNotEmpty, isTrue);

    // Live Dual-Protocol user profile & timeline via WeiboApi wrapper
    await WeiboApi.instance.init(tempDir.path);
    final profileRaw = await ShareCore.instance.userProfileDual('1642591402');
    final profileUser = User.fromProfilePayload(jsonDecode(profileRaw) as Map<String, dynamic>);
    expect(profileUser, isNotNull);
    expect(profileUser!.id, '1642591402');
    expect(profileUser.name.isNotEmpty, isTrue);

    final userTimelineRaw = await ShareCore.instance.userTimelineDual('1642591402', count: 5);
    debugPrint('userTimelineDual(1642591402) len=${userTimelineRaw.length} sample=${userTimelineRaw.substring(0, userTimelineRaw.length > 320 ? 320 : userTimelineRaw.length)}');
    final userTimelineMap = jsonDecode(userTimelineRaw) as Map<String, dynamic>;
    final userPosts = (userTimelineMap['statuses'] as List?) ??
        (userTimelineMap['cards'] as List?) ??
        (userTimelineMap['data']?['list'] as List?);
    expect(userPosts, isNotNull);

    // Live /2/comments/build_comments via commentsDual on a hot post with comments
    final commentTarget = statuses.whereType<Map<String, dynamic>>().firstWhere(
          (s) => ((s['comments_count'] as num?)?.toInt() ?? 0) > 2,
          orElse: () => <String, dynamic>{},
        );
    final commentSid = '${commentTarget['idstr'] ?? commentTarget['id'] ?? ''}';
    if (commentSid.isNotEmpty) {
      final rawComments = await ShareCore.instance.commentsDual(
        commentSid,
        authorUid: '${commentTarget['user']?['idstr'] ?? commentTarget['user']?['id'] ?? ''}',
      );
      final parsedComments = WeiboApi.extractCommentsFromPayload(
        jsonDecode(rawComments) as Map<String, dynamic>,
      );
      debugPrint('live commentsDual($commentSid) count=${parsedComments.length}');
      expect(parsedComments.isNotEmpty, isTrue);

      final parentWithReplies = parsedComments.firstWhere(
        (c) => c.replyCount > 0 || c.replies.isNotEmpty,
        orElse: () => parsedComments.first,
      );
      if (parentWithReplies.id.isNotEmpty) {
        final rawReplies = await ShareCore.instance.commentRepliesDual(
          parentWithReplies.id,
        );
        final pagedReplies = await WeiboApi.instance.repliesPaged(
          parentWithReplies.id,
        );
        debugPrint(
          'live commentRepliesDual(${parentWithReplies.id}) bytes=${rawReplies.length} '
          'parsed=${pagedReplies.items.length} inline=${parentWithReplies.replies.length} total=${parentWithReplies.replyCount}',
        );
        expect(rawReplies.isNotEmpty, isTrue);
        expect(pagedReplies.items.isNotEmpty, isTrue);
      }

      final rawUserSearch = await ShareCore.instance.searchTypedDual(
        '微博',
        searchType: 'user',
      );
      final parsedUserSearch = await WeiboApi.instance.searchTyped(
        '微博',
        type: 'user',
      );
      debugPrint(
        'live searchTypedDual(user) bytes=${rawUserSearch.length} users=${parsedUserSearch.users.length}',
      );
      expect(rawUserSearch.isNotEmpty, isTrue);
      expect(parsedUserSearch.users.isNotEmpty, isTrue);

      final rawReposts = await ShareCore.instance.repostListDual(commentSid);
      final parsedReposts = WeiboApi.instance.extractRepostsFromPayload(
        jsonDecode(rawReposts) as Map<String, dynamic>,
      );
      debugPrint('live repostListDual($commentSid) count=${parsedReposts.items.length} tip=${parsedReposts.tip}');
      expect(parsedReposts.items.isNotEmpty || parsedReposts.tip.isNotEmpty || rawReposts.isNotEmpty, isTrue);

      final rawLikers = await ShareCore.instance.likersDual(commentSid);
      final parsedLikers = WeiboApi.extractLikersFromPayload(
        jsonDecode(rawLikers) as Map<String, dynamic>,
      );
      debugPrint('live likersDual($commentSid) count=${parsedLikers.length}');
      expect(rawLikers.isNotEmpty, isTrue);
    }

    // Live Hot Search Categories via Dual-Protocol mobile cardlist + band_list
    final hotCats = await WeiboApi.instance.hotSearchCategories();
    debugPrint('live hotSearchCategories count=${hotCats.length} titles=${hotCats.map((c) => '${c.title}(${c.items.length})').join(',')}');
    expect(hotCats.length, greaterThanOrEqualTo(2));
    expect(hotCats.first.title, '实时热搜');
    expect(hotCats.first.items.isNotEmpty, isTrue);

    // Live LongText expansion on any long post returned from hot / profile feed
    final longTarget = [...statuses, ...?userPosts].whereType<Map<String, dynamic>>().firstWhere(
          (s) => s['isLongText'] == true,
          orElse: () => <String, dynamic>{},
        );
    final longId = '${longTarget['idstr'] ?? longTarget['id'] ?? ''}';
    if (longId.isNotEmpty) {
      final fullTxt = await WeiboApi.instance.longText(longId);
      debugPrint('live longText($longId) len=${fullTxt.length}');
      expect(fullTxt.isNotEmpty, isTrue);
    }
  });

  test('Dual-protocol parsers handle both mobile /2/* and web /ajax/* payloads', () {
    // DmConversation: mobile user_list + direct_message + Weibo date string
    final dmMob = jsonEncode({
      'user_list': [
        {
          'user': {'idstr': '12345', 'screen_name': 'Alice', 'avatar_large': ''},
          'direct_message': {
            'idstr': '999',
            'text': '你好 Share',
            'created_at': 'Sat Jun 22 18:07:52 +0800 2024',
          },
          'unread_count': 2,
        }
      ]
    });
    final convs = DmConversation.parseList(dmMob);
    expect(convs.length, 1);
    expect(convs.first.uid, '12345');
    expect(convs.first.name, 'Alice');
    expect(convs.first.preview, '你好 Share');
    expect(convs.first.timeMs, greaterThan(1700000000000));
    expect(convs.first.unread, 2);

    // NoticeFeed: mobile top-level attitudes & comments
    final likeMob = jsonEncode({
      'attitudes': [
        {
          'id': '777',
          'created_at': 'Sat Jun 22 18:07:52 +0800 2024',
          'user': {'idstr': '222', 'screen_name': 'Bob'},
          'status': {'idstr': '5001', 'text': '原博'},
        }
      ],
      'total_number': 1,
      'next_cursor': 0,
    });
    final parsedLike = NoticeFeed.parse(likeMob, NoticeKind.like);
    expect(parsedLike.notices.length, 1);
    expect(parsedLike.notices.first.from?.name, 'Bob');

    // UnreadHint: mobile /2/remind/unread_count
    final unreadMob = jsonEncode({
      'cmt': 3,
      'mention_status': 2,
      'mention_cmt': 1,
      'attitude': 4,
      'dm': 5,
    });
    final hint = UnreadHint.parse(unreadMob);
    expect(hint.countFor(NoticeKind.comment), 3);
    expect(hint.countFor(NoticeKind.atWeibo), 2);
    expect(hint.countFor(NoticeKind.atComment), 1);
    expect(hint.countFor(NoticeKind.like), 4);
    expect(hint.dm, 5);
    expect(hint.total, 15);

    // GroupSet: mobile /2/groups lists[]
    final groupsMob = jsonEncode({
      'lists': [
        {'idstr': '101', 'name': '特别关注', 'member_count': 12},
      ]
    });
    final gs = GroupSet.parse(groupsMob);
    expect(gs.all.length, 1);
    expect(gs.all.first.gid, '101');
    expect(gs.all.first.title, '特别关注');

    // User.fromProfilePayload: mobile userInfo wrapper
    final u = User.fromProfilePayload({
      'userInfo': {'id': 1642591402, 'screen_name': '新浪新闻'}
    });
    expect(u, isNotNull);
    expect(u!.id, '1642591402');
    expect(u.name, '新浪新闻');
  });

  testWidgets('MainShell bottom bar hides on scroll down and restores on downward swipe on ProfilePage',
      (tester) async {
    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = const AppSettings(
      themeKey: 'elegant_purple',
      prefs: {
        'navigation_hide_on_scroll': true,
        'navigation_position': 2,
        'fab_options': 0,
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((_) => SettingsNotifier(settings)),
        ],
        child: const MaterialApp(home: MainShell()),
      ),
    );
    await tester.pump();

    // Switch to Profile tab ('我').
    expect(find.byType(BottomAppBar), findsOneWidget);
    await tester.tap(find.text('我'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(BottomAppBar), findsOneWidget);

    // Scroll upward (finger moves up -> content scrolls down) to hide the bottom navigation bar.
    final profileList = find.byType(ListView).last;
    await tester.drag(profileList, const Offset(0, -180));
    await tester.pump();
    expect(find.byType(BottomAppBar), findsNothing);

    // Swipe downward (finger moves down -> scrolling back up on the short page) to restore it.
    await tester.drag(profileList, const Offset(0, 90));
    await tester.pump();
    expect(find.byType(BottomAppBar), findsOneWidget);
  });

  testWidgets('Pushed LoginPage shows BackButton so it can pop back', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                ),
                child: const Text('GoLogin'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('GoLogin'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text('登录微博账号'), findsOneWidget);
  });

  testWidgets('ThemePage renders 21 rows + bottom toggles without navigation crash', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: ThemePage()),
      ),
    );
    expect(find.text('淡雅紫'), findsOneWidget);
    expect(find.text('透明'), findsOneWidget);
    expect(find.text('自定义'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('普通主题标题栏颜色跟随主题'), 250);
    expect(find.text('普通主题标题栏颜色跟随主题'), findsOneWidget);
  });

  testWidgets('AboutPage 3-tap easter egg unlocks developer mode & TextBoomDialog segments text',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: AboutPage()),
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('版本号'));
      await tester.pump();
    }
    expect(find.text('开发者/隐藏功能已解锁'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TextBoomDialog(text: '测试大爆炸 #话题# Hello'),
        ),
      ),
    );
    expect(find.text('文本大爆炸'), findsOneWidget);
    expect(find.text('#话题#'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
  });

  test('v1.2 fixes: root_comments parsing, mobile video URLs, chronological sort, runtime emoji, tail labels', () {
    // 1. Mobile build_comments with empty `comments: []` + populated `root_comments`
    final commentPayload = <String, dynamic>{
      'comments': <dynamic>[],
      'root_comments': [
        {
          'id': 987654,
          'rootid': 987654,
          'created_at': 'Tue Nov 25 10:00:00 +0800 2025',
          'text': '测试评论 [淡淡的]',
          'like_counts': 12,
          'floor_number': 1,
          'user': {'idstr': '10001', 'screen_name': '路人甲'},
        }
      ],
    };
    final comments = WeiboApi.extractCommentsFromPayload(commentPayload);
    expect(comments.length, 1);
    expect(comments.first.textHtml, '测试评论 [淡淡的]');
    expect(comments.first.user?.name, '路人甲');

    // 2. Mobile video keys (mp4_720p_mp4, http://, pic_info.pic_big, object_id)
    final vidStatus = Status.fromJson({
      'idstr': '5123456789000001',
      'created_at': 'Tue Nov 25 10:00:00 +0800 2025',
      'text': '看视频',
      'page_info': {
        'type': 'video',
        'object_id': '1034:5123456',
        'pic_info': {
          'pic_big': {'url': '//wx1.sinaimg.cn/large/cover.jpg'}
        },
        'media_info': {
          'duration': 42,
          'mp4_720p_mp4': 'http://f.video.weibocdn.com/test720.mp4',
        },
      },
    });
    expect(vidStatus.isVideo, isTrue);
    expect(vidStatus.videoUrl, 'http://f.video.weibocdn.com/test720.mp4');
    expect(vidStatus.videoCover, 'https://wx1.sinaimg.cn/large/cover.jpg');
    expect(vidStatus.videoObjectId, '1034:5123456');

    // 3. Reverse chronological sort by status ID
    final unsorted = [
      const Status(id: '100', mblogid: 'a', createdAt: '', textHtml: 'old', textRaw: 'old', source: ''),
      const Status(id: '300', mblogid: 'c', createdAt: '', textHtml: 'new', textRaw: 'new', source: ''),
      const Status(id: '200', mblogid: 'b', createdAt: '', textHtml: 'mid', textRaw: 'mid', source: ''),
    ];
    WeiboApi.sortStatusesChronologically(unsorted);
    expect(unsorted.map((e) => e.id).toList(), ['300', '200', '100']);

    // 4. Runtime EmoticonRegistry resolves modern [淡淡的] emoji
    EmoticonRegistry.instance.registerPairs({
      '[淡淡的]': '//face.t.sinajs.cn/t4/appstyle/expression/ext/normal/dandande.png',
    });
    final emojiSegs = RichTextParser.parse('今天[淡淡的]啊');
    expect(
      emojiSegs.any((s) =>
          s.kind == RichKind.emoji &&
          s.text == '[淡淡的]' &&
          (s.imageUrl ?? '').startsWith('https://')),
      isTrue,
    );

    // 5. Typography comfortable line height + intl Weibo tail preset labels
    const defSettings = AppSettings();
    expect(defSettings.lineSpacing, closeTo(1.45, 0.02));
    expect(AppSettings.formatPublishTailLabel('intl'), '微博国际版 (Weibo.intl)');
    expect(AppSettings.formatPublishTailLabel('weico'), 'Weico客户端');
    expect(AppSettings.formatPublishTailLabel('none'), '不显示');
  });

  testWidgets('Tapping plain body text triggers StatusCard.onTap while #topic# triggers link callback',
      (tester) async {
    var cardTapped = 0;
    RichSegment? tappedSegment;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: StatusCard(
              status: const Status(
                id: '90001',
                mblogid: 'M90001',
                createdAt: '',
                textHtml: '这是一段非常清楚的正文内容',
                textRaw: '这是一段非常清楚的正文内容',
                source: '微博网页版',
              ),
              onTap: () => cardTapped++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.textContaining('这是一段非常清楚的正文内容'));
    await tester.pump();
    expect(cardTapped, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeiboRichText(
            html: '正文前缀 #测试话题# 后缀',
            onTapSegment: (seg) => tappedSegment = seg,
          ),
        ),
      ),
    );
    await tester.tapOnText(find.textRange.ofSubstring('#测试话题#'));
    await tester.pump();
    expect(tappedSegment?.kind, RichKind.topic);
    expect(tappedSegment?.text, '#测试话题#');
  });

  test('Reposts and likers payload extractors handle mobile and web fallback keys', () {
    final repostPayload = <String, dynamic>{
      'reposts': <dynamic>[],
      'hot_reposts': [
        {
          'idstr': '5001002',
          'created_at': 'Tue Nov 25 10:00:00 +0800 2025',
          'text': '热门转发语',
          'user': {'idstr': '3001', 'screen_name': '转发用户'},
        }
      ],
      'hot_desc': '已加载热门转发',
    };
    final reposts = WeiboApi.instance.extractRepostsFromPayload(repostPayload);
    expect(reposts.items.length, 1);
    expect(reposts.items.first.user?.name, '转发用户');
    expect(reposts.tip, '已加载热门转发');

    final likersPayload = <String, dynamic>{
      'users': <dynamic>[],
      'data': {
        'data': [
          {
            'user': {'idstr': '4001', 'screen_name': '点赞同学'}
          }
        ],
      },
    };
    final likers = WeiboApi.extractLikersFromPayload(likersPayload);
    expect(likers.length, 1);
    expect(likers.first.id, '4001');
    expect(likers.first.name, '点赞同学');
  });

  testWidgets('StatusCard separates outer card tap from inner retweet original-post tap',
      (tester) async {
    var outerTaps = 0;
    var innerTaps = 0;

    const original = Status(
      id: '92002',
      mblogid: 'M92002',
      createdAt: '',
      textHtml: '这是被引用的原微博文本区域',
      textRaw: '这是被引用的原微博文本区域',
      source: '微博网页版',
      user: User(id: 'u2', name: '原作者', avatar: ''),
    );
    const repost = Status(
      id: '92001',
      mblogid: 'M92001',
      createdAt: '',
      textHtml: '外层转发评价内容',
      textRaw: '外层转发评价内容',
      source: 'Share',
      user: User(id: 'u1', name: '转发者', avatar: ''),
      retweeted: original,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: StatusCard(
              status: repost,
              onTap: () => outerTaps++,
              onRetweetTap: () => innerTaps++,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.textContaining('外层转发评价内容'));
    await tester.pump();
    expect(outerTaps, 1);
    expect(innerTaps, 0);

    await tester.tap(find.textContaining('这是被引用的原微博文本区域'));
    await tester.pump();
    expect(outerTaps, 1);
    expect(innerTaps, 1);
  });

  testWidgets(
      'StatusDetailPage switches 评论/转发/赞 tabs without Duplicate GlobalKey crash and pushes original post on retweet tap',
      (tester) async {
    const original = Status(
      id: '91002',
      mblogid: 'M91002',
      createdAt: '',
      textHtml: '我是被引用的原微博正文内容',
      textRaw: '我是被引用的原微博正文内容',
      source: '微博网页版',
      user: User(id: 'u2', name: '原博作者', avatar: ''),
      reposts: 1,
      comments: 2,
      attitudes: 3,
    );
    const outer = Status(
      id: '91001',
      mblogid: 'M91001',
      createdAt: '',
      textHtml: '快看这条原微博',
      textRaw: '快看这条原微博',
      source: 'Share',
      user: User(id: 'u1', name: '转发博友', avatar: ''),
      retweeted: original,
      reposts: 5,
      comments: 3,
      attitudes: 7,
    );

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: StatusDetailPage(status: outer),
        ),
      ),
    );
    await tester.pump();

    // Default tab is 评论 (index 1).
    expect(find.byType(StatusDetailPage), findsOneWidget);
    expect(find.text('热门评论'), findsOneWidget);

    // Switch to 转发 (index 0) - previously crashed with Duplicate GlobalKey -> white screen.
    await tester.tap(find.text('转发 5').first);
    await tester.pump();
    expect(find.byType(RepostTabList), findsOneWidget);

    // Switch to 赞 (index 2).
    await tester.tap(find.text('赞 7').first);
    await tester.pump();
    expect(find.byType(LikersList), findsOneWidget);

    // Switch back to 评论 (index 1) - must stay intact and not white-screen.
    await tester.tap(find.text('评论 3').first);
    await tester.pump();
    expect(find.text('热门评论'), findsOneWidget);

    // Tap the quoted original tweet box inside the detail card -> pushes StatusDetailPage for original.
    final origFinder = find.textContaining('我是被引用的原微博正文内容').last;
    await tester.tap(origFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(BackButton), findsOneWidget);
    final pushedDetail = find.byType(StatusDetailPage).last;
    expect(find.descendant(of: pushedDetail, matching: find.text('原博作者')), findsOneWidget);
    expect(
      find.descendant(of: pushedDetail, matching: find.textContaining('我是被引用的原微博正文内容')),
      findsOneWidget,
    );
  });

  test('FeedCacheStore persists statuses, scrollOffset, and lastGroup across kills', () async {
    SharedPreferences.setMockInitialValues({});
    const status = Status(
      id: '88001',
      mblogid: 'M88001',
      createdAt: 'Wed Nov 25 18:00:00 +0800 2026',
      textHtml: '缓存测试微博正文内容',
      textRaw: '缓存测试微博正文内容',
      source: 'Share',
      user: User(id: 'u8', name: '缓存作者', avatar: ''),
      pics: [
        Pic(
          url: 'https://wx1.sinaimg.cn/orj360/abc.jpg',
          large: 'https://wx1.sinaimg.cn/large/abc.jpg',
          width: 800,
          height: 600,
        ),
      ],
      isLongText: true,
      liked: true,
      attitudes: 12,
    );

    await FeedCacheStore.instance.saveSnapshot(
      '123456',
      const CachedTimelineSnapshot(
        groupKey: 'all',
        items: [status],
        maxId: '88000',
        page: 2,
        hasMore: true,
        scrollOffset: 1425.5,
      ),
    );
    await FeedCacheStore.instance.saveLastGroup(
      '123456',
      const CachedGroupSelection(groupKey: 'group_777', title: '科技数码'),
    );

    final loaded = await FeedCacheStore.instance.loadSnapshot('123456', groupKey: 'all');
    expect(loaded, isNotNull);
    expect(loaded!.items.length, 1);
    expect(loaded.items.first.id, '88001');
    expect(loaded.items.first.pics.first.width, 800);
    expect(loaded.items.first.liked, isTrue);
    expect(loaded.scrollOffset, closeTo(1425.5, 0.01));
    expect(loaded.page, 2);

    final lastGroup = await FeedCacheStore.instance.loadLastGroup('123456');
    expect(lastGroup?.groupKey, 'group_777');
    expect(lastGroup?.title, '科技数码');
  });

  testWidgets('StatusCard hides 全文 hint and expands full text when fullText is true',
      (tester) async {
    const longStatus = Status(
      id: '77001',
      mblogid: 'M77001',
      createdAt: '',
      textHtml: '这是一条很长很长的微博第一行<br/>第二行<br/>第三行',
      textRaw: '这是一条很长很长的微博第一行\n第二行\n第三行',
      source: 'Share',
      user: User(id: 'u1', name: '长微博作者', avatar: ''),
      isLongText: true,
    );

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: StatusCard(status: longStatus, fullText: false)),
        ),
      ),
    );
    expect(find.text('全文'), findsOneWidget);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: StatusCard(status: longStatus, fullText: true)),
        ),
      ),
    );
    expect(find.text('全文'), findsNothing);
    expect(find.textContaining('这是一条很长很长的微博第一行'), findsOneWidget);
  });

  test('ShareActions deterministicImageName produces stable dedup names', () {
    expect(
      ShareActions.deterministicImageName(
          'https://wx3.sinaimg.cn/original/006abcgy1hv99test.jpg'),
      'share_006abcgy1hv99test',
    );
    expect(
      ShareActions.originalUrl('https://wx3.sinaimg.cn/orj1080/006abcgy1hv99test.jpg'),
      'https://wx3.sinaimg.cn/original/006abcgy1hv99test.jpg',
    );
  });

  testWidgets('GalleryPage separates 保存原图到手机 vs 保存所有原图到手机 cleanly',
      (tester) async {
    const singlePic = [Pic(url: 'https://example.com/bmiddle/1.jpg')];
    const multiPics = [
      Pic(url: 'https://example.com/bmiddle/1.jpg'),
      Pic(url: 'https://example.com/bmiddle/2.jpg'),
      Pic(url: 'https://example.com/bmiddle/3.jpg'),
    ];

    // Single photo -> shows 保存原图到手机, no 保存所有原图到手机.
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: GalleryPage(pics: singlePic)),
      ),
    );
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('保存原图到手机'), findsOneWidget);
    expect(find.textContaining('保存所有原图到手机'), findsNothing);

    // Pop sheet and test multi-photo -> shows both 保存原图到手机 and 保存所有原图到手机 (3张).
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: GalleryPage(pics: multiPics)),
      ),
    );
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('保存原图到手机'), findsOneWidget);
    expect(find.text('保存所有原图到手机 (3张)'), findsOneWidget);
  });

  test('HotSearch category parser extracts 实时热搜, channel_list, and classified band_list tabs', () {
    final cats = WeiboApi.parseHotSearchCategoriesPayload({
      'mobile': {
        'cardlistInfo': {
          'channel_list': [
            {'name': '实时热搜', 'containerid': '106003type=25&filter_type=realtimehot'},
            {'name': '我的', 'containerid': '106003type=25&filter_type=mine'},
          ],
        },
      },
      'band': {
        'data': {
          'band_list': [
            {'word': '航天新闻事件', 'num': 980000, 'label_name': '爆', 'category': '国际时政'},
            {'word': '热播新剧大结局', 'num': 650000, 'label_name': '热', 'category': '剧集'},
            {'word': '黄金股市大涨', 'num': 420000, 'label_name': '新', 'category': '财经'},
            {'word': 'AI新模型发布', 'num': 310000, 'label_name': '', 'category': '互联网'},
            {'word': '全球总决赛半决赛', 'num': 290000, 'label_name': '沸', 'category': '电竞'},
          ],
        },
      },
    });

    final titles = cats.map((c) => c.title).toList();
    expect(titles, containsAll(['实时热搜', '我的', '要闻社会', '文娱', '财经', '科技数码', '体育电竞']));
    expect(cats.first.items.length, 5);
    expect(cats.firstWhere((c) => c.title == '文娱').items.first.word, '热播新剧大结局');
    expect(cats.firstWhere((c) => c.title == '要闻社会').items.first.word, '航天新闻事件');
  });

  test('QrCodeMatrix generates valid ISO-18004 finder patterns', () {
    final matrix = QrCodeMatrix.encode('https://weibo.com/123456/P123456789');
    expect(matrix.size, greaterThanOrEqualTo(21));
    expect(matrix.at(0, 0), isTrue);
    expect(matrix.at(0, 6), isTrue);
    expect(matrix.at(6, 0), isTrue);
    expect(matrix.at(1, 1), isFalse);
    expect(matrix.at(3, 3), isTrue);
    expect(matrix.at(0, matrix.size - 1), isTrue);
    expect(matrix.at(matrix.size - 1, 0), isTrue);
  });

  testWidgets('LongImagePage renders untruncated poster with QR code, optional comments, and save controls',
      (tester) async {
    const status = Status(
      id: '66001',
      mblogid: 'M66001',
      createdAt: '',
      textHtml: '生成长图测试完整正文内容不会截断',
      textRaw: '生成长图测试完整正文内容不会截断',
      source: 'Weibo.intl',
      user: User(id: 'u66', name: '长图博主', avatar: ''),
      reposts: 9,
      comments: 2,
      attitudes: 33,
    );
    const comments = [
      Comment(
        id: 'c1',
        rootId: 'c1',
        createdAt: '',
        textHtml: '第一条热评测试',
        user: User(id: 'u1', name: '热评一', avatar: ''),
      ),
    ];

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: LongImagePage(status: status, initialComments: comments),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('生成长图'), findsOneWidget);
    expect(find.text('保存到相册'), findsOneWidget);
    expect(find.text('分享长图'), findsOneWidget);
    expect(find.text('以下为部分评论'), findsOneWidget);
    expect(find.textContaining('生成长图测试完整正文内容不会截断'), findsOneWidget);
    expect(find.textContaining('第一条热评测试'), findsOneWidget);
    expect(find.byType(QrCodeBox), findsOneWidget);
  });

  testWidgets('StatusCard renders 查看翻译 button when status_translation setting is enabled',
      (tester) async {
    const status = Status(
      id: '55001',
      mblogid: 'M55001',
      createdAt: '',
      textHtml: 'Hello Share v1.4',
      textRaw: 'Hello Share v1.4',
      source: 'Share',
      user: User(id: 'u1', name: 'Tester', avatar: ''),
    );
    const settingsOn = AppSettings(
      themeKey: 'elegant_purple',
      prefs: {'status_translation': true},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((_) => SettingsNotifier(settingsOn)),
        ],
        child: const MaterialApp(
          home: Scaffold(body: StatusCard(status: status)),
        ),
      ),
    );
    expect(find.text('查看翻译'), findsOneWidget);
  });

  testWidgets('FeedPage cold start restores persisted timeline and scroll offset when auto-refresh is off',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fakeItems = List.generate(
      18,
      (i) => Status(
        id: '${900000 - i}',
        mblogid: 'M${900000 - i}',
        createdAt: '',
        textHtml: '第 $i 条持久化微博内容用于测试恢复定位与防覆盖\n第二行增加高度确保页面可向下滚动',
        textRaw: '第 $i 条持久化微博内容用于测试恢复定位与防覆盖\n第二行增加高度确保页面可向下滚动',
        source: 'Share',
        user: User(id: 'u$i', name: '博主$i', avatar: ''),
      ),
    );
    await tester.runAsync(() async {
      await FeedCacheStore.instance.saveSnapshot(
        'guest',
        CachedTimelineSnapshot(
          groupKey: 'all',
          items: fakeItems,
          page: 1,
          hasMore: true,
          scrollOffset: 360.0,
        ),
      );
    });

    const settingsNoAutoRefresh = AppSettings(
      themeKey: 'elegant_purple',
      prefs: {'start_refresh_status': false},
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((_) => SettingsNotifier(settingsNoAutoRefresh)),
        ],
        child: const MaterialApp(home: FeedPage()),
      ),
    );
    // Flush addPostFrameCallback -> let real async SQLite/prefs complete -> pump list + scroll jump.
    await tester.pump();
    for (var step = 0; step < 3; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 120));

    final listView = tester.widget<ListView>(find.byType(ListView).first);
    final pos = listView.controller?.offset ?? 0;
    expect(pos, greaterThan(100.0));
  });

  test('v1.5 models: Comment nested replies/more_info/pics, Status hotComment, Pic GIF & long badges', () {
    final c = Comment.fromJson({
      'idstr': 'c100',
      'rootidstr': 's900',
      'text': '根评论正文',
      'created_at': '刚刚',
      'user': {'idstr': 'u1', 'screen_name': '楼主', 'profile_image_url': ''},
      'total_number': 0,
      'more_info': {'text': '共42条回复'},
      'pic': {
        'url': 'https://wx1.sinaimg.cn/orj360/abc.gif',
        'large': {'url': 'https://wx1.sinaimg.cn/large/abc.gif'},
      },
      'comments': [
        {
          'idstr': 'r101',
          'rootidstr': 'c100',
          'text': '这是跟评内容',
          'user': {'idstr': 'u2', 'screen_name': '小A', 'profile_image_url': ''},
          'reply_comment': {
            'idstr': 'r100',
            'user': {'idstr': 'u3', 'screen_name': '小B', 'profile_image_url': ''},
          },
        },
      ],
    });
    expect(c.id, 'c100');
    expect(c.replyCount, 42);
    expect(c.replies.length, 1);
    expect(c.replies.first.textHtml, '这是跟评内容');
    expect(c.replies.first.replyTo?.user?.name, '小B');
    expect(c.pics.length, 1);
    expect(c.pics.first.isGif, isTrue);

    final status = Status.fromJson({
      'idstr': 's900',
      'text': '测试带热门评论微博',
      'hot_comment': {
        'idstr': 'hc1',
        'text': '这是精选神评',
        'like_counts': 99,
        'user': {'idstr': 'u9', 'screen_name': '神评君', 'profile_image_url': ''},
      },
      'pic_infos': {
        'p1': {
          'bmiddle': {'url': 'https://wx1.sinaimg.cn/bmiddle/long.jpg', 'width': 500, 'height': 1600},
          'original': {'url': 'https://wx1.sinaimg.cn/large/long.jpg', 'width': 500, 'height': 1600},
        },
      },
    });
    expect(status.hotComment, isNotNull);
    expect(status.hotComment!.textHtml, '这是精选神评');
    expect(status.pics.single.isLongImage, isTrue);
  });

  testWidgets('CommentFloorPage renders pre-seeded 跟评, switches sub-reply target, and resets on close',
      (tester) async {
    const subReply = Comment(
      id: 'sub1',
      rootId: 'root1',
      createdAt: '1分钟前',
      textHtml: '第一条楼中楼回复',
      user: User(id: 'u2', name: '小跟评', avatar: ''),
      likeCount: 6,
    );
    const rootComment = Comment(
      id: 'root1',
      rootId: 'status1',
      createdAt: '5分钟前',
      textHtml: '这是根评论正文',
      user: User(id: 'u1', name: '楼主', avatar: ''),
      replyCount: 3,
      replies: [subReply],
    );

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: CommentFloorPage(
            root: rootComment,
            statusAuthor: '作者大大',
            statusId: 'status1',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('3 条回复'), findsOneWidget);
    expect(find.text('这是根评论正文'), findsOneWidget);
    expect(find.text('第一条楼中楼回复'), findsOneWidget);
    expect(find.text('按热度'), findsOneWidget);

    // Tap the child reply tile -> switches composer target to 小跟评.
    await tester.tap(find.text('第一条楼中楼回复'));
    await tester.pump();
    expect(find.text('正在回复 @小跟评'), findsOneWidget);

    // Clear target -> returns to root reply mode.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(find.text('正在回复 @小跟评'), findsNothing);
  });

  testWidgets('PicGrid shows GIF badge, 长图 badge, and +N scrim above 9 images',
      (tester) async {
    const gifPic = Pic(
      url: 'https://wx1.sinaimg.cn/bmiddle/test.gif',
      width: 400,
      height: 300,
    );
    const longPic = Pic(
      url: 'https://wx1.sinaimg.cn/bmiddle/tall.jpg',
      width: 500,
      height: 1800,
    );
    final manyPics = List.generate(
      12,
      (i) => Pic(url: 'https://wx1.sinaimg.cn/bmiddle/p$i.jpg', width: 400, height: 400),
    );

    const imgOnSettings = AppSettings(
      themeKey: 'elegant_purple',
      prefs: {'download_image_quality': 2},
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((_) => SettingsNotifier(imgOnSettings)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  const PicGrid(pics: [gifPic], maxWidth: 280),
                  const PicGrid(pics: [longPic], maxWidth: 280),
                  PicGrid(pics: manyPics, maxWidth: 300),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('GIF'), findsOneWidget);
    expect(find.text('长图'), findsOneWidget);
    expect(find.text('+3'), findsOneWidget);
  });

  testWidgets('StatusCard honors hot_status_comment_preview and show_status_space indent',
      (tester) async {
    const status = Status(
      id: '77001',
      mblogid: 'M77001',
      createdAt: '',
      textHtml: '带热门评论与左侧留白的正文内容',
      textRaw: '带热门评论与左侧留白的正文内容',
      source: 'Share',
      user: User(id: 'u1', name: '博主', avatar: ''),
      hotComment: Comment(
        id: 'hc77',
        rootId: '77001',
        createdAt: '',
        textHtml: '非常赞同这个观点',
        likeCount: 128,
        user: User(id: 'u2', name: '热心网友', avatar: ''),
      ),
    );

    const settingsIndented = AppSettings(
      themeKey: 'elegant_purple',
      prefs: {
        'hot_status_comment_preview': true,
        'show_status_space': true,
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((_) => SettingsNotifier(settingsIndented)),
        ],
        child: const MaterialApp(
          home: Scaffold(body: StatusCard(status: status)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('热评'), findsOneWidget);
    expect(find.textContaining('非常赞同这个观点'), findsOneWidget);
    expect(find.text('128'), findsOneWidget);
  });

  testWidgets('SearchPage renders typed result tabs and UserPage renders feed filter tabs',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SearchPage(initialKeyword: 'Flutter')),
      ),
    );
    await tester.pump();

    expect(find.text('综合'), findsOneWidget);
    expect(find.text('实时'), findsOneWidget);
    expect(find.text('用户'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: UserPage(uid: '10086', initialName: '测试主页')),
      ),
    );
    await tester.pump();

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('原创'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);
  });

  testWidgets('Manual white mode override persists across active night window and resets next night',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final notifier = SettingsNotifier(
      const AppSettings(
        themeKey: 'white',
        prefs: {
          'auto_night_mode': true,
          'auto_night_mode_duration': '22:00-07:00',
          'night_theme': 3,
        },
      ),
    );
    final tonight = DateTime(2026, 11, 26, 23, 30);
    final pastMidnightSameCycle = DateTime(2026, 11, 27, 2, 0);
    final nextNight = DateTime(2026, 11, 27, 22, 30);

    expect(notifier.state.effectivePreset(Brightness.light, tonight).dark, isTrue);

    notifier.toggleThemeDark(
      false,
      platformBrightness: Brightness.light,
      now: tonight,
    );
    expect(notifier.state.effectivePreset(Brightness.light, tonight).key, 'white');
    expect(
      notifier.state.effectivePreset(Brightness.light, pastMidnightSameCycle).key,
      'white',
    );
    expect(notifier.state.effectivePreset(Brightness.light, nextNight).dark, isTrue);

    // UI switch inside ShareDrawer with all-day active auto_night_mode window.
    final drawerNotifier = SettingsNotifier(
      const AppSettings(
        themeKey: 'white',
        prefs: {
          'auto_night_mode': true,
          'auto_night_mode_duration': '00:00-23:59',
          'night_theme': 3,
        },
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith((_) => drawerNotifier)],
        child: MaterialApp(
          home: Scaffold(body: ShareDrawer(onSelectTab: (_) {})),
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byType(Switch),
      150,
      scrollable: find.descendant(
        of: find.byType(ShareDrawer),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pump();
    expect(find.text('日间模式'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(drawerNotifier.state.effectivePreset(Brightness.light).key, 'white');
    expect(find.text('夜间模式'), findsOneWidget);

    // Follow system dark override also respects manual white toggle until re-enabled.
    final sysNotifier = SettingsNotifier(
      const AppSettings(
        themeKey: 'white',
        followSystemDark: true,
        prefs: {'auto_night_mode_follow_system': true, 'night_theme': 3},
      ),
    );
    expect(sysNotifier.state.effectivePreset(Brightness.dark).dark, isTrue);
    sysNotifier.toggleThemeDark(false, platformBrightness: Brightness.dark);
    expect(sysNotifier.state.effectivePreset(Brightness.dark).key, 'white');
  });

  testWidgets('MainShell mounts ShareDrawer above BottomAppBar and opening drawer prevents bottom bar flicker',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    final notifier = SettingsNotifier(
      const AppSettings(
        themeKey: 'white',
        prefs: {
          'navigation_hide_on_scroll': true,
          'navigation_position': 2,
          'fab_options': 1,
          'auto_night_mode': true,
          'auto_night_mode_duration': '00:00-23:59',
          'night_theme': 3,
        },
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith((_) => notifier)],
        child: const MaterialApp(home: MainShell()),
      ),
    );
    await tester.pump();

    expect(find.byType(BottomAppBar), findsOneWidget);
    // Open drawer by tapping avatar button on FeedPage.
    await tester.tap(find.byType(ClipOval).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(ShareDrawer), findsOneWidget);
    expect(
      find.ancestor(of: find.byType(ShareDrawer), matching: find.byType(FeedPage)),
      findsNothing,
    );
    expect(
      find.ancestor(of: find.byType(ShareDrawer), matching: find.byType(MainShell)),
      findsOneWidget,
    );

    // Scroll drawer if needed, and verify night-mode switch is unobstructed & hit-testable above BottomAppBar.
    final drawerScroll = find.descendant(
      of: find.byType(ShareDrawer),
      matching: find.byType(Scrollable),
    );
    final nightSwitchFinder = find.descendant(
      of: find.byType(ShareDrawer),
      matching: find.byType(Switch),
    );
    await tester.scrollUntilVisible(
      nightSwitchFinder,
      150,
      scrollable: drawerScroll,
    );
    await tester.pump();
    expect(find.text('日间模式'), findsOneWidget);
    await tester.tap(nightSwitchFinder);
    await tester.pump();
    expect(find.text('夜间模式'), findsOneWidget);

    // Scrolling inside the open drawer must not hide or flicker BottomAppBar.
    final drawerList = find.descendant(
      of: find.byType(ShareDrawer),
      matching: find.byType(ListView),
    );
    await tester.drag(drawerList, const Offset(0, -120));
    await tester.pump();
    expect(find.byType(BottomAppBar), findsOneWidget);
  });

  test('DmConversation and DmHistory parse joined group chats and groupchat WebIM messages', () {
    final convRaw = jsonEncode({
      'user_list': [
        {
          'user': {
            'id': 99887766,
            'type': '3',
            'screen_name': 'Flutter交流群',
            'round_avatar_large': 'https://example.com/g.jpg',
            'member_count': 42,
          },
          'direct_message': {
            'id': 501,
            'text': '最新群消息',
            'created_at': 1700000100,
          },
          'unread_count': 3,
        },
        {
          'user': {
            'id': 12345,
            'type': '1',
            'screen_name': '好友小王',
            'avatar_large': 'https://example.com/u.jpg',
          },
          'direct_message': {
            'id': 502,
            'text': '私聊',
            'created_at': 1700000050,
          },
        },
      ],
    });
    final convs = DmConversation.parseList(convRaw);
    expect(convs.length, 2);
    expect(convs.first.uid, '99887766');
    expect(convs.first.isGroup, isTrue);
    expect(convs.first.avatar, 'https://example.com/g.jpg');
    expect(convs.last.uid, '12345');
    expect(convs.last.isGroup, isFalse);

    final webimGroupConvRaw = jsonEncode({
      'conversations': [
        {
          'type': 2,
          'gid': '77665544',
          'user': {'name': '设计群'},
          'last_message': {'id': 601, 'content': '早安', 'time': 1700000200},
        },
      ],
    });
    final webimConvs = DmConversation.parseList(webimGroupConvRaw);
    expect(webimConvs.single.uid, '77665544');
    expect(webimConvs.single.isGroup, isTrue);

    final groupMsgRaw = jsonEncode({
      'result': true,
      'messages': [
        {
          'msgid': '1002',
          'content': '我自己发的消息',
          'time': 1700000020,
          'from_uid': '10001',
          'from_user': {'id': 10001, 'screen_name': '我自己'},
        },
        {
          'msgid': '1001',
          'content': '大家好',
          'time': 1700000010,
          'from_uid': '2002',
          'from_user': {
            'id': 2002,
            'screen_name': '群友A',
            'avatar_large': 'https://example.com/a.jpg',
          },
        },
      ],
    });
    final history = DmHistory.parse(groupMsgRaw, myUid: '10001', count: 20);
    expect(history.items.length, 2);
    expect(history.items.first.id, '1001');
    expect(history.items.first.senderName, '群友A');
    expect(history.items.first.senderAvatar, 'https://example.com/a.jpg');
    expect(history.items.first.fromMe, isFalse);
    expect(history.items.last.fromMe, isTrue);

    final sendResp = jsonDecode(jsonEncode({
      'result': true,
      'message': {
        'msgid': '1003',
        'content': '群内发送成功',
        'time': 1700000030,
        'from_uid': '10001',
      },
    })) as Map<String, dynamic>;
    final sentMsg = DmMessage.fromJson(sendResp, myUid: '10001');
    expect(sentMsg.id, '1003');
    expect(sentMsg.text, '群内发送成功');
    expect(sentMsg.fromMe, isTrue);

    expect(
      () => DmHistory.parse(
        jsonEncode({'result': false, 'error_msg': '非群成员'}),
        myUid: '10001',
      ),
      throwsFormatException,
    );
  });

  testWidgets('GalleryPage toggles 2.5x zoom on double tap and locks PageView paging while zoomed',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: GalleryPage(
            pics: [
              Pic(url: 'https://example.com/1.jpg'),
              Pic(url: 'https://example.com/2.jpg'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final viewerFinder = find.byType(InteractiveViewer);
    expect(viewerFinder, findsOneWidget);
    final viewer = tester.widget<InteractiveViewer>(viewerFinder);
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), closeTo(1.0, 0.01));

    // Double-tap zooms in to 2.5x and disables PageView horizontal swiping.
    final center = tester.getCenter(viewerFinder);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      closeTo(2.5, 0.05),
    );
    final pageViewZoomed = tester.widget<PageView>(find.byType(PageView));
    expect(pageViewZoomed.physics, isA<NeverScrollableScrollPhysics>());

    // Double-tap again resets back to 1.0x and restores paging.
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      closeTo(1.0, 0.05),
    );
    final pageViewUnzoomed = tester.widget<PageView>(find.byType(PageView));
    expect(pageViewUnzoomed.physics, isNull);
  });

  test('Pic.extractPid and Status.fromJson extract pid, isTop, and visible fields', () {
    expect(
      Pic.extractPid('https://wx1.sinaimg.cn/large/006ABCD1ly1hz9abc1234j30u0140n0u.jpg'),
      '006ABCD1ly1hz9abc1234j30u0140n0u',
    );
    final status = Status.fromJson({
      'idstr': '5123456789012345',
      'mblogid': 'P123abc',
      'text': '测试置顶微博',
      'isTop': 1,
      'visible': {'type': 2, 'list_id': 0},
      'pic_infos': {
        '006ABCD1ly1hz9abc1234j30u0140n0u': {
          'large': {
            'url': 'https://wx1.sinaimg.cn/large/006ABCD1ly1hz9abc1234j30u0140n0u.jpg',
            'width': 1080,
            'height': 1440,
          },
        },
      },
    });
    expect(status.isTop, isTrue);
    expect(status.visible, 2);
    expect(status.pics.single.pid, '006ABCD1ly1hz9abc1234j30u0140n0u');
  });

  testWidgets('ComposePage editStatus shows full Share editor and StatusActionSheet opens it instead of dialog',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final sessionNotifier = SessionNotifier()
      ..state = const SessionState(
        account: SessionAccount(
          uid: '10086',
          screenName: '我',
          avatar: '',
          isGuest: false,
          active: true,
        ),
      );
    final status = Status(
      id: '5123456789012345',
      mblogid: 'P123abc',
      createdAt: '',
      textHtml: '原来的微博正文',
      textRaw: '原来的微博正文 ...全文',
      source: 'Share',
      user: const User(id: '10086', name: '我', avatar: ''),
      isTop: true,
      visible: 2,
      pics: const [
        Pic(
          url: 'https://wx1.sinaimg.cn/bmiddle/006ABCD1ly1hz9abc1234j30u0140n0u.jpg',
          pid: '006ABCD1ly1hz9abc1234j30u0140n0u',
        ),
      ],
      retweeted: const Status(
        id: '5000000000000001',
        mblogid: 'O123xyz',
        createdAt: '',
        textHtml: '被转发原博内容',
        textRaw: '被转发原博内容',
        source: '',
        user: User(id: '999', name: '原作者', avatar: ''),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith((_) => sessionNotifier)],
        child: MaterialApp(home: ComposePage(editStatus: status)),
      ),
    );
    await tester.pump();

    expect(find.text('编辑微博'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('存草稿'), findsNothing);
    expect(find.text('原来的微博正文'), findsOneWidget);
    expect(find.text('@原作者: 被转发原博内容'), findsOneWidget);
    expect(find.text('好友圈'), findsOneWidget);

    // Author action sheet shows cancel-pin label when isTop=true and launches ComposePage on '编辑微博'.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith((_) => sessionNotifier)],
        child: MaterialApp(
          home: Consumer(
            builder: (ctx, ref, _) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showStatusActionSheet(ctx, ref, status),
                child: const Text('OpenMenu'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OpenMenu'));
    await tester.pumpAndSettle();

    expect(find.text('取消个人主页置顶'), findsOneWidget);
    await tester.ensureVisible(find.text('编辑微博'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑微博'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(ComposePage), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('Mid-screen swipe-back pops pushed routes on iOS, respects swipe_back modes, PopScope, TabBarView, and GalleryPage zoom',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    try {
      Future<SettingsNotifier> pumpNavHost({
        required TargetPlatform platform,
        required int swipeBackMode,
        WidgetBuilder? pageBuilder,
      }) async {
        debugDefaultTargetPlatformOverride = platform;
        final s = initialSettings.copyWith(
          prefs: {...initialSettings.prefs, 'swipe_back': swipeBackMode},
        );
        final notifier = SettingsNotifier(s);
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [settingsProvider.overrideWith((_) => notifier)],
            child: Consumer(
              builder: (context, ref, _) {
                final cur = ref.watch(settingsProvider);
                return MaterialApp(
                  theme: ShareTheme.build(
                    ShareThemePreset.byKey(cur.themeKey),
                    settings: cur,
                  ),
                  home: Builder(
                    builder: (ctx) => Scaffold(
                      body: Center(
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(ctx).push(
                            MaterialPageRoute<void>(
                              builder: pageBuilder ??
                                  (_) => Scaffold(
                                        body: ListView(
                                          children: const [
                                            SizedBox(
                                              height: 1200,
                                              child: Center(
                                                child: Text('SecondaryPage'),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                            ),
                          ),
                          child: const Text('PushSecondary'),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        return notifier;
      }

      // 1. iOS: root page ignores mid-screen swipe; pushed secondary page pops on mid-screen right swipe
      // and fast fling, while small drag or diagonal vertical scroll stays on page.
      await pumpNavHost(platform: TargetPlatform.iOS, swipeBackMode: 3);
      await tester.dragFrom(const Offset(195, 422), const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(find.text('PushSecondary'), findsOneWidget);

      await tester.tap(find.text('PushSecondary'));
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsOneWidget);

      // Diagonal vertical list scroll must not trigger back navigation.
      await tester.dragFrom(const Offset(195, 422), const Offset(22, -220));
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsOneWidget);

      // Small non-fling drag does not pop.
      await tester.dragFrom(const Offset(195, 422), const Offset(28, 0));
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsOneWidget);

      // Mid-screen right swipe pops on iOS.
      await tester.dragFrom(const Offset(195, 422), const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsNothing);
      expect(find.text('PushSecondary'), findsOneWidget);

      // Fast right fling from center also pops on iOS.
      await tester.tap(find.text('PushSecondary'));
      await tester.pumpAndSettle();
      await tester.flingFrom(const Offset(195, 422), const Offset(60, 0), 900);
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsNothing);

      // Step-by-step interactive drag on iOS must slide smoothly without twitching back to 0.
      await tester.tap(find.text('PushSecondary'));
      await tester.pumpAndSettle();
      final baseLeft = tester.getTopLeft(find.text('SecondaryPage')).dx;
      final gesture = await tester.startGesture(const Offset(195, 422));
      await tester.pump();
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(45, 0));
      await tester.pump();
      final dx1 = tester.getTopLeft(find.text('SecondaryPage')).dx;
      expect(dx1, greaterThan(baseLeft + 25));

      await gesture.moveBy(const Offset(45, 0));
      await tester.pump();
      final dx2 = tester.getTopLeft(find.text('SecondaryPage')).dx;
      expect(dx2, greaterThan(dx1 + 25));

      await gesture.moveBy(const Offset(45, 0));
      await tester.pump();
      final dx3 = tester.getTopLeft(find.text('SecondaryPage')).dx;
      expect(dx3, greaterThan(dx2 + 25));

      // Moving finger slightly left must glide smoothly left without restarting or jittering.
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      final dx4 = tester.getTopLeft(find.text('SecondaryPage')).dx;
      expect(dx4, lessThan(dx3));
      expect(dx4, greaterThan(dx1));

      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      final dx5 = tester.getTopLeft(find.text('SecondaryPage')).dx;
      expect(dx5, greaterThan(dx4 + 30));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsNothing);
      expect(find.text('PushSecondary'), findsOneWidget);

      // 2. Respect swipe_back modes: 1 (right only), 2 (left only), 4 (disabled).
      final notifier =
          await pumpNavHost(platform: TargetPlatform.android, swipeBackMode: 1);
      await tester.tap(find.text('PushSecondary'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(195, 422), const Offset(-160, 0));
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsOneWidget);
      await tester.dragFrom(const Offset(195, 422), const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsNothing);

      notifier.setPref('swipe_back', 2);
      await tester.pump();
      await tester.tap(find.text('PushSecondary'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(195, 422), const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsOneWidget);
      await tester.dragFrom(const Offset(195, 422), const Offset(-160, 0));
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsNothing);

      notifier.setPref('swipe_back', 4);
      await tester.pump();
      await tester.tap(find.text('PushSecondary'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(195, 422), const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(find.text('SecondaryPage'), findsOneWidget);

      // 3. PopScope(canPop: false) is respected via maybePop() instead of bypassing.
      var popInvoked = 0;
      await pumpNavHost(
        platform: TargetPlatform.iOS,
        swipeBackMode: 3,
        pageBuilder: (_) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) popInvoked++;
          },
          child: const Scaffold(body: Center(child: Text('GuardedPage'))),
        ),
      );
      await tester.tap(find.text('PushSecondary'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(195, 422), const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(popInvoked, 1);
      expect(find.text('GuardedPage'), findsOneWidget);

      // 4. TabBarView: Tab 0 -> Tab 1 swipe left switches tab instead of popping;
      // Tab 1 -> Tab 0 swipe right returns to Tab 0 instead of popping;
      // Tab 0 overscroll swipe right pops the route.
      await pumpNavHost(
        platform: TargetPlatform.iOS,
        swipeBackMode: 3,
        pageBuilder: (_) => DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(title: const Text('TabsHost')),
            body: const TabBarView(
              children: [
                Center(child: Text('TabZero')),
                Center(child: Text('TabOne')),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('PushSecondary'));
      await tester.pumpAndSettle();
      expect(find.text('TabZero'), findsOneWidget);

      await tester.dragFrom(const Offset(320, 422), const Offset(-260, 0));
      await tester.pumpAndSettle();
      expect(find.text('TabOne'), findsOneWidget);
      expect(find.text('TabsHost'), findsOneWidget);

      await tester.dragFrom(const Offset(70, 422), const Offset(260, 0));
      await tester.pumpAndSettle();
      expect(find.text('TabZero'), findsOneWidget);
      expect(find.text('TabsHost'), findsOneWidget);

      await tester.dragFrom(const Offset(195, 422), const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(find.text('TabsHost'), findsNothing);
      expect(find.text('PushSecondary'), findsOneWidget);

      // 5. GalleryPage: 2.5x zoomed image does NOT pop on mid-screen right swipe;
      // unzoomed single-pic GalleryPage pops cleanly on mid-screen right swipe.
      await pumpNavHost(
        platform: TargetPlatform.iOS,
        swipeBackMode: 3,
        pageBuilder: (_) => const GalleryPage(
          pics: [Pic(url: 'https://example.com/solo.jpg')],
        ),
      );
      await tester.tap(find.text('PushSecondary'));
      await tester.pumpAndSettle();
      expect(find.byType(GalleryPage), findsOneWidget);

      final center = tester.getCenter(find.byType(InteractiveViewer));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      await tester.dragFrom(const Offset(195, 422), const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(find.byType(GalleryPage), findsOneWidget);

      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      await tester.dragFrom(const Offset(195, 422), const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(find.byType(GalleryPage), findsNothing);
      expect(find.text('PushSecondary'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Retweeted video renders inside quoted box even when outer JSON hoists page_info',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final parsed = Status.fromJson({
      'idstr': '5200000000000002',
      'mblogid': 'Q999xyz',
      'text': '转发评论正文',
      'user': {'id': '100', 'screen_name': '转发者'},
      'page_info': {
        'type': 'video',
        'object_id': '1034:99887766',
        'page_pic': {'url': 'https://wx1.sinaimg.cn/large/cover.jpg'},
        'media_info': {
          'duration': '65',
          'mp4_720p_mp4': 'https://f.video.weibocdn.com/test.mp4',
        },
      },
      'retweeted_status': {
        'idstr': '5200000000000001',
        'mblogid': 'O111abc',
        'text': '原博视频正文',
        'user': {'id': '200', 'screen_name': '原博主'},
      },
    });

    expect(parsed.isVideo, isFalse);
    expect(parsed.videoUrl, isNull);
    expect(parsed.retweeted, isNotNull);
    expect(parsed.retweeted!.isVideo, isTrue);
    expect(parsed.retweeted!.videoDuration, 65);
    expect(parsed.retweeted!.videoObjectId, '1034:99887766');
    expect(parsed.resolvedVideoTarget.id, '5200000000000001');

    // Also verify cached/stale Status with outer video still renders inside retweet box.
    const staleCached = Status(
      id: '5200000000000002',
      mblogid: 'Q999xyz',
      createdAt: '',
      textHtml: '转发评论正文',
      textRaw: '转发评论正文',
      source: 'Share',
      isVideo: true,
      videoDuration: 65,
      videoCover: '',
      videoObjectId: '1034:99887766',
      user: User(id: '100', name: '转发者', avatar: ''),
      retweeted: Status(
        id: '5200000000000001',
        mblogid: 'O111abc',
        createdAt: '',
        textHtml: '原博视频正文',
        textRaw: '原博视频正文',
        source: 'Share',
        user: User(id: '200', name: '原博主', avatar: ''),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatusCard(
                status: staleCached,
                showActions: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('01:05'), findsOneWidget);
    final quoteBoxFinder = find.byWidgetPredicate(
      (w) => w is Material && w.color == ShareColors.repostBg,
    );
    expect(quoteBoxFinder, findsOneWidget);
    expect(
      find.descendant(of: quoteBoxFinder, matching: find.text('01:05')),
      findsOneWidget,
    );
  });

  test('Comments and embedded media/users handle stringified numeric and boolean JSON fields safely', () {
    final comments = WeiboApi.extractCommentsFromPayload({
      'root_comments': [
        {
          'idstr': '9001',
          'rootidstr': '9001',
          'created_at': 'Fri Nov 27 08:45:00 +0800 2026',
          'text': '测试带图跟评',
          'floor_number': '15',
          'like_counts': '42',
          'like_status': '1',
          'total_number': '7',
          'isLikedByMblogAuthor': '1',
          'user': {
            'id': 12345,
            'screen_name': '博士',
            'verified': 'true',
            'verified_type': '0',
            'followers_count': '1234',
            'friends_count': '56',
            'statuses_count': '789',
            'verified_reason': 0,
          },
          'pic': {
            'url': 'https://wx1.sinaimg.cn/bmiddle/cmtpic.jpg',
            'width': '1080',
            'height': '1440',
            'large': {
              'url': 'https://wx1.sinaimg.cn/large/cmtpic.jpg',
            },
          },
          'comments': [
            {
              'idstr': '9002',
              'rootidstr': '9001',
              'text': '子回复',
              'like_count': '9',
              'like_status': '0',
              'user': {
                'id': '67890',
                'screen_name': '楼友',
                'verified_type': '-1',
                'followers_count': '10.5万',
              },
            },
          ],
        },
      ],
    });

    expect(comments, hasLength(1));
    final c = comments.single;
    expect(c.floor, 15);
    expect(c.likeCount, 42);
    expect(c.likedByMe, isTrue);
    expect(c.likedByAuthor, isTrue);
    expect(c.replyCount, 7);
    expect(c.user?.verified, isTrue);
    expect(c.user?.verifiedType, 0);
    expect(c.user?.followers, 1234);
    expect(c.user?.friends, 56);
    expect(c.user?.statuses, 789);
    expect(c.pics, hasLength(1));
    expect(c.pics.single.width, 1080);
    expect(c.pics.single.height, 1440);
    expect(c.replies, hasLength(1));
    expect(c.replies.single.likeCount, 9);
    expect(c.replies.single.user?.verifiedType, -1);
    expect(c.replies.single.user?.followers, 0);
  });

  testWidgets('Mixed pics + video posts render all media in a unified 9-grid both in detail and inside retweet box',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 1. Parse mix_media_info payload where pics + video sit in mix_media_info.items without pic_infos.
    final mixedInfoStatus = Status.fromJson({
      'idstr': '5369533460122999',
      'mblogid': 'ArkMix01',
      'text': '图文混排原博',
      'user': {'id': '6279793937', 'screen_name': '明日方舟Arknights'},
      'mix_media_info': {
        'items': [
          {
            'type': 'pic',
            'id': 'pid0',
            'data': {
              'pic_id': 'pid0',
              'large': {'url': 'https://wx1.sinaimg.cn/large/pid0.jpg', 'width': 1080, 'height': 1080},
            },
          },
          {
            'type': 'video',
            'id': '1034:5369511348731982',
            'data': {
              'object_id': '1034:5369511348731982',
              'page_pic': {'url': 'https://wx3.sinaimg.cn/orj480/cover.jpg'},
              'media_info': {'duration': 60, 'mp4_720p_mp4': 'https://f.video.weibocdn.com/a.mp4'},
            },
          },
          {
            'type': 'pic',
            'id': 'pid1',
            'data': {
              'pic_id': 'pid1',
              'large': {'url': 'https://wx1.sinaimg.cn/large/pid1.gif', 'width': 500, 'height': 726},
            },
          },
        ],
      },
    });
    expect(mixedInfoStatus.pics, hasLength(2));
    expect(mixedInfoStatus.isVideo, isTrue);
    expect(mixedInfoStatus.videoDuration, 60);
    expect(mixedInfoStatus.videoMixIndex, 1);

    // 2. Parse mobile mix_media_ids (7 pics + 1 video at slot 7) and verify full-width 3x3 unified grid.
    final picIds = [
      '006QZngZgy1p0',
      '006QZngZgy1p1',
      '006QZngZgy1p2',
      '006QZngZgy1p3',
      '006QZngZgy1p4',
      '006QZngZgy1p5',
      '006QZngZgy1p6',
    ];
    final sevenPicStatus = Status.fromJson({
      'idstr': '5369533460122337',
      'mblogid': 'ArkMain',
      'text': '绿影之下 - 麦哲伦',
      'user': {'id': '6279793937', 'screen_name': '明日方舟Arknights'},
      'pic_ids': picIds,
      'pic_infos': {
        for (var i = 0; i < picIds.length; i++)
          picIds[i]: {
            'large': {
              'url': i == 0
                  ? 'https://wx3.sinaimg.cn/large/${picIds[i]}.jpg'
                  : 'https://wx3.sinaimg.cn/large/${picIds[i]}.gif',
              'width': 500,
              'height': 500,
            },
          },
      },
      'mix_media_ids': [...picIds, 'http://t.cn/AXTEvNes'],
      'page_info': {
        'type': '11',
        'object_id': '1034:5369511348731982',
        'page_pic': {'url': 'https://wx3.sinaimg.cn/orj480/cover.jpg'},
        'media_info': {'duration': 60, 'mp4_720p_mp4': 'https://f.video.weibocdn.com/v.mp4'},
      },
    });
    expect(sevenPicStatus.pics, hasLength(7));
    expect(sevenPicStatus.isVideo, isTrue);
    expect(sevenPicStatus.videoMixIndex, 7);

    int? tappedPic;
    var tappedVideo = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatusCard(
                status: sevenPicStatus,
                showActions: false,
                fullText: true,
                onImageTap: (i) => tappedPic = i,
                onVideoTap: () => tappedVideo++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // All 6 GIF pics + 1 video tile render together inside ONE unified 9-grid (not hidden by else-if!).
    expect(find.byType(PicGrid), findsOneWidget);
    expect(find.text('GIF'), findsNWidgets(6));
    expect(find.text('01:00'), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);
    expect(tester.getSize(find.byType(PicGrid)).width, greaterThan(330));

    await tester.tap(find.text('01:00'));
    await tester.pump();
    expect(tappedVideo, 1);

    await tester.tap(find.text('GIF').first);
    await tester.pump();
    expect(tappedPic, 1);

    // 3. Verify interleaved PicGrid maps pic indices accurately around the video tile.
    int? interleavedPic;
    var interleavedVideo = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: PicGrid(
              pics: mixedInfoStatus.pics,
              video: PicGridVideo(
                coverUrl: mixedInfoStatus.videoCover,
                durationSeconds: mixedInfoStatus.videoDuration,
                onTap: () => interleavedVideo++,
              ),
              videoIndex: mixedInfoStatus.videoMixIndex,
              maxWidth: 340,
              onTap: (i) => interleavedPic = i,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('GIF'), findsOneWidget);
    expect(find.text('01:00'), findsOneWidget);
    await tester.tap(find.text('GIF'));
    await tester.pump();
    expect(interleavedPic, 1);
    await tester.tap(find.text('01:00'));
    await tester.pump();
    expect(interleavedVideo, 1);

    // 4. Verify retweeted mixed post renders full-width unified 9-grid inside quote box (no 0.62x squish).
    final reposted = Status(
      id: '5369539999999999',
      mblogid: 'RepostMix',
      createdAt: '',
      textHtml: '转发微博',
      textRaw: '转发微博',
      source: 'Share',
      user: const User(id: '300', name: '-大地寂寂-', avatar: ''),
      retweeted: sevenPicStatus,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatusCard(
                status: reposted,
                showActions: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final quoteBoxFinder = find.byWidgetPredicate(
      (w) => w is Material && w.color == ShareColors.repostBg,
    );
    expect(quoteBoxFinder, findsOneWidget);
    final quotePicGrid = find.descendant(
      of: quoteBoxFinder,
      matching: find.byType(PicGrid),
    );
    expect(quotePicGrid, findsOneWidget);
    expect(
      find.descendant(of: quotePicGrid, matching: find.text('01:00')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: quotePicGrid, matching: find.text('GIF')),
      findsNWidgets(6),
    );
    expect(tester.getSize(quotePicGrid).width, greaterThan(300));
  });
}
