import 'dart:convert';

import 'emotions.dart';
import 'offline_emoticons.dart';

/// View models supporting BOTH Weibo web API (`weibo.com/ajax/*`) AND
/// mobile API (`api.weibo.cn/2/*`).
// ---------------------------------------------------------------------------
// Rich text
// ---------------------------------------------------------------------------

enum RichKind { text, mention, topic, link, emoji }

class RichSegment {
  final RichKind kind;
  final String text;
  final String? imageUrl;
  final String? assetPath;

  /// Target of an `<a>` tag or link URL.
  final String? href;

  const RichSegment(
    this.kind,
    this.text, {
    this.imageUrl,
    this.assetPath,
    this.href,
  });
}

class RichTextParser {
  static final _token = RegExp(
    r'<img\b[^>]*?\balt="([^"]*)"[^>]*?\bsrc="([^"]*)"[^>]*>'
    r'|<img\b[^>]*?\bsrc="([^"]*)"[^>]*?\balt="([^"]*)"[^>]*>'
    r'|<a\b[^>]*?href="([^"]*)"[^>]*>(.*?)</a>'
    r'|<br\s*/?>',
    dotAll: true,
    caseSensitive: false,
  );

  static final _plainToken = RegExp(
    r'(\[[^\]\r\n]{1,16}\])'
    r'|(#[^#\r\n]{1,64}#)'
    r'|(@[\u4e00-\u9fa5A-Za-z0-9_\-]+)'
    r'|(https?://[^\s<>\[\]"' "'" r'\u4e00-\u9fa5]+)',
  );

  static List<RichSegment> parse(String html) {
    final segments = <RichSegment>[];
    var cursor = 0;

    void addPlainWithInlineTokens(String raw, {String? link}) {
      if (raw.isEmpty) return;
      final text = _decodeEntities(raw);
      if (text.isEmpty) return;
      if (link != null && link.isNotEmpty) {
        segments.add(RichSegment(RichKind.link, text, href: link));
        return;
      }
      var pCursor = 0;
      for (final m in _plainToken.allMatches(text)) {
        if (m.start > pCursor) {
          segments.add(RichSegment(RichKind.text, text.substring(pCursor, m.start)));
        }
        pCursor = m.end;
        final bracket = m.group(1);
        final topic = m.group(2);
        final mention = m.group(3);
        final url = m.group(4);
        if (bracket != null) {
          final asset = kShareEmoticonAssets[bracket];
          if (asset != null) {
            segments.add(RichSegment(RichKind.emoji, bracket, assetPath: asset));
          } else {
            final onlineUrl = EmoticonRegistry.instance.urlFor(bracket);
            if (onlineUrl != null && onlineUrl.isNotEmpty) {
              segments.add(RichSegment(RichKind.emoji, bracket, imageUrl: onlineUrl));
            } else {
              segments.add(RichSegment(RichKind.text, bracket));
            }
          }
        } else if (topic != null) {
          segments.add(RichSegment(RichKind.topic, topic));
        } else if (mention != null) {
          segments.add(RichSegment(RichKind.mention, mention));
        } else if (url != null) {
          segments.add(RichSegment(RichKind.link, url, href: url));
        }
      }
      if (pCursor < text.length) {
        segments.add(RichSegment(RichKind.text, text.substring(pCursor)));
      }
    }

    for (final match in _token.allMatches(html)) {
      if (match.start > cursor) {
        addPlainWithInlineTokens(html.substring(cursor, match.start));
      }
      cursor = match.end;

      if (match.group(2) != null || match.group(3) != null) {
        final url = match.group(2) ?? match.group(3) ?? '';
        final alt = _decodeEntities(match.group(1) ?? match.group(4) ?? '');
        final localAsset = kShareEmoticonAssets[alt] ??
            (alt.isNotEmpty ? kShareEmoticonAssets['[$alt]'] : null);
        segments.add(RichSegment(
          RichKind.emoji,
          alt,
          imageUrl: url,
          assetPath: localAsset,
        ));
      } else if (match.group(6) != null) {
        final body = _decodeEntities(_stripTags(match.group(6)!));
        final kind = body.startsWith('#')
            ? RichKind.topic
            : body.startsWith('@')
                ? RichKind.mention
                : RichKind.link;
        if (body.isNotEmpty) {
          segments.add(RichSegment(kind, body, href: match.group(5)));
        }
      } else {
        segments.add(const RichSegment(RichKind.text, '\n'));
      }
    }

    if (cursor < html.length) {
      addPlainWithInlineTokens(html.substring(cursor));
    }

    return _mergeText(segments);
  }

