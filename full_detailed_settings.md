#### 6.13.1 设置主导航大厅 (Settings Root Hub) (g.xml)
> **模块定位**：应用设置的总入口，组织 11 大功能板块的路由分发

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| - | PreferenceScreen | **** |  |  |
| - | CustomPreferenceCategory | **常规设置** |  |  |
| 基本设置 | Preference | **基本设置** |  |  |
| 流量控制 | Preference | **流量控制** |  |  |
| 音效管理 | Preference | **音效管理** |  |  |
| 通知设置 | Preference | **通知设置** |  |  |
| 隐私设置 | Preference | **隐私设置** |  |  |
| - | CustomPreferenceCategory | **显示设置** |  |  |
| 阅读习惯 | Preference | **阅读习惯** |  |  |
| 微博样式 | Preference | **微博样式** |  |  |
| 布局样式 | Preference | **布局样式** |  |  |
| other_category | CustomPreferenceCategory | **其他** |  |  |
| Share_Advanced | Preference | **Share高级版** |  |  |
| Share_Lab | Preference | **Share实验室** |  |  |
| 关于 | Preference | **关于** |  |  |
| 分享 | Preference | **分享** |  |  |

#### 6.13.2 Share高级版与关于 (Pro Features & About) (h.xml)
> **模块定位**：应用版本、高级功能、历史发布、使用手册与捐赠通道

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| - | PreferenceScreen | **** |  |  |
| download_update_auto | CustomSwitchPreference | **Wi-Fi下自动下载Share安装包** | true |  |
| rate | Preference | **给我评分** |  |  |
| check_update | Preference | **检查更新** |  |  |
| history_version | Preference | **历史版本** |  |  |
| version_code | Preference | **版本号** |  |  |
| user_guide | Preference | **使用手册** |  |  |
| donate_to_developer | Preference | **捐赠开发者** |  |  |
| user_and_privacy | Preference | **用户协议和隐私政策** |  |  |

#### 6.13.3 基本与常规交互设置 (Basic Settings) (i.xml)
> **模块定位**：后退手势、语言切换、屏幕旋转、相册保存策略及内置浏览器行为

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| - | PreferenceScreen | **** |  |  |
| - | CustomPreferenceCategory | **常规设置** |  |  |
| home_back | CustomSwitchPreference | **首页按返回键退出** | false | 退出应用，不在后台运行 |
| swipe_back | CustomListPreference | **二级页面滑动后退** | 3 | %s<br>↳ **选项枚举**：[1: 向右滑动退出 / 2: 向左滑动退出 / 3: 向左或右滑动退出 / 4: 禁用] |
| language | CustomListPreference | **语言** | 1 | %s<br>↳ **选项枚举**：[1: 跟随系统 / 2: 简体中文 / 3: 繁体中文 / 4: English] |
| orientation_new | CustomListPreference | **屏幕方向** | 1 | %s<br>↳ **选项枚举**：[1: 竖屏 / 2: 横屏] |
| ic_launcher | Preference | **应用图标** |  |  |
| same_photo_name | CustomCheckBoxPreference | **防止重复保存图片** | false | 默认多次保存会出现多张重复图片，图片文件名会以当前时间命名 |
| save_photo_path | Preference | **图片保存路径** |  |  |
| save_video_path | Preference | **视频保存路径** |  |  |
| click_photo_back | CustomCheckBoxPreference | **点击图片返回** | true |  |
| drag_photo_back | CustomCheckBoxPreference | **拖拽图片返回** | true |  |
| clear_photo_cache | Preference | **清除图片缓存** |  |  |
| internal_app_browser | CustomCheckBoxPreference | **使用内置浏览器** | true |  |
| custom_tabs_ui | CustomSwitchPreference | **使用CustomTabs** | true | 当使用外部浏览器打开链接时，顶部标题背景颜色使用应用的主题色，需浏览器支持(Chrome) |

