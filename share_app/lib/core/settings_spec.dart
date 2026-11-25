/// Declarative mirror of the original APK's `res/xml/g..q.xml` preference
/// screens.
///
/// Every entry keeps the **original preference key, title, default value and
/// option enumeration** so the rebuilt settings tree matches Share 3.9.6 item
/// for item. `live` marks the entries that actually change behaviour in this
/// build; the rest are persisted (so a value round-trips) but have no consumer
/// yet — mostly Android-service features (通知常驻、悬浮窗、CustomTabs) that a
/// Flutter port cannot own.
library;

enum PrefKind {
  /// `CustomSwitchPreference` / `CustomCheckBoxPreference`
  toggle,

  /// `CustomListPreference` — single choice, radio dialog
  choice,

  /// `CustomMultiSelectListPreference` — checkbox dialog
  multi,

  /// `SeekBarPreference`
  slider,

  /// `Preference` that opens another screen
  nav,
}

class PrefOption {
  final int value;
  final String label;

  const PrefOption(this.value, this.label);
}

class PrefItem {
  /// Original `android:key`, kept verbatim for traceability.
  final String key;
  final String title;
  final PrefKind kind;

  /// `true` when the value drives real behaviour in this build.
  final bool live;

  /// Toggle default.
  final bool defaultOn;

  /// Choice / slider default.
  final int defaultChoice;

  final List<PrefOption> options;

  /// Multi-select default (option values).
  final List<int> defaultMulti;

  /// Slider bounds (percent for 行距).
  final int min;
  final int max;

  /// Original `android:summary` / behaviour note.
  final String? note;

  /// For [PrefKind.nav]: internal route id (see `PrefPage` router) or a
  /// `https://` URL to open in the in-app browser.
  final String? route;

  const PrefItem.toggle(
    this.key,
    this.title, {
    this.defaultOn = false,
    this.live = false,
    this.note,
  })  : kind = PrefKind.toggle,
        defaultChoice = 0,
        options = const [],
        defaultMulti = const [],
        min = 0,
        max = 0,
        route = null;

  const PrefItem.choice(
    this.key,
    this.title, {
    required this.defaultChoice,
    required this.options,
    this.live = false,
    this.note,
  })  : kind = PrefKind.choice,
        defaultOn = false,
        defaultMulti = const [],
        min = 0,
        max = 0,
        route = null;

  const PrefItem.multi(
    this.key,
    this.title, {
    required this.options,
    this.defaultMulti = const [],
    this.live = false,
    this.note,
  })  : kind = PrefKind.multi,
        defaultOn = false,
        defaultChoice = 0,
        min = 0,
        max = 0,
        route = null;

  const PrefItem.slider(
    this.key,
    this.title, {
    required this.defaultChoice,
    this.min = 0,
    this.max = 100,
    this.live = false,
    this.note,
  })  : kind = PrefKind.slider,
        defaultOn = false,
        options = const [],
        defaultMulti = const [],
        route = null;

  const PrefItem.nav(
    this.key,
    this.title, {
    required this.route,
    this.note,
  })  : kind = PrefKind.nav,
        live = false,
        defaultOn = false,
        defaultChoice = 0,
        options = const [],
        defaultMulti = const [],
        min = 0,
        max = 0;

  Object? get defaultValue => switch (kind) {
        PrefKind.toggle => defaultOn,
        PrefKind.choice || PrefKind.slider => defaultChoice,
        PrefKind.multi => defaultMulti,
        PrefKind.nav => null,
      };
}

class PrefGroup {
  /// Optional `CustomPreferenceCategory` caption above the group.
  final String? title;
  final List<PrefItem> items;

  const PrefGroup({required this.items, this.title});
}

class PrefPage {
  final String key;
  final String title;
  final String? blurb;
  final List<PrefGroup> groups;

  const PrefPage({
    required this.key,
    required this.title,
    this.blurb,
    required this.groups,
  });

  Iterable<PrefItem> get all => groups.expand((g) => g.items);