  static List<RichSegment> _mergeText(List<RichSegment> input) {
    final out = <RichSegment>[];
    for (final seg in input) {
      if (seg.kind == RichKind.text && out.isNotEmpty && out.last.kind == RichKind.text) {
        out[out.length - 1] = RichSegment(RichKind.text, out.last.text + seg.text);
      } else {
        out.add(seg);
      }
    }
    return out;
  }

  static String _stripTags(String input) => input.replaceAll(RegExp(r'<[^>]+>'), '');

  static String _decodeEntities(String input) {
    if (!input.contains('&')) return input;
    return input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
  }

  /// Plain text version, used for previews and the composer quote.
  static String toPlain(String html) {
    return parse(html).map((s) => s.kind == RichKind.emoji ? s.text : s.text).join();
  }
}

// ---------------------------------------------------------------------------
// User
// ---------------------------------------------------------------------------

class User {
  final String id;
  final String name;
  final String avatar;
  final String? remark;
  final bool verified;
  final int verifiedType;
  final String verifiedReason;
  final String description;
  final int followers;
  final int friends;
  final int statuses;
  final bool following;
  final String gender;
  final String location;

  /// `/ajax/profile/info` exposes a profile cover (`cover_image_phone`).
  final String cover;

  const User({
    required this.id,
    required this.name,
    required this.avatar,
    this.remark,
    this.verified = false,
    this.verifiedType = -1,
    this.verifiedReason = '',
    this.description = '',
    this.followers = 0,
    this.friends = 0,
    this.statuses = 0,
    this.following = false,
    this.gender = '',
    this.location = '',
    this.cover = '',
  });

  factory User.fromJson(Map<String, dynamic> json) {
    // 三种接口的字段名并不统一：
    //   /ajax/statuses/*        -> screen_name + id
    //   /ajax/side/search       -> name / nick + uid（没有 screen_name，也没有 id）
    //   webim / 私信用户卡片    -> nick + uid
    // 所以每个字段都走「取第一个非空值」，不能只看 null。
    final avatar = _firstNonEmpty(json, const [
      'avatar_hd',
      'avatar_large',
      'profile_image_url',
    ]);
    return User(
      id: _firstNonEmpty(json, const ['id', 'idstr', 'uid']),
      name: _firstNonEmpty(json, const [
        'screen_name',
        'name',
        'nick',
        'remark',
      ]),
      avatar: _bigAvatar(avatar),
      remark: jsonNullableStr(json['remark']),
      verified: jsonBool(json['verified']),
      verifiedType: jsonInt(json['verified_type'], -1),
      verifiedReason: jsonStr(json['verified_reason']),
      description: jsonStr(json['description']),
      followers: jsonInt(json['followers_count']),
      friends: jsonInt(json['friends_count']),
      statuses: jsonInt(json['statuses_count']),
      following: jsonBool(json['following']),
      gender: jsonStr(json['gender']),
      location: jsonStr(json['location']),
      cover: jsonStr(json['cover_image_phone']),
    );
  }

  /// Parses mobile (`/2/profile` -> `userInfo` or top-level) and web (`/ajax/profile/info` -> `data.user`) payloads.
  static User? fromProfilePayload(Map<String, dynamic> json) {
    final candidates = <dynamic>[
      json['userInfo'],
      json['data'] is Map ? (json['data'] as Map)['user'] : null,
      json['user'],
      json,
    ];
    for (final c in candidates) {
      if (c is Map<String, dynamic>) {
        final u = User.fromJson(c);
        if (u.id.isNotEmpty || u.name.isNotEmpty) return u;
      }
    }
    return null;
  }

  String get displayName => (remark != null && remark!.isNotEmpty) ? remark! : name;

  Map<String, dynamic> toJson() => {
        'id': id,
        'idstr': id,
        'screen_name': name,
        'avatar_large': avatar,
        if (remark != null) 'remark': remark,
        'verified': verified,
        'verified_type': verifiedType,
        'verified_reason': verifiedReason,
        'description': description,
        'followers_count': followers,
        'friends_count': friends,
        'statuses_count': statuses,
        'following': following,
        'gender': gender,
        'location': location,
        'cover_image_phone': cover,
      };

  /// 依次尝试 [keys]，返回**第一个非空**的字符串值。
  ///
  /// 用 `json[k] ?? fallback` 是不够的：接口经常把 `screen_name` 返回成 `""`
  /// 而不是省略字段，那样 `??` 不会回退，名字就成了空白。
  static String _firstNonEmpty(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      final text = '$value'.trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return '';
  }

  static String _bigAvatar(String url) {
    if (url.isEmpty) return url;
    // profile_image_url is served at 50px; /avatar/ is 180px.
    return url.replaceFirst('/crop.0.0.1080.1080.50/', '/crop.0.0.1080.1080.180/');
  }
}

// ---------------------------------------------------------------------------
// Media
// ---------------------------------------------------------------------------