#### 6.13.4 流量控制与多媒体画质 (Network & Traffic) (j.xml)
> **模块定位**：预读流控、单批次拉取条数、动图/视频自动播放及图片质量自适应

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| - | PreferenceScreen | **** |  |  |
| - | CustomPreferenceCategory | **常规设置** |  |  |
| preread | CustomSwitchPreference | **预读模式** | true | 当内容快浏览到尽头时提前加载避免等待 |
| load_status_count | CustomListPreference | **首页加载微博时的条数** | 1 | %s<br>↳ **选项枚举**：[1: 自动 / 2: 30条 / 3: 50条 / 4: 88条 / 5: 100条] |
| auto_play_options | CustomListPreference | **自动播放视频和动图** | 3 | %s<br>↳ **选项枚举**：[1: 仅Wi-Fi / 2: 总是 / 3: 从不] |
| video_play_quality | CustomListPreference | **视频播放优先质量** | 3 | %s<br>↳ **选项枚举**：[1: 超清 / 2: 高清 / 3: 标清 / 4: 流畅 / 5: 自动] |
| - | CustomPreferenceCategory | **图片** |  |  |
| save_image_original | CustomSwitchPreference | **保存图片时默认保存原图** | false |  |
| show_avatar | CustomMultiSelectListPreference | **不显示头像** | @array/l | 关闭可以节省流量<br>↳ **选项枚举**：[1: 微博头像 / 2: 评论、转发、赞头像 / 3: Wi-Fi下不隐藏头像] |
| download_image_quality | CustomListPreference | **微博图片加载质量** | 5 | %s<br>↳ **选项枚举**：[1: 无图 / 2: 缩略图 / 3: 高清图 / 4: 原图 / 5: 自动 / 6: 仅Wi-Fi下加载] |
| show_comment_photo_options | CustomListPreference | **显示评论图片** | 1 | %s<br>↳ **选项枚举**：[1: 跟随微博图片 / 2: 仅Wi-Fi下加载 / 3: 从不] |
| photo_upload_quality | CustomListPreference | **图片上传的默认质量** | 2 | %s<br>↳ **选项枚举**：[1: 压缩处理 / 2: 原图 / 3: 自动] |

#### 6.13.5 布局样式与导航定制 (Layout & Navigation) (k.xml)
> **模块定位**：抽屉菜单定制、底栏/顶栏模式、沉浸式状态栏、悬浮按钮 FAB 配置及板块隐藏

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| - | PreferenceScreen | **** |  |  |
| drawer_menu | Preference | **侧栏菜单调整** |  |  |
| drawer_cover_type | Preference | **侧栏封面** |  |  |
| navigation_position | CustomListPreference | **导航栏模式** | 2 | %s<br>↳ **选项枚举**：[2: 底栏 / 3: 不显示] |
| navigation_hide_on_scroll | CustomSwitchPreference | **滑动时隐藏导航栏** | true |  |
| toolbar_fix_on_scroll | CustomSwitchPreference | **滑动时不隐藏标题** | false |  |
| flat_status_bar | CustomSwitchPreference | **沉浸式状态栏** | true | 部分手机可能暂不支持关闭沉浸式状态栏 |
| navigation_theme_color | CustomSwitchPreference | **虚拟导航栏跟随主题颜色** | true |  |
| show_drawer_from_left | CustomSwitchPreference | **首页抽屉菜单从左侧展开** | true |  |
| show_fab_from_left | CustomSwitchPreference | **FAB(右下按钮)左侧显示** | false |  |
| fast_scroll_indicator | CustomSwitchPreference | **开启快速拖动** | true | 浏览首页微博时可用拖动条快速拖动 |
| show_video_close_from_left | CustomSwitchPreference | **悬浮窗视频关闭按钮左侧显示** | false |  |
| fab_options | CustomListPreference | **首页FAB按钮** | 4 | %s<br>↳ **选项枚举**：[1: 不显示 / 2: 切换分组 / 3: 刷新 / 4: 发微博] |
| hide_hot_tab | CustomSwitchPreference | **隐藏热门板块** | false |  |
| hide_hot_search | CustomSwitchPreference | **隐藏热门搜索** | false |  |
| hide_often_visit | CustomSwitchPreference | **隐藏经常访问** | false |  |
| hide_share_friend_list | CustomSwitchPreference | **隐藏分享菜单的好友列表** | false |  |