  static PrefPage? byKey(String key) {
    for (final page in pages) {
      if (page.key == key) return page;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// 6.13.1 设置主导航大厅 (g.xml) — 3 categories / 11 entries
// ---------------------------------------------------------------------------

/// Root hub rows, in the original order.
const settingsRoot = <({String? category, String title, String? route})>[
  (category: '常规设置', title: '基本设置', route: 'basic'),
  (category: null, title: '流量控制', route: 'traffic'),
  (category: null, title: '音效管理', route: 'sound'),
  (category: null, title: '通知设置', route: 'notify'),
  (category: null, title: '隐私设置', route: 'privacy'),
  (category: '显示设置', title: '阅读习惯', route: 'reading'),
  (category: null, title: '微博样式', route: 'card'),
  (category: null, title: '布局样式', route: 'layout'),
  (category: '其他', title: 'Share高级版', route: 'pro'),
  (category: null, title: 'Share实验室', route: 'lab'),
  (category: null, title: '关于', route: 'about'),
];

// ---------------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------------

final _lang = [
  const PrefOption(1, '跟随系统'),
  const PrefOption(2, '简体中文'),
  const PrefOption(3, '繁体中文'),
  const PrefOption(4, 'English'),
];

const _nightThemes = [
  PrefOption(1, '夜间黑'),
  PrefOption(2, 'A屏黑'),
  PrefOption(3, '夜间蓝'),
];

const _avatarShape = [
  PrefOption(1, '正方形'),
  PrefOption(2, '正方圆角'),
  PrefOption(3, '圆形'),
];

final _fontSizes = [
  for (final pt in [13, 14, 15, 16, 17, 18, 19, 20, 21, 23])
    PrefOption(pt, '$pt pt'),
];

/// 6.13.3 基本与常规交互设置 (i.xml)
final prefBasic = PrefPage(
  key: 'basic',
  title: '基本设置',
  blurb: '后退手势、语言、屏幕方向、相册与内置浏览器',
  groups: [
    PrefGroup(title: '常规设置', items: [
      const PrefItem.toggle('home_back', '首页按返回键退出',
          note: '退出应用，不在后台运行'),
      PrefItem.choice('swipe_back', '二级页面滑动后退', defaultChoice: 3, options: [
        const PrefOption(1, '向右滑动退出'),
        const PrefOption(2, '向左滑动退出'),
        const PrefOption(3, '向左或右滑动退出'),
        const PrefOption(4, '禁用'),
      ]),
      PrefItem.choice('language', '语言', defaultChoice: 1, options: _lang),
      PrefItem.choice('orientation_new', '屏幕方向', defaultChoice: 1, options: [
        const PrefOption(1, '竖屏'),
        const PrefOption(2, '横屏'),
      ]),
      PrefItem.choice('ic_launcher', '应用图标', defaultChoice: 1, live: true, options: [
        const PrefOption(1, '经典蓝黑 (默认)'),
        const PrefOption(2, '简约白底'),
        const PrefOption(3, '暗夜纯黑'),
        const PrefOption(4, '扁平渐变'),
        const PrefOption(5, '淡雅紫'),
      ]),
      const PrefItem.toggle('same_photo_name', '防止重复保存图片',
          note: '多次保存会出现多张重复图片，图片文件名会以当前时间命名'),
      const PrefItem.nav('save_photo_path', '图片保存路径',
          route: 'save_photo_path'),
      const PrefItem.nav('save_video_path', '视频保存路径',
          route: 'save_video_path'),
      const PrefItem.toggle('click_photo_back', '点击图片返回',
          defaultOn: true),
      const PrefItem.toggle('drag_photo_back', '拖拽图片返回',
          defaultOn: true),
      const PrefItem.nav('clear_photo_cache', '清除图片缓存',
          route: 'clear_photo_cache'),
      const PrefItem.toggle('internal_app_browser', '使用内置浏览器',
          defaultOn: true),
      const PrefItem.toggle('custom_tabs_ui', '使用CustomTabs',
          defaultOn: true,
          note: '外部浏览器打开链接时，顶部标题背景使用应用主题色(需 Chrome 支持)'),
    ]),
  ],
);

/// 6.13.4 流量控制与多媒体画质 (j.xml)
final prefTraffic = PrefPage(
  key: 'traffic',
  title: '流量控制',
  blurb: '预读流控、拉取条数、动图视频自动播放与图片质量',
  groups: [
    PrefGroup(title: '常规设置', items: [
      const PrefItem.toggle('preread', '预读模式',
          defaultOn: true, live: true, note: '浏览到尽头前提前加载，避免等待'),
      PrefItem.choice('load_status_count', '首页加载微博时的条数',
          defaultChoice: 1, live: true, options: [
        const PrefOption(1, '自动'),
        const PrefOption(2, '30条'),
        const PrefOption(3, '50条'),
        const PrefOption(4, '88条'),
        const PrefOption(5, '100条'),
      ]),
      PrefItem.choice('auto_play_options', '自动播放视频和动图',
          defaultChoice: 3, live: true, options: [
        const PrefOption(1, '仅Wi-Fi'),
        const PrefOption(2, '总是'),
        const PrefOption(3, '从不'),
      ]),
      PrefItem.choice('video_play_quality', '视频播放优先质量',
          defaultChoice: 3, options: [
        const PrefOption(1, '超清'),
        const PrefOption(2, '高清'),
        const PrefOption(3, '标清'),
        const PrefOption(4, '流畅'),
        const PrefOption(5, '自动'),
      ]),
    ]),
    PrefGroup(title: '图片', items: [
      const PrefItem.toggle('save_image_original', '保存图片时默认保存原图', live: true),
      PrefItem.multi('show_avatar', '不显示头像', options: [
        const PrefOption(1, '微博头像'),
        const PrefOption(2, '评论、转发、赞头像'),
        const PrefOption(3, 'Wi-Fi下不隐藏头像'),
      ], note: '关闭可以节省流量'),
      PrefItem.choice('download_image_quality', '微博图片加载质量',
          defaultChoice: 5, live: true, options: [
        const PrefOption(1, '无图'),
        const PrefOption(2, '缩略图'),
        const PrefOption(3, '高清图'),
        const PrefOption(4, '原图'),
        const PrefOption(5, '自动'),
        const PrefOption(6, '仅Wi-Fi下加载'),
      ]),
      PrefItem.choice('show_comment_photo_options', '显示评论图片',
          defaultChoice: 1, options: [
        const PrefOption(1, '跟随微博图片'),
        const PrefOption(2, '仅Wi-Fi下加载'),
        const PrefOption(3, '从不'),
      ]),
      PrefItem.choice('photo_upload_quality', '图片上传的默认质量',
          defaultChoice: 2, live: true, options: [
        const PrefOption(1, '压缩处理'),
        const PrefOption(2, '原图'),
        const PrefOption(3, '自动'),
      ]),
    ]),
  ],
);

/// 6.13.10 声音音效与震动触觉 (p.xml)
final prefSound = PrefPage(
  key: 'sound',
  title: '音效管理',
  blurb: '全局静音、操作音效与震动反馈',
  groups: [
    PrefGroup(title: '铃声设置', items: [
      const PrefItem.toggle('sound_off', '静音模式', note: '关闭一切提醒音效'),
      PrefItem.multi('ringtone_type', '音效类型', options: [
        const PrefOption(1, '首页有新的微博'),
        const PrefOption(2, '未读通知'),
        const PrefOption(3, '视频下载成功'),
      ]),
      const PrefItem.nav('ringtone_notify_oreo', '调整通知的振动和铃声',
          route: 'system_sound'),
    ]),
    PrefGroup(title: '振动设置', items: [
      const PrefItem.toggle('vibration_on', '开启振动', defaultOn: true),
      const PrefItem.toggle('vibration_feedback', '振动反馈',
          defaultOn: true, note: '内容发送成功后振动反馈'),
    ]),
  ],
);

/// 6.13.6 通知推送与后台保活 (l.xml)
final prefNotify = PrefPage(
  key: 'notify',
  title: '通知设置',
  blurb: '不支持实时推送：消息通知需要保持应用开启并允许后台运行',
  groups: [
    PrefGroup(items: [
      const PrefItem.toggle('notify_open', '开启通知提醒', defaultOn: true),
      const PrefItem.nav('notify_oreo', '调整通知的振动和铃声', route: 'system_sound'),
      const PrefItem.toggle('app_persistent', '开启应用常驻后台',
          note: '开启后通知栏会有无法移除的通知'),
      const PrefItem.toggle('remind_dm_subscribe_ignore', '消息页屏蔽订阅类私信'),
      const PrefItem.nav('remind_dm_subscribe_manage', '订阅类私信管理',
          route: 'https://api.weibo.com/chat'),
    ]),
    PrefGroup(title: '提醒设置', items: [
      const PrefItem.toggle('special_follow_remind', '特别关注微博提醒'),
      PrefItem.multi('remind_notify_type', '通知提醒类型', options: [
        const PrefOption(1, '评论'),
        const PrefOption(2, '@我'),
        const PrefOption(3, '私信'),
        const PrefOption(4, '新粉丝'),
        const PrefOption(5, '点赞'),
      ]),
      PrefItem.multi('remind_unread_type', '数字红点提醒类型',
          defaultMulti: [1, 2, 3], live: true, options: [
        const PrefOption(1, '评论'),
        const PrefOption(2, '@我'),
        const PrefOption(3, '点赞'),
      ]),
      const PrefItem.toggle('remind_by_vibration', '振动提醒', defaultOn: true),
      const PrefItem.toggle('remind_by_lights', '呼吸灯提醒',
          defaultOn: true, note: '需手机支持'),
    ]),
  ],
);

/// 6.13.7 隐私控制与黑名单过滤 (m.xml)
final prefPrivacy = PrefPage(
  key: 'privacy',
  title: '隐私设置',
  blurb: '黑名单、关键词屏蔽与小尾巴控制',
  groups: [
    PrefGroup(items: [
      const PrefItem.nav('privacy_common', '通用设置', route: 'privacy_common'),
      const PrefItem.nav('blacklist', '黑名单与过滤', route: 'blacklist'),
      const PrefItem.nav('black_content', '关键词屏蔽', route: 'black_content'),
      const PrefItem.nav('block_status', '微博尾巴屏蔽', route: 'block_status'),
      const PrefItem.toggle('repost_direct', '微博快转', defaultOn: true, live: true),
      const PrefItem.nav('recently_visit', '经常访问与历史', route: 'recently_visit'),
    ]),
  ],
);

/// 6.13.8 阅读习惯与视频引擎 (n.xml)
final prefReading = PrefPage(
  key: 'reading',
  title: '阅读习惯',
  blurb: '夜间模式、逆序排版、长按点赞与小窗视频',
  groups: [
    PrefGroup(items: [
      PrefItem.choice('night_theme', '默认夜间主题',
          defaultChoice: 3, live: true, options: _nightThemes),
      const PrefItem.toggle('auto_night_mode_follow_system', '夜间模式跟随系统', live: true),
      const PrefItem.toggle('auto_night_mode', '自动切换夜间模式',
          defaultOn: true, live: true),
      const PrefItem.nav('auto_night_mode_duration', '自定义夜间模式时间',
          route: 'night_duration'),
      const PrefItem.toggle('night_shade_mode', '图片适配夜间模式',
          live: true,
          note: '夜间模式时部分图片缩略图会变暗，减少亮度保护眼睛'),
      const PrefItem.toggle('read_verse_order', '逆序浏览',
          note: '不能保证微博一定可以连续逆序浏览'),
      const PrefItem.toggle('like_status_long_click', '点赞通过长按触发',
          live: true,
          note: '避免单击误触点赞'),
      const PrefItem.toggle('show_like_status_error', '开启点赞失败提示',
          note: '微博点赞可能失败，默认忽略错误直接显示成功'),
      const PrefItem.toggle('show_recommend_status', '显示最近赞过的微博',
          defaultOn: true, note: '时间线显示好友最近赞过和打赏过的微博'),
      const PrefItem.toggle('video_play_list', '视频播放开启专辑模式',
          defaultOn: true),
      const PrefItem.toggle('auto_fullscreen_video', '视频播放默认全屏'),
      const PrefItem.toggle('floating_video', '默认使用悬浮窗加载视频',
          note: '需要悬浮窗权限'),
      const PrefItem.toggle('floating_video_move', '悬浮窗直接移动',
          note: '默认需要长按才能触发移动'),
      const PrefItem.toggle('video_controller_hide', '禁止视频手势控制'),
      const PrefItem.toggle('auto_close_video', '视频播放完毕后自动关闭'),
      const PrefItem.toggle('start_refresh_status', '打开应用后自动刷新微博',
          note: '开启后下次启动不再保留旧的浏览记录'),
      const PrefItem.toggle('auto_refresh_status', '切换分组自动刷新微博'),
      const PrefItem.toggle('reselect_tab_refresh', '当重复点击首页的tab时刷新',
          defaultOn: true, live: true),
      const PrefItem.toggle('hot_status_comment_preview', '预览热门微博评论',
          defaultOn: true),
      const PrefItem.toggle('comment_floor', '微博评论楼中楼显示',
          defaultOn: true, live: true),
      const PrefItem.toggle('comment_sort_by_time', '楼中楼评论优先按时间排序', live: true),
      const PrefItem.toggle('scroll_idle_load_photo', '滑动停止后才加载图片',
          note: '适合滑动时加载图片会卡顿的手机'),
      const PrefItem.toggle('direct_repost', '开启微博快转', defaultOn: true),
      const PrefItem.toggle('direct_message_enter', '私信回车发送消息', live: true),
      const PrefItem.toggle('hot_search_tag', '记录热搜查看历史'),
    ]),
  ],
);

/// 6.13.11 微博卡片样式与排版微调 (q.xml)
final prefCard = PrefPage(
  key: 'card',
  title: '微博样式',
  blurb: '字号行距、头像形状、卡片风格与选项按钮',
  groups: [
    PrefGroup(items: [
      const PrefItem.nav('publish_source', '微博尾巴', route: 'publish_source'),
      PrefItem.choice('font_size', '微博字体大小调整',
          defaultChoice: 15, live: true, options: _fontSizes),
      const PrefItem.slider('font_spacing_value', '微博字体行距调整',
          defaultChoice: 50, min: 0, max: 100, live: true),
      const PrefItem.toggle('show_status_card_background', '显示头像框和卡片背景',
          live: true),
      PrefItem.choice('avatar_style', '调整头像样式',
          defaultChoice: 3, live: true, options: _avatarShape),
      const PrefItem.toggle('show_status_card', '微博使用卡片风格',
          defaultOn: true, live: true),
      const PrefItem.toggle('status_icon_show', '微博名字后面显示图标',
          defaultOn: true, live: true),
      const PrefItem.toggle('show_status_options', '微博显示选项按钮',
          defaultOn: true, live: true, note: '微博内容下方显示转发、评论、赞等按钮'),
      const PrefItem.toggle('show_status_collect_btn', '同时显示微博收藏按钮'),
      const PrefItem.toggle('show_status_space', '微博左侧保留空白空间', live: true),
      const PrefItem.toggle('status_name_theme', '微博名字跟随主题颜色', live: true),
      const PrefItem.toggle('status_name_bold', '微博名字加粗',
          defaultOn: true, note: '手机字体不支持加粗时请关闭'),
      const PrefItem.toggle('status_origin_name_show', '同时显示备注和名字'),
      const PrefItem.toggle('show_status_card_divider', '使用卡片风格的分割线',
          live: true),
    ]),
  ],
);

/// 6.13.5 布局样式与导航定制 (k.xml)
final prefLayout = PrefPage(
  key: 'layout',
  title: '布局样式',
  blurb: '侧栏、导航栏、沉浸式状态栏与 FAB',
  groups: [
    PrefGroup(items: [
      const PrefItem.nav('drawer_menu', '侧栏菜单调整', route: 'drawer_menu'),
      const PrefItem.nav('drawer_cover_type', '侧栏封面', route: 'drawer_cover'),
      PrefItem.choice('navigation_position', '导航栏模式',
          defaultChoice: 2, live: true, options: [
        const PrefOption(2, '底栏'),
        const PrefOption(3, '不显示'),
      ]),
      const PrefItem.toggle('navigation_hide_on_scroll', '滑动时隐藏导航栏',
          defaultOn: true, live: true),
      const PrefItem.toggle('toolbar_fix_on_scroll', '滑动时不隐藏标题', live: true),
      const PrefItem.toggle('flat_status_bar', '沉浸式状态栏',
          defaultOn: true, note: '部分手机可能暂不支持关闭'),
      const PrefItem.toggle('navigation_theme_color', '虚拟导航栏跟随主题颜色',
          defaultOn: true, live: true),
      const PrefItem.toggle('show_drawer_from_left', '首页抽屉菜单从左侧展开',
          defaultOn: true, live: true),
      const PrefItem.toggle('show_fab_from_left', 'FAB(右下按钮)左侧显示', live: true),
      const PrefItem.toggle('fast_scroll_indicator', '开启快速拖动',
          defaultOn: true, live: true, note: '浏览首页微博时可用拖动条快速拖动'),
      const PrefItem.toggle('show_video_close_from_left', '悬浮窗视频关闭按钮左侧显示'),
      PrefItem.choice('fab_options', '首页FAB按钮',
          defaultChoice: 4, live: true, options: [
        const PrefOption(1, '不显示'),
        const PrefOption(2, '切换分组'),
        const PrefOption(3, '刷新'),
        const PrefOption(4, '发微博'),
      ]),
      const PrefItem.toggle('hide_hot_tab', '隐藏热门板块', live: true),
      const PrefItem.toggle('hide_hot_search', '隐藏热门搜索', live: true),
      const PrefItem.toggle('hide_often_visit', '隐藏经常访问', live: true),
      const PrefItem.toggle('hide_share_friend_list', '隐藏分享菜单的好友列表'),
    ]),
  ],
);

/// 6.13.9 Share实验室前沿功能 (o.xml)
final prefLab = PrefPage(
  key: 'lab',
  title: 'Share实验室',
  blurb: '大爆炸取词、HTTP-DNS、短链保护与网页暗色注入',
  groups: [
    PrefGroup(items: [
      const PrefItem.toggle('navigation_anim', '虚拟导航栏渐变动画',
          note: '查看大图时虚拟导航栏渐变，部分手机可能卡顿'),
      const PrefItem.toggle('text_boom', '微博文本支持大爆炸',
          defaultOn: true, live: true, note: '长按微博正文取词'),
      const PrefItem.toggle('http_dns', '改善网络请求', note: '加载缓慢时可尝试开启'),
      const PrefItem.toggle('video_dns', '改善视频加载',
          note: '需同时开启改善网络请求'),
      const PrefItem.toggle('status_translation', '开启微博翻译功能',
          live: true, note: '在微博里显示翻译入口'),
      PrefItem.choice('status_translation_default', '默认翻译语言',
          defaultChoice: 2, options: [
        const PrefOption(1, '中文'),
        const PrefOption(2, 'English (英文)'),
        const PrefOption(3, '日本语 (日文)'),
        const PrefOption(4, '한국어 (韩文)'),
      ]),
      const PrefItem.toggle('status_detail_tab_scroll', '开启微博正文页Tab滑动切换',
          live: true, note: '开启后上下滑动内容可能错乱，且不能长截图'),
      const PrefItem.toggle('browser_https', '优化内置浏览器短链的跳转',
          defaultOn: true, live: true, note: '防止短链被劫持，若 t.cn 打不开请关闭'),
      const PrefItem.toggle('webview_night', '强制内置浏览器跟随应用开启夜间模式',
          defaultOn: true, live: true),
      const PrefItem.toggle('big_image_improve', '改善查看大图时的显示质量',
          note: '可能卡顿或闪退'),
      const PrefItem.toggle('new_dm_2_mode', '体验新版私信消息', defaultOn: true),
    ]),
  ],
);

/// 6.13.2 Share高级版与关于 (h.xml), split into the two entry points the
/// original hub exposes.
final prefPro = PrefPage(
  key: 'pro',
  title: 'Share高级版',
  blurb: '更新、评分、历史版本与使用手册',
  groups: [
    PrefGroup(items: [
      const PrefItem.toggle('download_update_auto', 'Wi-Fi下自动下载Share安装包',
          defaultOn: true),
      const PrefItem.nav('rate', '给我评分', route: 'rate'),
      const PrefItem.nav('check_update', '检查更新', route: 'check_update'),
      const PrefItem.nav('history_version', '历史版本', route: 'history_version'),
      const PrefItem.nav('version_code', '版本号', route: 'version_code'),
      const PrefItem.nav('user_guide', '使用手册',
          route: 'https://github.com/aaaddress1/Share'),
    ]),
  ],
);

final prefAbout = PrefPage(
  key: 'about',
  title: '关于',
  blurb: '版本、协议与捐赠',
  groups: [
    PrefGroup(items: [
      const PrefItem.nav('version_code', '版本号', route: 'version_code'),
      const PrefItem.nav('user_guide', '使用手册',
          route: 'https://github.com/aaaddress1/Share'),
      const PrefItem.nav('donate_to_developer', '捐赠开发者', route: 'donate'),
      const PrefItem.nav('user_and_privacy', '用户协议和隐私政策', route: 'terms'),
    ]),
  ],
);

final pages = <PrefPage>[
  prefBasic,
  prefTraffic,
  prefSound,
  prefNotify,
  prefPrivacy,
  prefReading,
  prefCard,
  prefLayout,
  prefLab,
  prefPro,
  prefAbout,
];

/// Flat lookup used when loading persisted values.
final Map<String, PrefItem> prefIndex = {
  for (final page in pages)
    for (final item in page.all)
      if (item.kind != PrefKind.nav) item.key: item,
};