class Pic {
  final String url;
  final String? large;
  final int width;
  final int height;
  final String? videoUrl;
  final String? pid;

  const Pic({
    required this.url,
    this.large,
    this.width = 0,
    this.height = 0,
    this.videoUrl,
    this.pid,
  });

  static String? extractPid(String url) {
    final uri = Uri.tryParse(url);
    final seg = (uri != null && uri.pathSegments.isNotEmpty)
        ? uri.pathSegments.last
        : url;
    final dot = seg.indexOf('.');
    final stem = dot > 0 ? seg.substring(0, dot) : seg;
    return RegExp(r'^[A-Za-z0-9]{16,40}$').hasMatch(stem) ? stem : null;
  }

  double get aspectRatio => (width > 0 && height > 0) ? width / height : 1;

  bool get isGif {
    final u = (large ?? url).toLowerCase();
    return u.contains('.gif');
  }

  bool get isLongImage => width > 0 && height > 0 && (height / width) >= 2.2;

  static List<Pic> parseFromMapList(Map<String, dynamic> json) {
    final pics = <Pic>[];
    final infoMap = json['pic_infos'];
    if (infoMap is Map) {
      final ids = (json['pic_ids'] as List?)?.map((e) => '$e').toList() ??
          infoMap.keys.map((e) => '$e').toList();
      for (final id in ids) {
        final info = infoMap[id];
        if (info is! Map) continue;
        final large = (info['large'] ?? info['bmiddle'] ?? info['thumbnail']) as Map?;
        if (large == null) continue;
        final origUrl = (info['original'] is Map ? info['original']['url'] : null) ??
            large['url'];
        pics.add(Pic(
          url: jsonStr(large['url']),
          large: jsonNullableStr(origUrl),
          width: jsonInt(large['width']),
          height: jsonInt(large['height']),
          pid: id,
        ));
      }
      if (pics.isNotEmpty) return pics;
    }
    final singlePic = json['pic'];
    if (singlePic is Map) {
      final geo = singlePic['geo'];
      final largeMap = singlePic['large'];
      final largeUrl = largeMap is Map ? jsonStr(largeMap['url']) : '';
      final thumbUrl = jsonStr(singlePic['url']);
      final resolvedUrl = thumbUrl.isNotEmpty ? thumbUrl : largeUrl;
      if (resolvedUrl.isNotEmpty) {
        pics.add(Pic(
          url: resolvedUrl,
          large: largeUrl.isNotEmpty ? largeUrl : null,
          width: jsonInt(singlePic['width'] ?? (geo is Map ? geo['width'] : null)),
          height: jsonInt(singlePic['height'] ?? (geo is Map ? geo['height'] : null)),
          pid: jsonNullableStr(singlePic['pid']) ??
              extractPid(largeUrl.isNotEmpty ? largeUrl : thumbUrl),
        ));
      }
      if (pics.isNotEmpty) return pics;
    }
    if (json['pics'] is List) {
      for (final p in (json['pics'] as List)) {
        if (p is! Map) continue;
        final geo = p['geo'];
        final largeMap = p['large'];
        final largeGeo = largeMap is Map ? largeMap['geo'] : null;
        final u = jsonStr(p['url']);
        if (u.isEmpty) continue;
        final largeUrl = largeMap is Map ? jsonNullableStr(largeMap['url']) : null;
        pics.add(Pic(
          url: u,
          large: largeUrl,
          width: jsonInt(p['width'] ??
              (geo is Map ? geo['width'] : null) ??
              (largeGeo is Map ? largeGeo['width'] : null)),
          height: jsonInt(p['height'] ??
              (geo is Map ? geo['height'] : null) ??
              (largeGeo is Map ? largeGeo['height'] : null)),
          videoUrl: jsonNullableStr(p['video_url']),
          pid: jsonNullableStr(p['pid']) ?? extractPid(largeUrl ?? u),
        ));
      }
    }
    return pics;
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        if (large != null) 'large': {'url': large},
        if (width > 0) 'width': width,
        if (height > 0) 'height': height,
        if (videoUrl != null) 'video_url': videoUrl,
        if (pid != null) 'pid': pid,
      };
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

class Status {
  final String id;
  final String mblogid;
  final String createdAt;
  final String textHtml;
  final String textRaw;
  final String source;
  final User? user;
  final Status? retweeted;
  final List<Pic> pics;
  final int reposts;
  final int comments;
  final int attitudes;
  final bool isLongText;
  final bool favorited;
  final bool liked;
  final bool isTop;
  final int visible;
  final String region;
  final bool isVideo;
  final int videoDuration;
  final String? videoCover;
  final String? videoUrl;
  final String? videoObjectId;
  final String? topic;
  final Comment? hotComment;