#### 6.13.6 通知推送与后台保活 (Notifications & Push) (l.xml)
> **模块定位**：WeSync二进制长连接、前台常驻服务保活、特别关注推送、未读红点分类

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| root_group | PreferenceScreen | **** |  |  |
| - | Preference | **** |  | 不支持实时通知、后台推送也无法实现，消息通知需要保持应用开启和允许后台运行，如果收不到通知请检查是否手机限制了应用的后台活动 |
| notify_open | CustomSwitchPreference | **开启通知提醒** | true |  |
| notify_oreo | Preference | **调整通知的振动和铃声** |  |  |
| app_persistent | CustomSwitchPreference | **开启应用常驻后台** | false | 开启后会在通知栏里有个无法移除的通知，如果通知收不到请尝试开启该选项 |
| remind_dm_subscribe_ignore | CustomCheckBoxPreference | **消息页屏蔽订阅类私信** | false |  |
| remind_dm_subscribe_manage | Preference | **订阅类私信管理** |  |  |
| remind_group | CustomPreferenceCategory | **提醒设置** |  |  |
| special_follow_remind | CustomCheckBoxPreference | **特别关注微博提醒** | false |  |
| remind_notify_type | CustomMultiSelectListPreference | **通知提醒类型** | @array/aa | **选项枚举**：[1: 评论 / 2: @我 / 3: 私信 / 4: 新粉丝 / 5: 点赞] |
| remind_unread_type | CustomMultiSelectListPreference | **数字红点提醒类型** | @array/ad | **选项枚举**：[1: 评论 / 2: @我 / 3: 点赞] |
| remind_by_vibration | CustomCheckBoxPreference | **振动提醒** | true |  |
| remind_by_lights | CustomCheckBoxPreference | **呼吸灯提醒** | true | 需手机支持 |

#### 6.13.7 隐私控制与黑名单过滤 (Privacy & Blacklist) (m.xml)
> **模块定位**：用户拉黑、关键词折叠/隐藏、小尾巴设备屏蔽、常访博主隐私

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| - | PreferenceScreen | **** |  |  |
| privacy_common | Preference | **通用设置** |  |  |
| blacklist | Preference | **黑名单** |  |  |
| black_content | Preference | **关键词屏蔽** |  |  |
| block_status | Preference | **微博消息提醒屏蔽** |  |  |
| repost_direct | Preference | **微博快转** |  |  |
| recently_visit | Preference | **经常访问** |  |  |

#### 6.13.8 阅读习惯与视频引擎 (Reading Habits & Video) (n.xml)
> **模块定位**：夜间模式策略、暗光图片遮罩、逆序排版、长按点赞防误触、小窗悬浮画中画

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| - | PreferenceScreen | **** |  |  |
| night_theme | CustomListPreference | **默认夜间主题** | 3 | %s<br>↳ **选项枚举**：[1: 夜间黑 / 2: A屏黑 / 3: 夜间蓝] |
| auto_night_mode_follow_system | CustomSwitchPreference | **夜间模式跟随系统** | false |  |
| auto_night_mode | CustomSwitchPreference | **自动切换夜间模式** | true |  |
| auto_night_mode_duration | Preference | **自定义夜间模式时间** |  |  |
| night_shade_mode | CustomSwitchPreference | **图片适配夜间模式** | false | 夜间模式时部分图片缩略图会变暗，减少亮度保护您的眼睛 |
| read_verse_order | CustomSwitchPreference | **逆序浏览** | false | 不能保证微博一定可以连续逆序浏览 |
| like_status_long_click | CustomSwitchPreference | **点赞通过长按触发** | false | 避免单击误触点赞 |
| show_like_status_error | CustomSwitchPreference | **开启点赞失败提示** | false | 因不可抗拒因素，微博点赞可能会失败，默认会忽略错误显示点赞成功 |
| show_recommend_status | CustomSwitchPreference | **显示最近赞过的微博** | true | 微博时间线显示好友最近赞过和打赏过的微博 |
| video_play_list | CustomSwitchPreference | **视频播放开启专辑模式** | true |  |
| auto_fullscreen_video | CustomSwitchPreference | **视频播放默认全屏** | false |  |
| floating_video | CustomSwitchPreference | **默认使用悬浮窗加载视频** | false | 需要悬浮窗权限，边看视频边刷微博 |
| floating_video_move | CustomSwitchPreference | **悬浮窗直接移动** | false | 默认需要长按才能触发移动 |
| video_controller_hide | CustomSwitchPreference | **禁止视频手势控制** | false |  |
| auto_close_video | CustomSwitchPreference | **视频播放完毕后自动关闭** | false |  |
| start_refresh_status | CustomSwitchPreference | **打开应用后自动刷新微博** | false | 开启后，下次启动不再保留旧的微博浏览记录 |
| auto_refresh_status | CustomSwitchPreference | **切换分组自动刷新微博** | false |  |
| reselect_tab_refresh | CustomSwitchPreference | **当重复点击首页的tab时刷新** | true | 默认是从顶部和上次浏览位置切换 |
| hot_status_comment_preview | CustomSwitchPreference | **预览热门微博评论** | true |  |
| comment_floor | CustomSwitchPreference | **微博评论楼中楼显示** | true |  |
| comment_sort_by_time | CustomSwitchPreference | **楼中楼评论优先按时间排序** | false | 默认按热度排序，数量较少时按时间排序 |
| scroll_idle_load_photo | CustomSwitchPreference | **滑动停止后才加载图片** | false | 适合滑动时加载图片会卡顿的手机 |
| direct_repost | CustomSwitchPreference | **开启微博快转** | true |  |
| direct_message_enter | CustomSwitchPreference | **私信回车发送消息** | false |  |
| hot_search_tag | CustomSwitchPreference | **记录热搜查看历史** | false |  |