  const Status({
    required this.id,
    required this.mblogid,
    required this.createdAt,
    required this.textHtml,
    required this.textRaw,
    required this.source,
    this.user,
    this.retweeted,
    this.pics = const [],
    this.reposts = 0,
    this.comments = 0,
    this.attitudes = 0,
    this.isLongText = false,
    this.favorited = false,
    this.liked = false,
    this.isTop = false,
    this.visible = 0,
    this.region = '',
    this.isVideo = false,
    this.videoDuration = 0,
    this.videoCover,
    this.videoUrl,
    this.videoObjectId,
    this.topic,
    this.hotComment,
  });

  factory Status.fromJson(Map<String, dynamic> json) {
    final pageInfo = jsonMap(json['page_info']);
    final outerIsVideo = pageInfo != null &&
        (pageInfo['type'] == 'video' ||
            pageInfo['object_type'] == 'video' ||
            pageInfo['media_info'] is Map);

    final pics = <Pic>[];
    final infoMap = jsonMap(json['pic_infos']);
    if (infoMap != null) {
      final ids = (json['pic_ids'] as List?)?.map((e) => '$e').toList() ??
          infoMap.keys.toList();
      for (final id in ids) {
        final info = infoMap[id];
        if (info is! Map) continue;
        final largeRaw = info['large'] ?? info['bmiddle'] ?? info['thumbnail'];
        if (largeRaw is! Map) continue;
        final bmidRaw = info['bmiddle'] ?? info['large'];
        final origRaw = info['original'];
        pics.add(Pic(
          url: jsonStr(largeRaw['url']),
          large: jsonNullableStr(
              (origRaw is Map ? origRaw['url'] : null) ?? largeRaw['url']),
          width: jsonInt(largeRaw['width']),
          height: jsonInt(largeRaw['height']),
          pid: id,
        ));
        // keep bmiddle for grid when large is oversized
        if (bmidRaw is Map && pics.isNotEmpty) {
          // no-op: bmiddle handled by url rewrite in widget
        }
      }
    } else if (json['pics'] is List) {
      for (final p in (json['pics'] as List)) {
        if (p is Map) {
          final geo = p['geo'];
          final largeMap = p['large'];
          final largeGeo = largeMap is Map ? largeMap['geo'] : null;
          final u = jsonStr(p['url']);
          final largeUrl = largeMap is Map ? jsonNullableStr(largeMap['url']) : null;
          pics.add(Pic(
            url: u,
            large: largeUrl,
            width: jsonInt(p['width'] ??
                (geo is Map ? geo['width'] : null) ??
                (largeGeo is Map ? largeGeo['width'] : null)),
            height: jsonInt(p['height'] ??
                (geo is Map ? geo['height'] : null) ??
                (largeGeo is Map ? largeGeo['height'] : null)),
            videoUrl: jsonNullableStr(p['video_url']),
            pid: jsonNullableStr(p['pid']) ?? Pic.extractPid(largeUrl ?? u),
          ));
        }
      }
    } else if (json['pic_urls'] is List) {
      for (final p in (json['pic_urls'] as List)) {
        if (p is Map) {
          final thumb = jsonStr(p['thumbnail_pic']).trim();
          if (thumb.isNotEmpty) {
            pics.add(Pic(
              url: thumb.replaceFirst('/thumbnail/', '/bmiddle/'),
              large: thumb.replaceFirst('/thumbnail/', '/large/'),
              pid: Pic.extractPid(thumb),
            ));
          }
        }
      }
    }

    final retweetedMap = jsonMap(json['retweeted_status']);
    var retweeted = retweetedMap != null ? Status.fromJson(retweetedMap) : null;
    final userMap = jsonMap(json['user']);
    final longTextObj = jsonMap(json['longText']);
    final longTextStr =
        longTextObj != null ? jsonStr(longTextObj['longTextContent']) : '';
    final resolvedText =
        longTextStr.isNotEmpty ? longTextStr : jsonStr(json['text']);
    final attStatus = jsonInt(json['attitudes_status']);

    final picInfoMap = pageInfo?['pic_info'];
    final outerVideoCover = _picUrl(pageInfo?['page_pic']) ??
        _picUrl(picInfoMap is Map
            ? (picInfoMap['pic_big'] ?? picInfoMap['pic_middle'] ?? picInfoMap['pic_small'])
            : null);
    final rawObjectId = jsonStr(pageInfo?['object_id']).trim();
    final outerVideoObjectId = rawObjectId.isNotEmpty ? rawObjectId : null;
    final mediaInfoMap = jsonMap(pageInfo?['media_info']);
    final outerVideoDuration = jsonInt(mediaInfoMap?['duration']);
    final outerVideoUrl = _videoUrl(pageInfo, allowPageUrlFallback: outerIsVideo);

    var effectiveIsVideo = outerIsVideo;
    var effectiveVideoDuration = outerVideoDuration;
    String? effectiveVideoCover = outerVideoCover;
    String? effectiveVideoUrl = outerVideoUrl;
    String? effectiveVideoObjectId = outerVideoObjectId;

    // 转发微博时，微博接口常把原博的视频 page_info 挂在外层转发微博对象上（而非 retweeted_status 内）。
    // 将此类视频元数据归并回被转发的原微博内部，使视频显示在引用框内部而非外层。
    if (retweeted != null && outerIsVideo) {
      retweeted = _mergeRetweetVideo(
        retweeted,
        outerDuration: outerVideoDuration,
        outerCover: outerVideoCover,
        outerUrl: outerVideoUrl,
        outerObjectId: outerVideoObjectId,
      );
      effectiveIsVideo = false;
      effectiveVideoDuration = 0;
      effectiveVideoCover = null;
      effectiveVideoUrl = null;
      effectiveVideoObjectId = null;
    }

    final rawHotComment = json['hot_comment'] ??
        json['recommend_comment'] ??
        (json['hot_comments'] is List && (json['hot_comments'] as List).isNotEmpty
            ? (json['hot_comments'] as List).first
            : null);
    final hotCommentMap = jsonMap(rawHotComment);
    final hotComment =
        hotCommentMap != null ? Comment.fromJson(hotCommentMap) : null;
    final titleObj = json['title'];
    final isTop = jsonBool(json['isTop']) ||
        jsonBool(json['is_top']) ||
        jsonInt(json['mblogtype']) == 2 ||
        (titleObj is Map && '${titleObj['text']}'.contains('置顶'));
    final rawVisible = json['visible'];
    final visible = rawVisible is Map
        ? jsonInt(rawVisible['type'])
        : jsonInt(rawVisible);
    final textRawStr = jsonStr(json['text_raw']);

    return Status(
      id: '${json['idstr'] ?? json['id'] ?? ''}',
      mblogid: '${json['mblogid'] ?? json['mid'] ?? json['idstr'] ?? json['id'] ?? ''}',
      createdAt: jsonStr(json['created_at']),
      textHtml: resolvedText,
      textRaw: textRawStr.isNotEmpty
          ? textRawStr
          : RichTextParser.toPlain(resolvedText),
      source: jsonStr(json['source']),
      user: userMap != null ? User.fromJson(userMap) : null,
      retweeted: retweeted,
      pics: pics,
      reposts: jsonInt(json['reposts_count']),
      comments: jsonInt(json['comments_count']),
      attitudes: jsonInt(json['attitudes_count']),
      isLongText: jsonBool(json['isLongText']) || (longTextObj != null),
      favorited: jsonBool(json['favorited']),
      liked: jsonBool(json['liked']) || attStatus == 1,
      isTop: isTop,
      visible: visible,
      region: jsonStr(json['region_name']),
      isVideo: effectiveIsVideo,
      videoDuration: effectiveVideoDuration,
      videoCover: effectiveVideoCover,
      videoUrl: effectiveVideoUrl,
      videoObjectId: effectiveVideoObjectId,
      topic: _topicTitle(json['topic_struct']),
      hotComment: (hotComment != null && hotComment.textHtml.isNotEmpty) ? hotComment : null,
    );
  }