#### 6.13.9 Share实验室前沿功能 (Lab Features) (o.xml)
> **模块定位**：大爆炸分词取词、HTTP-DNS 防污染、短链 HTTPS 劫持规避、夜间网页暗色注入

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| - | PreferenceScreen | **** |  |  |
| navigation_anim | CustomCheckBoxPreference | **虚拟导航栏渐变动画** | false | 如果设备有虚拟导航栏，开启了该选项，当查看大图时虚拟导航栏会有渐变效果，部分手机开启后会引起卡顿时请关闭 |
| text_boom | CustomCheckBoxPreference | **微博文本支持大爆炸** | true | 如果出现微博正文换行异常，或者你的设备支持类似锤子的大爆炸功能，希望在微博正文支持该特性时请开启该选项，可能会带来一点性能损失 |
| http_dns | CustomCheckBoxPreference | **改善网络请求** | false | 如果发现加载缓慢，请尝试开启该选项 |
| video_dns | CustomCheckBoxPreference | **改善视频加载** | false | 如果发现视频加载缓慢，请尝试开启该选项，需要同时开启改善网络请求 |
| status_translation | CustomCheckBoxPreference | **开启微博翻译功能** | false | 在微博里显示翻译入口，长按查看翻译可切换语言 |
| status_translation_default | CustomListPreference | **默认翻译语言** | 2 | %s<br>↳ **选项枚举**：[1: 中文 / 2: English (英文) / 3: 日本语 (日文) / 4: 한국어 (韩文)] |
| status_detail_tab_scroll | CustomCheckBoxPreference | **开启微博正文页Tab滑动切换** | false | 开启该选项后正文页上下滑动时内容可能会错乱，并且导致你的设备可能不能长截图 |
| browser_https | CustomCheckBoxPreference | **优化内置浏览器短链的跳转** | true | 开启该选项后可以防止短链被劫持跳转广告，但可能会导致短链(https://t.cn)打不开，如果打不开请关闭该选项。 |
| webview_night | CustomCheckBoxPreference | **强制内置浏览器跟随应用开启夜间模式** | true | 如果夜间模式下浏览网页异常请关闭该选项 |
| big_image_improve | CustomCheckBoxPreference | **改善查看大图时的显示质量** | false | 如果在查看大图时觉得图片显示有质量问题请开启该选项，但是可能会导致卡顿或者闪退 |
| new_dm_2_mode | CustomCheckBoxPreference | **体验新版私信消息** | true |  |

#### 6.13.10 声音音效与震动触觉 (Sound & Haptics) (p.xml)
> **模块定位**：全局静音、操作音效选择、触觉震动马达反馈波形

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| - | PreferenceScreen | **** |  |  |
| ringtone_group | CustomPreferenceCategory | **铃声设置** |  |  |
| sound_off | CustomSwitchPreference | **静音模式** | false | 关闭一切提醒音效 |
| ringtone_type | CustomMultiSelectListPreference | **音效类型** | @array/an | **选项枚举**：[1: 首页有新的微博 / 2: 未读通知 / 3: 视频下载成功] |
| ringtone_notify_oreo | Preference | **调整通知的振动和铃声** |  |  |
| vibration_group | CustomPreferenceCategory | **振动设置** |  |  |
| vibration_on | CustomSwitchPreference | **开启振动** | true |  |
| vibration_feedback | CustomCheckBoxPreference | **振动反馈** | true | 内容发送成功后振动反馈 |

#### 6.13.11 微博卡片样式与排版微调 (Card Typography) (q.xml)
> **模块定位**：小尾巴选择、13-23pt字号自由缩放、行间距微调、九宫格卡片几何与加粗

| 配置项 Key | 控件类型 | 界面标题 (Title) | 默认值 | 详细选项 / 业务行为规范 |
| :--- | :---: | :--- | :---: | :--- |
| - | PreferenceScreen | **** |  |  |
| publish_source | Preference | **微博尾巴** |  |  |
| font_size | CustomListPreference | **微博字体大小调整** | 16 | %s<br>↳ **选项枚举**：[13: 13 pt / 14: 14 pt / 15: 15 pt / 16: 16 pt / 17: 17 pt / 18: 18 pt / 19: 19 pt / 20: 20 pt / 21: 21 pt / 23: 23 pt] |
| font_spacing_value | SeekBarPreference | **微博字体行距调整** | 50 |  |
| show_status_card_background | CustomCheckBoxPreference | **显示头像框和卡片背景** | false |  |
| avatar_style | CustomListPreference | **调整头像样式** | 3 | %s<br>↳ **选项枚举**：[1: 正方形 / 2: 正方圆角 / 3: 圆形] |
| show_status_card | CustomCheckBoxPreference | **微博使用卡片风格** | true |  |
| status_icon_show | CustomCheckBoxPreference | **微博名字后面显示图标** | true |  |
| show_status_options | CustomCheckBoxPreference | **微博显示选项按钮** | true | 微博内容下方显示转发、评论、赞等按钮 |
| show_status_collect_btn | CustomCheckBoxPreference | **同时显示微博收藏按钮** | false |  |
| show_status_space | CustomCheckBoxPreference | **微博左侧保留空白空间** | false |  |
| status_name_theme | CustomCheckBoxPreference | **微博名字跟随主题颜色** | false |  |
| status_name_bold | CustomCheckBoxPreference | **微博名字加粗** | true | 如果手机字体不支持加粗时请关闭该选项 |
| status_origin_name_show | CustomCheckBoxPreference | **同时显示备注和名字** | false |  |
| show_status_card_divider | CustomCheckBoxPreference | **使用卡片风格的分割线** | false |  |