  static Status _mergeRetweetVideo(
    Status original, {
    required int outerDuration,
    required String? outerCover,
    required String? outerUrl,
    required String? outerObjectId,
  }) {
    final origCover =
        (original.videoCover != null && original.videoCover!.isNotEmpty)
            ? original.videoCover
            : outerCover;
    final origUrl =
        (original.videoUrl != null && original.videoUrl!.isNotEmpty)
            ? original.videoUrl
            : outerUrl;
    final origObjectId =
        (original.videoObjectId != null && original.videoObjectId!.isNotEmpty)
            ? original.videoObjectId
            : outerObjectId;
    return original.copyWith(
      isVideo: true,
      videoDuration:
          original.videoDuration > 0 ? original.videoDuration : outerDuration,
      videoCover: origCover,
      videoUrl: origUrl,
      videoObjectId: origObjectId,
    );
  }

  bool get hasPlayableVideo =>
      (videoUrl != null && videoUrl!.isNotEmpty) ||
      (videoObjectId != null && videoObjectId!.isNotEmpty);

  bool get hasVideoMedia =>
      isVideo &&
      (hasPlayableVideo || (videoCover != null && videoCover!.isNotEmpty));

  /// 返回已归一化的引用原博（即使早期缓存中仍将视频挂在外层 `Status`，也可在 UI 侧折叠回引用框内）。
  Status? get resolvedRetweeted {
    final rt = retweeted;
    if (rt == null) return null;
    if (!isVideo) return rt;
    return _mergeRetweetVideo(
      rt,
      outerDuration: videoDuration,
      outerCover: videoCover,
      outerUrl: videoUrl,
      outerObjectId: videoObjectId,
    );
  }

  /// 点击播放时定位真实视频所在的微博（优先外层可播视频，否则回退至引用原博）。
  Status get resolvedVideoTarget {
    if (hasPlayableVideo) return this;
    final rt = resolvedRetweeted;
    if (rt != null && rt.hasPlayableVideo) return rt;
    return rt ?? this;
  }

  String get cleanSource {
    if (source.isEmpty) return '';
    final text = source.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    return text;
  }

  Status copyWith({
    int? reposts,
    int? comments,
    int? attitudes,
    bool? liked,
    bool? favorited,
    bool? isTop,
    int? visible,
    String? textHtml,
    String? textRaw,
    bool? isLongText,
    Status? retweeted,
    bool? isVideo,
    int? videoDuration,
    String? videoCover,
    String? videoUrl,
    String? videoObjectId,
  }) {
    return Status(
      id: id,
      mblogid: mblogid,
      createdAt: createdAt,
      textHtml: textHtml ?? this.textHtml,
      textRaw: textRaw ?? this.textRaw,
      source: source,
      user: user,
      retweeted: retweeted ?? this.retweeted,
      pics: pics,
      reposts: reposts ?? this.reposts,
      comments: comments ?? this.comments,
      attitudes: attitudes ?? this.attitudes,
      isLongText: isLongText ?? this.isLongText,
      favorited: favorited ?? this.favorited,
      liked: liked ?? this.liked,
      isTop: isTop ?? this.isTop,
      visible: visible ?? this.visible,
      region: region,
      isVideo: isVideo ?? this.isVideo,
      videoDuration: videoDuration ?? this.videoDuration,
      videoCover: videoCover ?? this.videoCover,
      videoUrl: videoUrl ?? this.videoUrl,
      videoObjectId: videoObjectId ?? this.videoObjectId,
      topic: topic,
      hotComment: hotComment,
    );
  }

  Map<String, dynamic> toJson() => {
        'idstr': id,
        'mblogid': mblogid,
        'created_at': createdAt,
        'text': textHtml,
        'text_raw': textRaw,
        'source': source,
        if (user != null) 'user': user!.toJson(),
        if (retweeted != null) 'retweeted_status': retweeted!.toJson(),
        if (pics.isNotEmpty) 'pics': pics.map((p) => p.toJson()).toList(),
        'reposts_count': reposts,
        'comments_count': comments,
        'attitudes_count': attitudes,
        'isLongText': isLongText,
        'favorited': favorited,
        'liked': liked,
        if (isTop) 'isTop': 1,
        if (visible != 0) 'visible': visible,
        if (region.isNotEmpty) 'region_name': region,
        if (isVideo)
          'page_info': {
            'type': 'video',
            if (videoCover != null) 'page_pic': videoCover,
            if (videoObjectId != null) 'object_id': videoObjectId,
            'media_info': {
              'duration': videoDuration,
              if (videoUrl != null) 'mp4_720p_mp4': videoUrl,
            },
          },
        if (topic != null && topic!.isNotEmpty)
          'topic_struct': [
            {'topic_title': topic},
          ],
      };
}

// ---------------------------------------------------------------------------
// Comment
// ---------------------------------------------------------------------------

class Comment {
  final String id;
  final String rootId;
  final String createdAt;
  final String textHtml;
  final User? user;
  final int likeCount;
  final int replyCount;
  final int floor;
  final Comment? replyTo;
  final bool likedByAuthor;
  final bool likedByMe;
  final List<Comment> replies;
  final List<Pic> pics;

  const Comment({
    required this.id,
    required this.rootId,
    required this.createdAt,
    required this.textHtml,
    this.user,
    this.likeCount = 0,
    this.replyCount = 0,
    this.floor = 0,
    this.replyTo,
    this.likedByAuthor = false,
    this.likedByMe = false,
    this.replies = const [],
    this.pics = const [],
  });

  factory Comment.fromJson(Map<String, dynamic> json) {
    final reply = json['reply_comment'];
    final floor = jsonInt(json['floor_number']);
    final likeFlag = jsonBool(json['liked']) ||
        jsonBool(json['is_liked']) ||
        jsonInt(json['like_status']) == 1;

    final rawSubList = json['comments'] ??
        json['commentFloors'] ??
        json['sub_comments'];
    final parsedReplies = <Comment>[];
    if (rawSubList is List) {
      for (final item in rawSubList) {
        final itemMap = jsonMap(item);
        if (itemMap != null) {
          parsedReplies.add(Comment.fromJson(itemMap));
        }
      }
    }

    var replyCount = jsonInt(json['total_number']);
    if (replyCount <= 0 && json['more_info'] is Map) {
      final moreText = '${(json['more_info'] as Map)['text'] ?? ''}';
      final digits = RegExp(r'\d+').firstMatch(moreText)?.group(0);
      if (digits != null) {
        replyCount = int.tryParse(digits) ?? 0;
      }
    }
    if (replyCount < parsedReplies.length) {
      replyCount = parsedReplies.length;
    }

    final userMap = jsonMap(json['user']);
    final replyMap = jsonMap(reply);

    return Comment(
      id: '${json['idstr'] ?? json['id'] ?? ''}',
      rootId: '${json['rootidstr'] ?? json['rootid'] ?? json['idstr'] ?? json['id'] ?? ''}',
      createdAt: jsonStr(json['created_at']),
      textHtml: jsonStr(json['text']),
      user: userMap != null ? User.fromJson(userMap) : null,
      likeCount: jsonNullableInt(json['like_counts']) ??
          jsonNullableInt(json['like_count']) ??
          0,
      replyCount: replyCount,
      floor: floor,
      replyTo: replyMap != null ? Comment.fromJson(replyMap) : null,
      likedByAuthor: jsonBool(json['isLikedByMblogAuthor']),
      likedByMe: likeFlag,
      replies: parsedReplies,
      pics: Pic.parseFromMapList(json),
    );
  }

  Comment copyWith({
    int? likeCount,
    bool? likedByMe,
    List<Comment>? replies,
    int? replyCount,
  }) =>
      Comment(
        id: id,
        rootId: rootId,
        createdAt: createdAt,
        textHtml: textHtml,
        user: user,
        likeCount: likeCount ?? this.likeCount,
        replyCount: replyCount ?? this.replyCount,
        floor: floor,
        replyTo: replyTo,
        likedByAuthor: likedByAuthor,
        likedByMe: likedByMe ?? this.likedByMe,
        replies: replies ?? this.replies,
        pics: pics,
      );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class Paged<T> {
  final List<T> items;
  final String? maxId;
  final bool hasMore;

  const Paged({required this.items, this.maxId, this.hasMore = true});
}

Map<String, dynamic> decodeObject(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is Map<String, dynamic>) return decoded;
  throw const FormatException('接口返回格式异常');
}

Map<String, dynamic>? jsonMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

int jsonInt(dynamic value, [int fallback = 0]) {
  return jsonNullableInt(value) ?? fallback;
}

int? jsonNullableInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed) ?? double.tryParse(trimmed)?.toInt();
  }
  if (value is bool) return value ? 1 : 0;
  return null;
}

double jsonDouble(dynamic value, [double fallback = 0.0]) {
  if (value == null) return fallback;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return fallback;
    return double.tryParse(trimmed) ?? fallback;
  }
  return fallback;
}

bool jsonBool(dynamic value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final lower = value.trim().toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0' || lower.isEmpty) return false;
  }
  return fallback;
}

String jsonStr(dynamic value, [String fallback = '']) {
  if (value == null) return fallback;
  if (value is String) return value;
  return value.toString();
}

String? jsonNullableStr(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

/// `page_pic` is sometimes `{url: ...}` and sometimes a bare string (or a list)
/// depending on the card type, so normalise defensively.
String? _picUrl(dynamic value) {
  if (value == null) return null;
  if (value is String) return _normalizeMediaUrl(value);
  if (value is Map) {
    return _normalizeMediaUrl(value['url']);
  }
  if (value is List && value.isNotEmpty) return _picUrl(value.first);
  return null;
}

String? _normalizeMediaUrl(dynamic value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('//')) return 'https:$trimmed';
  return trimmed;
}

String? _pickFromUrlMap(dynamic map) {
  if (map is! Map) return null;
  for (final key in const [
    'mp4_720p_mp4',
    'mp4_720p_url',
    'mp4_hd_mp4',
    'mp4_hd_url',
    'inch_5_5_mp4_hd',
    'inch_5_mp4_hd',
    'mp4_sd_mp4',
    'mp4_sd_url',
    'mp4_ld_mp4',
    'hevc_mp4_hd',
  ]) {
    final u = _normalizeMediaUrl(map[key]);
    if (u != null && u.startsWith('http')) return u;
  }
  for (final v in map.values) {
    final u = _normalizeMediaUrl(v);
    if (u != null && u.startsWith('http')) return u;
  }
  return null;
}

String? _pickFromPlaybackList(dynamic list) {
  if (list is! List) return null;
  String? fallback;
  for (final entry in list) {
    if (entry is! Map) continue;
    final playInfo = entry['play_info'];
    final u = _normalizeMediaUrl(
      playInfo is Map ? playInfo['url'] : entry['url'],
    );
    if (u == null || !u.startsWith('http')) continue;
    final meta = (entry['meta'] is Map) ? entry['meta'] as Map : const {};
    final quality = '${meta['quality_class'] ?? meta['label'] ?? ''}';
    if (quality.contains('720') || (!u.contains('.m3u8') && quality.contains('HD'))) {
      return u;
    }
    fallback ??= u;
    if (!u.contains('.m3u8') && fallback.contains('.m3u8')) {
      fallback = u;
    }
  }
  return fallback;
}

String? _videoUrl(dynamic pageInfo, {bool allowPageUrlFallback = true}) {
  if (pageInfo is! Map) return null;
  final media = pageInfo['media_info'];
  if (media is Map) {
    for (final key in const [
      'mp4_720p_mp4',
      'mp4_720p_url',
      'inch_5_5_mp4_hd',
      'inch_5_mp4_hd',
      'inch_4_mp4_hd',
      'mp4_hd_mp4',
      'mp4_hd_url',
      'mp4_sd_mp4',
      'mp4_sd_url',
      'mp4_ld_mp4',
      'stream_url_hd',
      'stream_url',
      'h264_mp4_720p',
      'h264_mp4_hd',
      'h265_mp4_hd',
      'h265_mp4_ld',
      'hevc_mp4_hd',
    ]) {
      final u = _normalizeMediaUrl(media[key]);
      if (u != null && u.startsWith('http')) return u;
    }
    final fromPlayback = _pickFromPlaybackList(media['playback_list']);
    if (fromPlayback != null) return fromPlayback;
    final fromMediaUrls = _pickFromUrlMap(media['urls']);
    if (fromMediaUrls != null) return fromMediaUrls;
  }
  final fromPageUrls = _pickFromUrlMap(pageInfo['urls']);
  if (fromPageUrls != null) return fromPageUrls;
  if (allowPageUrlFallback) {
    final fallback = _normalizeMediaUrl(pageInfo['page_url'] ?? pageInfo['url']);
    if (fallback != null) return fallback;
  }
  return null;
}

String? _topicTitle(dynamic value) {
  if (value is! List || value.isEmpty) return null;
  final first = value.first;
  if (first is Map) {
    final title = first['topic_title'];
    if (title is String && title.isNotEmpty) return title;
  }
  return null;
}

String formatCount(int value) {
  if (value < 10000) return '$value';
  final wan = value / 10000;
  if (wan < 10) return '${wan.toStringAsFixed(1).replaceAll('.0', '')}万';
  return '${wan.toStringAsFixed(0)}万';
}

final _months = {
  'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
  'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
};

/// Parses `Sun Nov 01 00:17:50 +0800 2026` or ISO-8601 dates to epoch milliseconds (`0` if invalid).
int parseWeiboTimeMs(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 0;
  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length >= 6) {
    final month = _months[parts[1]];
    if (month != null) {
      final day = int.tryParse(parts[2]) ?? 1;
      final hms = parts[3].split(':');
      final year = int.tryParse(parts[5]) ?? DateTime.now().year;
      final tz = parts[4];
      final sign = tz.startsWith('-') ? -1 : 1;
      final offH = tz.length >= 3 ? (int.tryParse(tz.substring(1, 3)) ?? 8) : 8;
      final offM = tz.length >= 5 ? (int.tryParse(tz.substring(3, 5)) ?? 0) : 0;
      return DateTime.utc(
        year,
        month,
        day,
        hms.isNotEmpty ? (int.tryParse(hms[0]) ?? 0) : 0,
        hms.length > 1 ? (int.tryParse(hms[1]) ?? 0) : 0,
        hms.length > 2 ? (int.tryParse(hms[2]) ?? 0) : 0,
      )
          .subtract(Duration(hours: sign * offH, minutes: sign * offM))
          .millisecondsSinceEpoch;
    }
  }
  final parsedIso = DateTime.tryParse(trimmed);
  return parsedIso?.millisecondsSinceEpoch ?? 0;
}

/// Parses `Sun Nov 01 00:17:50 +0800 2026` and renders Share-style relative time.
String formatWeiboTime(String raw) {
  final ms = parseWeiboTimeMs(raw);
  if (ms <= 0) return raw;
  final local = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final diff = now.difference(local);

  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24 && now.day == local.day) return '${diff.inHours}小时前';

  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(local.year, local.month, local.day);
  final dayDiff = today.difference(that).inDays;
  if (dayDiff == 1) return '昨天 ${_two(local.hour)}:${_two(local.minute)}';
  if (local.year == now.year) return '${_two(local.month)}-${_two(local.day)}';
  return '${local.year}-${_two(local.month)}-${_two(local.day)}';
}

String _two(int v) => v.toString().padLeft(2, '0');
