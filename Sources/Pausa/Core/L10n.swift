import Foundation

/// App language. `.system` follows macOS preferred languages.
/// Strings are keyed by their Simplified Chinese source text; no resource bundles.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHans = "zh-Hans", zhHant = "zh-Hant", en, es, ru, fr, vi, th
    var id: String { rawValue }

    /// Shown in the picker in its own language (system row is translated).
    var nativeName: String {
        switch self {
        case .system: return L("跟随系统")
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .es: return "Español"
        case .ru: return "Русский"
        case .fr: return "Français"
        case .vi: return "Tiếng Việt"
        case .th: return "ภาษาไทย"
        }
    }

    /// Debug-only override (e.g. `--render-settings out.png --lang ru`); never persisted.
    static var override: AppLanguage?

    /// The concrete language in effect right now (never `.system`).
    static var current: AppLanguage {
        let chosen = override ?? Settings.shared.language
        return chosen == .system ? fromSystem(Locale.preferredLanguages) : chosen
    }

    static func fromSystem(_ preferred: [String]) -> AppLanguage {
        for id in preferred {
            let p = id.lowercased()
            if p.hasPrefix("zh") {
                let trad = ["zh-hant", "zh-tw", "zh-hk", "zh-mo"].contains { p.hasPrefix($0) }
                return trad ? .zhHant : .zhHans
            }
            for l in [AppLanguage.en, .es, .ru, .fr, .vi, .th] where p.hasPrefix(l.rawValue) { return l }
        }
        return .en
    }

    /// For SwiftUI `.environment(\.locale, AppLanguage.current.locale)`: picks PingFang TC glyphs for zh-Hant etc.
    var locale: Locale { Locale(identifier: self == .system ? AppLanguage.current.rawValue : rawValue) }
}

/// Translate a Simplified Chinese source string. Missing key -> the source itself.
func L(_ key: String, _ args: CVarArg...) -> String {
    let lang = AppLanguage.current
    let fmt = L10nTables.all[lang]?[key] ?? L10nTables.zhHans[key] ?? key
    return args.isEmpty ? fmt : String(format: fmt, locale: lang.locale, arguments: args)
}

/// CLDR cardinal plural categories for the 8 app languages (what a stringsdict would pick).
/// Keys: "key.one" / ".few" / ".many" / ".other"; missing categories fall back to ".other".
enum Plural {
    static func category(_ n: Int, _ lang: AppLanguage) -> String {
        switch lang {
        case .en, .es: return n == 1 ? "one" : "other"
        case .fr: return n == 0 || n == 1 ? "one" : "other"
        case .ru:
            let m10 = n % 10, m100 = n % 100
            if m10 == 1 && m100 != 11 { return "one" }
            if (2...4).contains(m10) && !(12...14).contains(m100) { return "few" }
            return "many"
        default: return "other"   // zh-Hans, zh-Hant, vi, th: no plural forms
        }
    }
    static func pick(_ key: String, _ n: Int) -> String {
        let lang = AppLanguage.current
        let table = L10nTables.all[lang] ?? [:]
        return table["\(key).\(category(n, lang))"] ?? table["\(key).other"]
            ?? L10nTables.zhHans["\(key).other"] ?? key
    }
}

/// Health footnote (wording pending medical review). Change the source here; translations key off it.
enum HealthNote {
    static let key = "若眼部持续不适，请及时就医。Pausa 不能替代专业的治疗。"
}

enum L10nTables {
    static let all: [AppLanguage: [String: String]] = [.zhHans: zhHans, .zhHant: zhHant, .en: en, .es: es, .ru: ru, .fr: fr, .vi: vi, .th: th]

    /// Source strings for keyed (dotted) entries; Chinese-keyed entries need no zh-Hans row.
    static let zhHans: [String: String] = [
        "菜单栏显示": "菜单栏显示", "剩余时间": "剩余时间", "进度圆环": "进度圆环",
        "rhythm.line1": "每{1}休息一次，", "rhythm.line2.other": "短休息{1}次后进行一次长休息。",
        "这一天": "这一天",
        "免打扰时段": "免打扰时段", "上班": "上班", "日期休息": "休息", "添加日期": "添加日期", "删除日期": "删除日期", "这些日期按设置上班或休息，不按星期几。": "这些日期按设置上班或休息，不按星期几。", "视频播放器和网页里的视频": "视频播放器和网页里的视频",
        "appearance.system": "跟随系统",
        // Round 3
        "%@ 后开始短休息，%@": "%@ 后开始短休息，%@", "%@ 后开始长休息，%@": "%@ 后开始长休息，%@", "休息延后 %d 分钟": "休息延后 %d 分钟", "break.short.ending": "即将结束", "break.holdToSkip": "长按 %@ 跳过", "key.space": "空格", "break.short.hint": "看看远处",
        "短休息时长": "短休息时长", "长休息时长": "长休息时长", "在程序坞显示": "在程序坞显示", "暂停范围": "暂停范围", "仅短休息": "仅短休息", "所有休息": "所有休息",
        "预览休息界面": "预览休息界面", "生效条件": "生效条件", "添加应用": "添加应用", 
        "编辑": "编辑",
        "删除时段": "删除时段",
        "添加": "添加",
        "设置": "设置",
        "暂停提醒 1 小时": "暂停提醒 1 小时", "恢复提醒": "恢复提醒", "添加提醒时段": "添加提醒时段", "添加免打扰时段": "添加免打扰时段", "这些时段内不提醒休息，即使落在提醒时段内。": "这些时段内不提醒休息，即使落在提醒时段内。",
    ]

    static let zhHant: [String: String] = [
        // pre-break card + cursor pill (SPEC-prebreak-v0.2 §2–3)
        "马上休息一下": "馬上休息一下", "长休息快到了": "長休息快到了", "休息 %d 秒": "休息 %d 秒", "休息 %d 分钟": "休息 %d 分鐘", "跳过这次": "跳過這次", "推迟 %d 分钟": "延後 %d 分鐘", "还能推迟 %d 分钟": "還能延後 %d 分鐘", "推迟额度用完了": "延後額度用完了", "已连续工作 %d 分钟": "已連續工作 %d 分鐘", "刚休息过": "剛休息過", "%d 秒后休息": "%d 秒後休息", "写完这句再休息": "寫完這句再休息", "收起": "收起",
        "随机": "隨機",
        // Update UI (About row, popover line)
        "检查更新": "檢查更新", "正在检查…": "正在檢查…", "已是最新版本": "已是最新版本", "正在下载 %@": "正在下載 %@", "%@ 已就绪，重启后生效": "%@ 已就緒，重新啟動後生效", "暂时无法检查更新": "暫時無法檢查更新", "有新版本 %@": "有新版本 %@", "休息结束后安装": "休息結束後安裝", "立即重启": "立即重新啟動", "自动检查更新": "自動檢查更新",
        "图标": "圖示", "水墨": "水墨", "玻璃": "玻璃",
        "暂停提醒": "暫停提醒",
        "在以下情况下，暂时不提醒休息。": "在以下情況下，暫時不提醒休息。",
        "图标的灵感来自泰国寺庙里的莲花。": "圖示的靈感來自泰國寺廟裡的蓮花。",
        "菜单栏显示": "選單列顯示", "剩余时间": "剩餘時間", "进度圆环": "進度圓環",
        "rhythm.line1": "每{1}休息一次，", "rhythm.line2.other": "短休息{1}次後進行一次長休息。",
        "这一天": "這一天",
        "免打扰时段": "勿擾時段", "上班": "上班", "日期休息": "休息", "添加日期": "加入日期", "删除日期": "刪除日期", "这些日期按设置上班或休息，不按星期几。": "這些日期按設定上班或休息，不按星期幾。", "视频播放器和网页里的视频": "影片播放器和網頁裡的影片",
        "已暂停：%@ 正在播放视频": "已暫停：%@ 正在播放影片",
        "已暂停：正在共享屏幕（%@）": "已暫停：正在分享螢幕（%@）",
        "已暂停：正在共享屏幕": "已暫停：正在分享螢幕",
        "已暂停：正在录屏（%@）": "已暫停：正在錄影（%@）",
        "已暂停：正在录屏": "已暫停：正在錄影",
        "已推迟：%@ 在前台": "已延後：%@ 在前景",
        "等你打完这句…": "等你打完這句…",
        "短休息已暂停": "短休息已暫停",
        "休息已推迟": "休息已延後",
        "专注模式「%@」：%@": "專注模式「%@」：%@",
        "专注模式：%@": "專注模式：%@",
        "视频结束 2 分钟后继续": "影片結束 2 分鐘後繼續",
        "结束后补一次长休息": "結束後補一次長休息",
        "还可推迟 %lld 分钟": "還可延後 %lld 分鐘",
        "最多再等 %@": "最多再等 %@",
        "版本 %@": "版本 %@",
        "全天": "全天",
        "时段": "時段",
        "时段外": "時段外",
        "下次开始 %@": "下次開始 %@",
        "明天 %@": "明天 %@",
        "开始": "開始",
        "结束": "結束",
        "重复": "重複",
        "删除": "刪除",
        "取消": "取消",
        "完成": "完成",
        "添加日期…": "加入日期…",
        "全天不提醒": "全天不提醒",
        "自定义时段": "自訂時段",
        "日期": "日期",
        "当天": "當天",
        "从不": "永不",
        "每天": "每天",
        "周末": "週末",
        "结束早于开始：时段跨过午夜。": "結束早於開始：時段跨過午夜。",
        "登录时打开": "登入時打開", 
        "由 Bowen（debidong）开发": "由 Bowen（debidong）開發",
        "名字来自西班牙语中的“暂停”。": "名字來自西班牙語中的「暫停」。",
        
        "配色模式": "配色模式", "appearance.system": "跟隨系統", "浅色": "淺色", "深色": "深色",
        "森林": "森林", "大海": "大海", "晚霞": "晚霞", "夜空": "夜空", "跟随系统": "跟隨系統",
        "已暂停，%@ 后恢复": "已暫停，%@ 後恢復",
        "你离开了电脑": "你離開了電腦",
        "长休息中": "長休息中", "短休息中": "短休息中",
        "长休息：%@ 后": "長休息：%@ 後", "短休息：%@ 后": "短休息：%@ 後",
        "立即短休息": "立即短休息", "立即长休息": "立即長休息",
        
        "退出 Pausa": "結束 Pausa",
        // menu popover
        "短休息": "短休息", "%d 秒": "%d 秒", "%d 分钟": "%d 分鐘",
        "现在休息": "現在休息", "已连续使用 90 分钟，长休息不能再推迟。": "已連續使用 90 分鐘，長休息不能再延後。",
        "Pausa 已在运行，下次休息在 %@ 后。": "Pausa 已在執行，下次休息在 %@ 後。",
        "分钟": "分鐘", "秒": "秒", 
        "主题": "主題", "预览": "預覽", "语言": "語言",
        HealthNote.key: "若眼部持續不適，請及時就醫。Pausa 不能取代專業的治療。",
        // Settings › 休息
        "休息节奏": "休息節奏", "每次": "每次", "提醒时段": "提醒時段", "仅在指定时段提醒": "僅在指定時段提醒", "会议进行时": "會議進行時", "麦克风或摄像头正在使用": "麥克風或攝影機正在使用", "共享或录制屏幕时": "分享或錄製螢幕時", "专注模式开启时": "專注模式開啟時", "尚未在系统设置中添加 Pausa 专注过滤器": "尚未在系統設定中加入 Pausa 專注過濾器", "打开系统设置…": "打開系統設定…", "输入或拖移时延迟": "輸入或拖移時延遲", "最长 2 分钟": "最長 2 分鐘", "使用指定应用时": "使用指定 App 時", "移除": "移除", "位于前台且全屏": "位於前景且全螢幕", "位于前台": "位於前景", "运行时": "執行時", "锁屏、睡眠，或全屏播放视频、玩游戏时，Pausa 会自动暂停。\n短休息最多推迟 10 分钟，长休息最多推迟 30 分钟。\n连续使用 90 分钟后，长休息不能再推迟。": "鎖定螢幕、睡眠，或全螢幕播放影片、玩遊戲時，Pausa 會自動暫停。\n短休息最多延後 10 分鐘，長休息最多延後 30 分鐘。\n連續使用 90 分鐘後，長休息不能再延後。", "低频提醒": "低頻提醒", "预设": "預設", "标准": "標準", "护眼优先": "護眼優先", "自定义": "自訂", "长休息": "長休息", "特定日期": "特定日期", "工作日": "工作日", "播放视频时": "播放影片時", "休息": "休息", "通用": "一般", "外观": "外觀", "关于": "關於",
        "已暂停：正在开会": "已暫停：正在開會", "已暂停：%@ 全屏中": "已暫停：%@ 全螢幕中",
        // Round 3
        "%@ 后开始短休息，%@": "%@ 後開始短休息，%@", "%@ 后开始长休息，%@": "%@ 後開始長休息，%@", "休息延后 %d 分钟": "休息延後 %d 分鐘", "break.short.ending": "即將結束", "break.holdToSkip": "長按 %@ 略過", "key.space": "空白鍵", "break.short.hint": "看看遠處",
        "短休息时长": "短休息時長", "长休息时长": "長休息時長", "在程序坞显示": "在 Dock 顯示", "暂停范围": "暫停範圍", "仅短休息": "僅短休息", "所有休息": "所有休息",
        "预览休息界面": "預覽休息畫面", "生效条件": "生效條件", "添加应用": "加入 App", 
        "编辑": "編輯",
        "删除时段": "刪除時段",
        "添加": "加入",
        "设置": "設定",
        "暂停提醒 1 小时": "暫停提醒 1 小時", "恢复提醒": "恢復提醒", "添加提醒时段": "加入提醒時段", "添加免打扰时段": "加入勿擾時段", "这些时段内不提醒休息，即使落在提醒时段内。": "這些時段內不提醒休息，即使落在提醒時段內。",
    ]

    static let en: [String: String] = [
        // pre-break card + cursor pill (SPEC-prebreak-v0.2 §2–3)
        "马上休息一下": "Short break coming up", "长休息快到了": "Long break coming up", "休息 %d 秒": "%d-second break", "休息 %d 分钟": "%d-minute break", "跳过这次": "Skip this one", "推迟 %d 分钟": "%d min later", "还能推迟 %d 分钟": "%d min of postponing left", "推迟额度用完了": "No postponing left", "已连续工作 %d 分钟": "Working for %d min", "刚休息过": "Just had a break", "%d 秒后休息": "Break in %d s", "写完这句再休息": "Finish your sentence", "收起": "Hide",
        "随机": "Random",
        // Update UI (About row, popover line)
        "检查更新": "Check for updates", "正在检查…": "Checking…", "已是最新版本": "Pausa is up to date", "正在下载 %@": "Downloading %@", "%@ 已就绪，重启后生效": "%@ is ready and takes effect after a restart", "暂时无法检查更新": "Can't check for updates right now", "有新版本 %@": "New version %@", "休息结束后安装": "Installs after the break", "立即重启": "Restart now", "自动检查更新": "Checks for updates automatically",
        "图标": "Icon", "水墨": "Ink", "玻璃": "Glass",
        "暂停提醒": "Pause reminders",
        "在以下情况下，暂时不提醒休息。": "Pausa won't remind you to take a break in these situations.",
        "图标的灵感来自泰国寺庙里的莲花。": "The icon was inspired by the lotus flowers in Thai temples.",
        "菜单栏显示": "Menu bar shows", "剩余时间": "Time left", "进度圆环": "Progress ring",
        "rhythm.line1": "Take a break every{1},", "rhythm.line2.one": "and a long break after{1}short break.", "rhythm.line2.other": "and a long break after{1}short breaks.",
        "这一天": "This day is",
        "免打扰时段": "Quiet hours", "上班": "Workday", "日期休息": "Day off", "添加日期": "Add date", "删除日期": "Delete date", "这些日期按设置上班或休息，不按星期几。": "These dates follow your setting instead of the day of the week.", "视频播放器和网页里的视频": "Video players and videos in web pages",
        "已暂停：%@ 正在播放视频": "Paused: %@ is playing video",
        "已暂停：正在共享屏幕（%@）": "Paused: sharing screen (%@)",
        "已暂停：正在共享屏幕": "Paused: sharing screen",
        "已暂停：正在录屏（%@）": "Paused: recording screen (%@)",
        "已暂停：正在录屏": "Paused: recording screen",
        "已推迟：%@ 在前台": "Postponed: %@ is frontmost",
        "等你打完这句…": "Waiting for you to finish typing…",
        "短休息已暂停": "short breaks paused",
        "休息已推迟": "breaks postponed",
        "专注模式「%@」：%@": "Focus “%@”: %@",
        "专注模式：%@": "Focus: %@",
        "视频结束 2 分钟后继续": "Resumes 2 minutes after the video ends",
        "结束后补一次长休息": "A long break follows when it ends",
        "还可推迟 %lld 分钟": "Can postpone %lld more min",
        "最多再等 %@": "Waiting up to %@",
        "版本 %@": "Version %@",
        "全天": "All Day",
        "时段": "Active Hours",
        "时段外": "Outside Pausa Time",
        "下次开始 %@": "Starts at %@",
        "明天 %@": "Tomorrow %@",
        "开始": "Start",
        "结束": "End",
        "重复": "Repeat",
        "删除": "Delete",
        "取消": "Cancel",
        "完成": "Done",
        "添加日期…": "Add Date…",
        "全天不提醒": "No reminders all day",
        "自定义时段": "Custom hours",
        "日期": "Date",
        "当天": "On this day",
        "从不": "Never",
        "每天": "Every Day",
        "周末": "Weekends",
        "结束早于开始：时段跨过午夜。": "End is before start: the hours cross midnight.",
        "登录时打开": "Open at Login", 
        "由 Bowen（debidong）开发": "Developed by Bowen (debidong)",
        "名字来自西班牙语中的“暂停”。": "The name comes from the Spanish word for “pause.”",
        
        "配色模式": "Mode", "appearance.system": "Auto", "浅色": "Light", "深色": "Dark",
        "森林": "Forest", "大海": "Ocean", "晚霞": "Sunset", "夜空": "Night Sky", "跟随系统": "Match System",
        "已暂停，%@ 后恢复": "Paused, resumes in %@",
        "你离开了电脑": "You're away from your computer",
        "长休息中": "On a long break", "短休息中": "On a short break",
        "长休息：%@ 后": "Long break in %@", "短休息：%@ 后": "Short break in %@",
        "立即短休息": "Short Break Now", "立即长休息": "Long Break Now",
        
        "退出 Pausa": "Quit Pausa",
        // menu popover
        "短休息": "Short break", "%d 秒": "%d sec", "%d 分钟": "%d min",
        "现在休息": "Break now", "已连续使用 90 分钟，长休息不能再推迟。": "You've been at it for 90 minutes. This long break can't wait.",
        "Pausa 已在运行，下次休息在 %@ 后。": "Pausa is running. Next break in %@.",
        "分钟": "min", "秒": "s", 
        "主题": "Theme", "预览": "Preview", "语言": "Language",
        HealthNote.key: "If eye discomfort persists, please see a doctor promptly. Pausa is not a substitute for professional treatment.",
        // Settings › 休息
        "休息节奏": "Break schedule", "每次": "for", "提醒时段": "Active hours", "仅在指定时段提醒": "Remind only during active hours", "会议进行时": "During meetings", "麦克风或摄像头正在使用": "Microphone or camera is in use", "共享或录制屏幕时": "While sharing or recording the screen", "专注模式开启时": "While a Focus is on", "尚未在系统设置中添加 Pausa 专注过滤器": "The Pausa Focus filter isn't added in System Settings", "打开系统设置…": "Open System Settings…", "输入或拖移时延迟": "Wait while typing or dragging", "最长 2 分钟": "Up to 2 minutes", "使用指定应用时": "While using specific apps", "移除": "Remove", "位于前台且全屏": "Frontmost and full screen", "位于前台": "Frontmost", "运行时": "Running", "锁屏、睡眠，或全屏播放视频、玩游戏时，Pausa 会自动暂停。\n短休息最多推迟 10 分钟，长休息最多推迟 30 分钟。\n连续使用 90 分钟后，长休息不能再推迟。": "Pausa pauses automatically when your screen is locked, your Mac is asleep, or a video or game is full screen.\nShort breaks can be postponed by up to 10 minutes, and long breaks by up to 30 minutes.\nAfter 90 minutes of continuous use, the long break can't be postponed.", "低频提醒": "Fewer reminders", "预设": "Preset", "标准": "Standard", "护眼优先": "Eye care", "自定义": "Custom", "长休息": "Long break", "特定日期": "Specific dates", "工作日": "Weekdays", "播放视频时": "While video plays", "休息": "Breaks", "通用": "General", "外观": "Appearance", "关于": "About",
        "已暂停：正在开会": "Paused: in a meeting", "已暂停：%@ 全屏中": "Paused: %@ is full screen",
        // Round 3
        "%@ 后开始短休息，%@": "Short break in %@, for %@", "%@ 后开始长休息，%@": "Long break in %@, for %@", "休息延后 %d 分钟": "Postpone break %d min", "break.short.ending": "Almost done", "break.holdToSkip": "Hold %@ to skip", "key.space": "Space", "break.short.hint": "Look far away",
        "短休息时长": "Short break length", "长休息时长": "Long break length", "在程序坞显示": "Show in Dock", "暂停范围": "Breaks to pause", "仅短休息": "Short breaks only", "所有休息": "All breaks",
        "预览休息界面": "Preview break screen", "生效条件": "Pause when", "添加应用": "Add app", 
        "编辑": "Edit",
        "删除时段": "Delete hours",
        "添加": "Add",
        "设置": "Settings",
        "暂停提醒 1 小时": "Pause for 1 hour", "恢复提醒": "Resume reminders", "添加提醒时段": "Add active hours", "添加免打扰时段": "Add quiet hours", "这些时段内不提醒休息，即使落在提醒时段内。": "Pausa doesn't remind you to take breaks during these hours, even within active hours.",
    ]

    static let es: [String: String] = [
        // pre-break card + cursor pill (SPEC-prebreak-v0.2 §2–3)
        "马上休息一下": "Descanso corto en breve", "长休息快到了": "Descanso largo en breve", "休息 %d 秒": "Descanso de %d s", "休息 %d 分钟": "Descanso de %d min", "跳过这次": "Saltar este", "推迟 %d 分钟": "%d min más tarde", "还能推迟 %d 分钟": "Puedes posponer %d min más", "推迟额度用完了": "Ya no puedes posponer", "已连续工作 %d 分钟": "Trabajando desde hace %d min", "刚休息过": "Acabas de descansar", "%d 秒后休息": "Descanso en %d s", "写完这句再休息": "Termina la frase", "收起": "Ocultar",
        "随机": "Aleatorio",
        // Update UI (About row, popover line)
        "检查更新": "Buscar actualizaciones", "正在检查…": "Buscando…", "已是最新版本": "Pausa está actualizada", "正在下载 %@": "Descargando %@", "%@ 已就绪，重启后生效": "La versión %@ está lista y se aplicará al reiniciar", "暂时无法检查更新": "No se pueden buscar actualizaciones por ahora", "有新版本 %@": "Nueva versión %@", "休息结束后安装": "Se instalará al terminar el descanso", "立即重启": "Reiniciar ahora", "自动检查更新": "Busca actualizaciones automáticamente",
        "图标": "Icono", "水墨": "Tinta", "玻璃": "Cristal",
        "暂停提醒": "Pausar recordatorios",
        "在以下情况下，暂时不提醒休息。": "Pausa no te recordará descansar en estas situaciones.",
        "图标的灵感来自泰国寺庙里的莲花。": "El icono se inspira en las flores de loto de los templos tailandeses.",
        "菜单栏显示": "La barra de menús muestra", "剩余时间": "Tiempo restante", "进度圆环": "Anillo de progreso",
        "rhythm.line1": "Descansa cada{1},", "rhythm.line2.one": "y haz un descanso largo tras{1}descanso corto.", "rhythm.line2.other": "y haz un descanso largo tras{1}descansos cortos.",
        "这一天": "Este día es",
        "免打扰时段": "Horario de silencio", "上班": "Día laborable", "日期休息": "Día libre", "添加日期": "Añadir fecha", "删除日期": "Eliminar fecha", "这些日期按设置上班或休息，不按星期几。": "Estas fechas siguen tu ajuste en lugar del día de la semana.", "视频播放器和网页里的视频": "Reproductores de vídeo y vídeos en páginas web",
        "已暂停：%@ 正在播放视频": "En pausa: %@ reproduce vídeo",
        "已暂停：正在共享屏幕（%@）": "En pausa: compartiendo pantalla (%@)",
        "已暂停：正在共享屏幕": "En pausa: compartiendo pantalla",
        "已暂停：正在录屏（%@）": "En pausa: grabando pantalla (%@)",
        "已暂停：正在录屏": "En pausa: grabando pantalla",
        "已推迟：%@ 在前台": "Pospuesto: %@ en primer plano",
        "等你打完这句…": "Esperando a que termines de escribir…",
        "短休息已暂停": "descansos cortos en pausa",
        "休息已推迟": "descansos pospuestos",
        "专注模式「%@」：%@": "Concentración «%@»: %@",
        "专注模式：%@": "Concentración: %@",
        "视频结束 2 分钟后继续": "Sigue 2 minutos después del vídeo",
        "结束后补一次长休息": "Al terminar habrá un descanso largo",
        "还可推迟 %lld 分钟": "Aún puede posponer %lld min",
        "最多再等 %@": "Esperando hasta %@",
        "版本 %@": "Versión %@",
        "全天": "Todo el día",
        "时段": "Horario activo",
        "时段外": "Fuera del horario",
        "下次开始 %@": "Empieza a las %@",
        "明天 %@": "Mañana %@",
        "开始": "Inicio",
        "结束": "Fin",
        "重复": "Repetir",
        "删除": "Eliminar",
        "取消": "Cancelar",
        "完成": "OK",
        "添加日期…": "Añadir fecha…",
        "全天不提醒": "Sin recordatorios todo el día",
        "自定义时段": "Horario personalizado",
        "日期": "Fecha",
        "当天": "Ese día",
        "从不": "Nunca",
        "每天": "Todos los días",
        "周末": "Fines de semana",
        "结束早于开始：时段跨过午夜。": "El fin es anterior al inicio: el horario cruza la medianoche.",
        "登录时打开": "Abrir al iniciar sesión", 
        "由 Bowen（debidong）开发": "Desarrollado por Bowen (debidong)",
        "名字来自西班牙语中的“暂停”。": "El nombre viene de la palabra española “pausa”.",
        
        "配色模式": "Modo", "appearance.system": "Auto", "浅色": "Claro", "深色": "Oscuro",
        "森林": "Bosque", "大海": "Océano", "晚霞": "Atardecer", "夜空": "Cielo nocturno", "跟随系统": "Según el sistema",
        "已暂停，%@ 后恢复": "En pausa, se reanuda en %@",
        "你离开了电脑": "Te has alejado del ordenador",
        "长休息中": "Descanso largo en curso", "短休息中": "Descanso corto en curso",
        "长休息：%@ 后": "Descanso largo en %@", "短休息：%@ 后": "Descanso corto en %@",
        "立即短休息": "Descanso corto ahora", "立即长休息": "Descanso largo ahora",
        
        "退出 Pausa": "Salir de Pausa",
        // menu popover
        "短休息": "Pausa corta", "%d 秒": "%d s", "%d 分钟": "%d min",
        "现在休息": "Descansar ya", "已连续使用 90 分钟，长休息不能再推迟。": "Llevas 90 minutos trabajando. La pausa larga ya no se puede posponer.",
        "Pausa 已在运行，下次休息在 %@ 后。": "Pausa está en marcha. Próximo descanso en %@.",
        "分钟": "min", "秒": "s", 
        "主题": "Tema", "预览": "Vista previa", "语言": "Idioma",
        HealthNote.key: "Si las molestias en los ojos persisten, acude al médico sin demora. Pausa no sustituye un tratamiento profesional.",
        // Settings › 休息
        "休息节奏": "Ritmo de descansos", "每次": "de", "提醒时段": "Horario activo", "仅在指定时段提醒": "Avisar solo en el horario activo", "会议进行时": "Durante reuniones", "麦克风或摄像头正在使用": "El micrófono o la cámara están en uso", "共享或录制屏幕时": "Al compartir o grabar la pantalla", "专注模式开启时": "Con un modo de concentración activo", "尚未在系统设置中添加 Pausa 专注过滤器": "El filtro de concentración de Pausa no está añadido en Ajustes del Sistema", "打开系统设置…": "Abrir Ajustes del Sistema…", "输入或拖移时延迟": "Esperar al escribir o arrastrar", "最长 2 分钟": "Hasta 2 minutos", "使用指定应用时": "Al usar apps concretas", "移除": "Quitar", "位于前台且全屏": "En primer plano y a pantalla completa", "位于前台": "En primer plano", "运行时": "Abierta", "锁屏、睡眠，或全屏播放视频、玩游戏时，Pausa 会自动暂停。\n短休息最多推迟 10 分钟，长休息最多推迟 30 分钟。\n连续使用 90 分钟后，长休息不能再推迟。": "Pausa se pausa sola con la pantalla bloqueada, el Mac en reposo o un vídeo o juego a pantalla completa.\nLos descansos cortos se pueden posponer hasta 10 minutos y los largos hasta 30.\nTras 90 minutos de uso seguido, el descanso largo no se puede posponer.", "低频提醒": "Menos avisos", "预设": "Preajuste", "标准": "Estándar", "护眼优先": "Cuidado visual", "自定义": "Personalizado", "长休息": "Descanso largo", "特定日期": "Fechas concretas", "工作日": "Entre semana", "播放视频时": "Al reproducir vídeo", "休息": "Descansos", "通用": "General", "外观": "Apariencia", "关于": "Acerca de",
        "已暂停：正在开会": "En pausa: en una reunión", "已暂停：%@ 全屏中": "En pausa: %@ en pantalla completa",
        // Round 3
        "%@ 后开始短休息，%@": "Pausa corta en %@, de %@", "%@ 后开始长休息，%@": "Pausa larga en %@, de %@", "休息延后 %d 分钟": "Posponer descanso %d min", "break.short.ending": "Casi listo", "break.holdToSkip": "Mantén %@ para omitir", "key.space": "Espacio", "break.short.hint": "Mira a lo lejos",
        "短休息时长": "Duración del descanso corto", "长休息时长": "Duración del descanso largo", "在程序坞显示": "Mostrar en el Dock", "暂停范围": "Descansos que se pausan", "仅短休息": "Solo descansos cortos", "所有休息": "Todos los descansos",
        "预览休息界面": "Vista previa de la pantalla de descanso", "生效条件": "Pausar cuando", "添加应用": "Añadir app", 
        "编辑": "Editar",
        "删除时段": "Eliminar horario",
        "添加": "Añadir",
        "设置": "Ajustes",
        "暂停提醒 1 小时": "Pausar 1 hora", "恢复提醒": "Reanudar recordatorios", "添加提醒时段": "Añadir horario activo", "添加免打扰时段": "Añadir horario de silencio", "这些时段内不提醒休息，即使落在提醒时段内。": "Pausa no te recuerda descansar en estas horas, aunque estén dentro del horario activo.",
    ]

    static let ru: [String: String] = [
        // pre-break card + cursor pill (SPEC-prebreak-v0.2 §2–3)
        "马上休息一下": "Скоро короткий перерыв", "长休息快到了": "Скоро длинный перерыв", "休息 %d 秒": "Перерыв %d с", "休息 %d 分钟": "Перерыв %d мин", "跳过这次": "Пропустить", "推迟 %d 分钟": "Через %d мин", "还能推迟 %d 分钟": "Можно отложить ещё на %d мин", "推迟额度用完了": "Откладывать больше нельзя", "已连续工作 %d 分钟": "Вы работаете %d мин", "刚休息过": "Вы только что отдохнули", "%d 秒后休息": "Перерыв через %d с", "写完这句再休息": "Допишите фразу", "收起": "Скрыть",
        "随机": "Случайно",
        // Update UI (About row, popover line)
        "检查更新": "Проверить обновления", "正在检查…": "Проверка…", "已是最新版本": "Установлена последняя версия", "正在下载 %@": "Загрузка %@", "%@ 已就绪，重启后生效": "Версия %@ готова и заработает после перезапуска", "暂时无法检查更新": "Сейчас не удаётся проверить обновления", "有新版本 %@": "Новая версия %@", "休息结束后安装": "Установится после перерыва", "立即重启": "Перезапустить", "自动检查更新": "Обновления проверяются автоматически",
        "图标": "Значок", "水墨": "Тушь", "玻璃": "Стекло",
        "暂停提醒": "Приостановка напоминаний",
        "在以下情况下，暂时不提醒休息。": "В этих ситуациях Pausa не будет напоминать о перерыве.",
        "图标的灵感来自泰国寺庙里的莲花。": "Значок вдохновлён лотосами в тайских храмах.",
        "菜单栏显示": "В строке меню", "剩余时间": "Оставшееся время", "进度圆环": "Кольцо прогресса",
        "rhythm.line1": "Перерыв каждые{1},", "rhythm.line2.one": "а длинный — после{1}короткого перерыва.", "rhythm.line2.few": "а длинный — после{1}коротких перерывов.", "rhythm.line2.many": "а длинный — после{1}коротких перерывов.", "rhythm.line2.other": "а длинный — после{1}коротких перерывов.",
        "这一天": "Этот день —",
        "免打扰时段": "Тихие часы", "上班": "Рабочий день", "日期休息": "Выходной", "添加日期": "Добавить дату", "删除日期": "Удалить дату", "这些日期按设置上班或休息，不按星期几。": "Эти даты следуют вашей настройке, а не дню недели.", "视频播放器和网页里的视频": "Видеоплееры и видео на веб-страницах",
        "已暂停：%@ 正在播放视频": "Пауза: %@ воспроизводит видео",
        "已暂停：正在共享屏幕（%@）": "Пауза: демонстрация экрана (%@)",
        "已暂停：正在共享屏幕": "Пауза: демонстрация экрана",
        "已暂停：正在录屏（%@）": "Пауза: запись экрана (%@)",
        "已暂停：正在录屏": "Пауза: запись экрана",
        "已推迟：%@ 在前台": "Отложено: %@ активно",
        "等你打完这句…": "Ждём, пока вы допечатаете…",
        "短休息已暂停": "короткие перерывы на паузе",
        "休息已推迟": "перерывы отложены",
        "专注模式「%@」：%@": "Фокусирование «%@»: %@",
        "专注模式：%@": "Фокусирование: %@",
        "视频结束 2 分钟后继续": "Продолжится через 2 мин после видео",
        "结束后补一次长休息": "После окончания — длинный перерыв",
        "还可推迟 %lld 分钟": "Можно отложить ещё на %lld мин",
        "最多再等 %@": "Ждём до %@",
        "版本 %@": "Версия %@",
        "全天": "Весь день",
        "时段": "Рабочие часы",
        "时段外": "Вне рабочих часов",
        "下次开始 %@": "Начало в %@",
        "明天 %@": "Завтра %@",
        "开始": "Начало",
        "结束": "Конец",
        "重复": "Повтор",
        "删除": "Удалить",
        "取消": "Отменить",
        "完成": "Готово",
        "添加日期…": "Добавить дату…",
        "全天不提醒": "Без напоминаний весь день",
        "自定义时段": "Свои часы",
        "日期": "Дата",
        "当天": "В этот день",
        "从不": "Никогда",
        "每天": "Каждый день",
        "周末": "Выходные",
        "结束早于开始：时段跨过午夜。": "Конец раньше начала: часы переходят через полночь.",
        "登录时打开": "Открывать при входе", 
        "由 Bowen（debidong）开发": "Разработчик: Bowen (debidong)",
        "名字来自西班牙语中的“暂停”。": "Название происходит от испанского слова «пауза».",
        
        "配色模式": "Режим", "appearance.system": "Авто", "浅色": "Светлая", "深色": "Тёмная",
        "森林": "Лес", "大海": "Океан", "晚霞": "Закат", "夜空": "Ночное небо", "跟随系统": "Как в системе",
        "已暂停，%@ 后恢复": "Приостановлено, возобновится через %@",
        "你离开了电脑": "Вы отошли от компьютера",
        "长休息中": "Идёт длинный перерыв", "短休息中": "Идёт короткий перерыв",
        "长休息：%@ 后": "Длинный перерыв через %@", "短休息：%@ 后": "Короткий перерыв через %@",
        "立即短休息": "Короткий перерыв сейчас", "立即长休息": "Длинный перерыв сейчас",
        
        "退出 Pausa": "Завершить Pausa",
        // menu popover
        "短休息": "Короткий перерыв", "%d 秒": "%d с", "%d 分钟": "%d мин",
        "现在休息": "Отдохнуть сейчас", "已连续使用 90 分钟，长休息不能再推迟。": "Вы работаете уже 90 минут. Длинный перерыв больше нельзя отложить.",
        "Pausa 已在运行，下次休息在 %@ 后。": "Pausa работает. Следующий перерыв через %@.",
        "分钟": "мин", "秒": "с", 
        "主题": "Тема", "预览": "Просмотр", "语言": "Язык",
        HealthNote.key: "Если дискомфорт в глазах не проходит, своевременно обратитесь к врачу. Pausa не заменяет профессиональное лечение.",
        // Settings › 休息
        "休息节奏": "Ритм перерывов", "每次": "по", "提醒时段": "Активные часы", "仅在指定时段提醒": "Напоминать только в активные часы", "会议进行时": "Во время встреч", "麦克风或摄像头正在使用": "Используется микрофон или камера", "共享或录制屏幕时": "При демонстрации или записи экрана", "专注模式开启时": "Когда включён фокус", "尚未在系统设置中添加 Pausa 专注过滤器": "Фильтр фокуса Pausa не добавлен в Системных настройках", "打开系统设置…": "Открыть Системные настройки…", "输入或拖移时延迟": "Ждать, пока вы печатаете или перетаскиваете", "最长 2 分钟": "До 2 минут", "使用指定应用时": "При работе в выбранных приложениях", "移除": "Удалить", "位于前台且全屏": "На переднем плане и во весь экран", "位于前台": "На переднем плане", "运行时": "Запущено", "锁屏、睡眠，或全屏播放视频、玩游戏时，Pausa 会自动暂停。\n短休息最多推迟 10 分钟，长休息最多推迟 30 分钟。\n连续使用 90 分钟后，长休息不能再推迟。": "Pausa приостанавливается, когда экран заблокирован, Mac спит или видео либо игра открыты во весь экран.\nКороткий перерыв можно отложить до 10 минут, длинный — до 30 минут.\nПосле 90 минут непрерывной работы длинный перерыв отложить нельзя.", "低频提醒": "Реже", "预设": "Набор", "标准": "Стандарт", "护眼优先": "Забота о глазах", "自定义": "Свой", "长休息": "Длинный перерыв", "特定日期": "Отдельные даты", "工作日": "Будни", "播放视频时": "При воспроизведении видео", "休息": "Перерывы", "通用": "Основные", "外观": "Оформление", "关于": "О программе",
        "已暂停：正在开会": "Пауза: идёт встреча", "已暂停：%@ 全屏中": "Пауза: %@ в полноэкранном режиме",
        // Round 3
        "%@ 后开始短休息，%@": "Короткий перерыв через %@, %@", "%@ 后开始长休息，%@": "Длинный перерыв через %@, %@", "休息延后 %d 分钟": "Отложить перерыв на %d мин", "break.short.ending": "Почти всё", "break.holdToSkip": "Удерживайте %@, чтобы пропустить", "key.space": "Пробел", "break.short.hint": "Посмотрите вдаль",
        "短休息时长": "Длительность короткого перерыва", "长休息时长": "Длительность длинного перерыва", "在程序坞显示": "Показывать в Dock", "暂停范围": "Какие перерывы приостанавливать", "仅短休息": "Только короткие перерывы", "所有休息": "Все перерывы",
        "预览休息界面": "Просмотр экрана перерыва", "生效条件": "Когда приостанавливать", "添加应用": "Добавить приложение", 
        "编辑": "Изменить",
        "删除时段": "Удалить часы",
        "添加": "Добавить",
        "设置": "Настройки",
        "暂停提醒 1 小时": "Приостановить на 1 час", "恢复提醒": "Возобновить напоминания", "添加提醒时段": "Добавить активные часы", "添加免打扰时段": "Добавить тихие часы", "这些时段内不提醒休息，即使落在提醒时段内。": "В эти часы Pausa не напоминает о перерывах, даже если они входят в активные часы.",
    ]

    static let fr: [String: String] = [
        // pre-break card + cursor pill (SPEC-prebreak-v0.2 §2–3)
        "马上休息一下": "Pause courte imminente", "长休息快到了": "Pause longue imminente", "休息 %d 秒": "Pause de %d s", "休息 %d 分钟": "Pause de %d min", "跳过这次": "Passer celle-ci", "推迟 %d 分钟": "Dans %d min", "还能推迟 %d 分钟": "Encore %d min de report possible", "推迟额度用完了": "Plus de report possible", "已连续工作 %d 分钟": "Au travail depuis %d min", "刚休息过": "Pause toute récente", "%d 秒后休息": "Pause dans %d s", "写完这句再休息": "Finissez votre phrase", "收起": "Masquer",
        "随机": "Aléatoire",
        // Update UI (About row, popover line)
        "检查更新": "Rechercher les mises à jour", "正在检查…": "Recherche…", "已是最新版本": "Pausa est à jour", "正在下载 %@": "Téléchargement de %@", "%@ 已就绪，重启后生效": "La version %@ est prête et s'appliquera au redémarrage", "暂时无法检查更新": "Impossible de rechercher les mises à jour pour le moment", "有新版本 %@": "Nouvelle version %@", "休息结束后安装": "S'installera après la pause", "立即重启": "Redémarrer maintenant", "自动检查更新": "Recherche les mises à jour automatiquement",
        "图标": "Icône", "水墨": "Encre", "玻璃": "Verre",
        "暂停提醒": "Suspendre les rappels",
        "在以下情况下，暂时不提醒休息。": "Pausa ne vous rappellera pas de faire une pause dans ces situations.",
        "图标的灵感来自泰国寺庙里的莲花。": "L’icône s’inspire des fleurs de lotus des temples thaïlandais.",
        "菜单栏显示": "La barre des menus affiche", "剩余时间": "Temps restant", "进度圆环": "Anneau de progression",
        "rhythm.line1": "Faites une pause toutes les{1},", "rhythm.line2.one": "et une pause longue après{1}pause courte.", "rhythm.line2.other": "et une pause longue après{1}pauses courtes.",
        "这一天": "Ce jour est",
        "免打扰时段": "Heures calmes", "上班": "Jour travaillé", "日期休息": "Jour de congé", "添加日期": "Ajouter une date", "删除日期": "Supprimer la date", "这些日期按设置上班或休息，不按星期几。": "Ces dates suivent votre réglage plutôt que le jour de la semaine.", "视频播放器和网页里的视频": "Lecteurs vidéo et vidéos des pages web",
        "已暂停：%@ 正在播放视频": "En pause : %@ lit une vidéo",
        "已暂停：正在共享屏幕（%@）": "En pause : partage d’écran (%@)",
        "已暂停：正在共享屏幕": "En pause : partage d’écran",
        "已暂停：正在录屏（%@）": "En pause : enregistrement d’écran (%@)",
        "已暂停：正在录屏": "En pause : enregistrement d’écran",
        "已推迟：%@ 在前台": "Reporté : %@ au premier plan",
        "等你打完这句…": "On attend la fin de votre phrase…",
        "短休息已暂停": "pauses courtes suspendues",
        "休息已推迟": "pauses reportées",
        "专注模式「%@」：%@": "Concentration « %@ » : %@",
        "专注模式：%@": "Concentration : %@",
        "视频结束 2 分钟后继续": "Reprend 2 minutes après la vidéo",
        "结束后补一次长休息": "Une longue pause suivra",
        "还可推迟 %lld 分钟": "Encore %lld min de report possible",
        "最多再等 %@": "Attente jusqu’à %@",
        "版本 %@": "Version %@",
        "全天": "Toute la journée",
        "时段": "Heures actives",
        "时段外": "Hors des heures actives",
        "下次开始 %@": "Reprend à %@",
        "明天 %@": "Demain %@",
        "开始": "Début",
        "结束": "Fin",
        "重复": "Répéter",
        "删除": "Supprimer",
        "取消": "Annuler",
        "完成": "OK",
        "添加日期…": "Ajouter une date…",
        "全天不提醒": "Aucun rappel de la journée",
        "自定义时段": "Heures personnalisées",
        "日期": "Date",
        "当天": "Ce jour-là",
        "从不": "Jamais",
        "每天": "Tous les jours",
        "周末": "Le week-end",
        "结束早于开始：时段跨过午夜。": "La fin précède le début : les heures passent minuit.",
        "登录时打开": "Ouvrir à la connexion", 
        "由 Bowen（debidong）开发": "Développé par Bowen (debidong)",
        "名字来自西班牙语中的“暂停”。": "Le nom vient du mot espagnol signifiant « pause ».",
        
        "配色模式": "Mode", "appearance.system": "Auto", "浅色": "Clair", "深色": "Sombre",
        "森林": "Forêt", "大海": "Océan", "晚霞": "Coucher de soleil", "夜空": "Ciel nocturne", "跟随系统": "Selon le système",
        "已暂停，%@ 后恢复": "En pause, reprise dans %@",
        "你离开了电脑": "Vous êtes loin de l’ordinateur",
        "长休息中": "Longue pause en cours", "短休息中": "Courte pause en cours",
        "长休息：%@ 后": "Longue pause dans %@", "短休息：%@ 后": "Courte pause dans %@",
        "立即短休息": "Courte pause maintenant", "立即长休息": "Longue pause maintenant",
        
        "退出 Pausa": "Quitter Pausa",
        // menu popover
        "短休息": "Pause courte", "%d 秒": "%d s", "%d 分钟": "%d min",
        "现在休息": "Pause maintenant", "已连续使用 90 分钟，长休息不能再推迟。": "Vous travaillez depuis 90 minutes. La pause longue ne peut plus être reportée.",
        "Pausa 已在运行，下次休息在 %@ 后。": "Pausa est lancé. Prochaine pause dans %@.",
        "分钟": "min", "秒": "s", 
        "主题": "Thème", "预览": "Aperçu", "语言": "Langue",
        HealthNote.key: "Si la gêne oculaire persiste, consultez rapidement un médecin. Pausa ne remplace pas un traitement professionnel.",
        // Settings › 休息
        "休息节奏": "Rythme des pauses", "每次": "de", "提醒时段": "Heures actives", "仅在指定时段提醒": "Rappeler seulement pendant les heures actives", "会议进行时": "Pendant les réunions", "麦克风或摄像头正在使用": "Le micro ou la caméra est utilisé", "共享或录制屏幕时": "Pendant le partage ou l’enregistrement de l’écran", "专注模式开启时": "Quand une concentration est active", "尚未在系统设置中添加 Pausa 专注过滤器": "Le filtre de concentration Pausa n’est pas ajouté dans Réglages Système", "打开系统设置…": "Ouvrir Réglages Système…", "输入或拖移时延迟": "Attendre pendant la saisie ou le glisser", "最长 2 分钟": "Jusqu’à 2 minutes", "使用指定应用时": "Avec certaines apps", "移除": "Retirer", "位于前台且全屏": "Au premier plan et en plein écran", "位于前台": "Au premier plan", "运行时": "Ouverte", "锁屏、睡眠，或全屏播放视频、玩游戏时，Pausa 会自动暂停。\n短休息最多推迟 10 分钟，长休息最多推迟 30 分钟。\n连续使用 90 分钟后，长休息不能再推迟。": "Pausa se met en pause quand l’écran est verrouillé, que le Mac est en veille ou qu’une vidéo ou un jeu est en plein écran.\nLes pauses courtes peuvent être reportées de 10 minutes au plus, les longues de 30 minutes.\nAprès 90 minutes d’utilisation continue, la pause longue ne peut plus être reportée.", "低频提醒": "Moins de rappels", "预设": "Préréglage", "标准": "Standard", "护眼优先": "Confort visuel", "自定义": "Personnalisé", "长休息": "Pause longue", "特定日期": "Dates précises", "工作日": "Jours ouvrés", "播放视频时": "Pendant la lecture vidéo", "休息": "Pauses", "通用": "Général", "外观": "Apparence", "关于": "À propos",
        "已暂停：正在开会": "En pause : en réunion", "已暂停：%@ 全屏中": "En pause : %@ en plein écran",
        // Round 3
        "%@ 后开始短休息，%@": "Pause courte dans %@, de %@", "%@ 后开始长休息，%@": "Pause longue dans %@, de %@", "休息延后 %d 分钟": "Reporter la pause de %d min", "break.short.ending": "Presque fini", "break.holdToSkip": "Maintenez %@ pour passer", "key.space": "Espace", "break.short.hint": "Regardez au loin",
        "短休息时长": "Durée de la pause courte", "长休息时长": "Durée de la pause longue", "在程序坞显示": "Afficher dans le Dock", "暂停范围": "Pauses à suspendre", "仅短休息": "Pauses courtes uniquement", "所有休息": "Toutes les pauses",
        "预览休息界面": "Aperçu de l’écran de pause", "生效条件": "Suspendre quand", "添加应用": "Ajouter une app", 
        "编辑": "Modifier",
        "删除时段": "Supprimer les heures",
        "添加": "Ajouter",
        "设置": "Réglages",
        "暂停提醒 1 小时": "Suspendre 1 heure", "恢复提醒": "Reprendre les rappels", "添加提醒时段": "Ajouter des heures actives", "添加免打扰时段": "Ajouter des heures calmes", "这些时段内不提醒休息，即使落在提醒时段内。": "Pausa ne vous rappelle pas de faire une pause pendant ces heures, même pendant les heures actives.",
    ]

    static let vi: [String: String] = [
        // pre-break card + cursor pill (SPEC-prebreak-v0.2 §2–3)
        "马上休息一下": "Sắp đến giờ nghỉ ngắn", "长休息快到了": "Sắp đến giờ nghỉ dài", "休息 %d 秒": "Nghỉ %d giây", "休息 %d 分钟": "Nghỉ %d phút", "跳过这次": "Bỏ qua lần này", "推迟 %d 分钟": "Hoãn %d phút", "还能推迟 %d 分钟": "Còn hoãn được %d phút", "推迟额度用完了": "Đã hết lượt hoãn", "已连续工作 %d 分钟": "Đã làm việc %d phút", "刚休息过": "Vừa nghỉ xong", "%d 秒后休息": "Nghỉ sau %d giây", "写完这句再休息": "Viết xong câu đã", "收起": "Ẩn",
        "随机": "Ngẫu nhiên",
        // Update UI (About row, popover line)
        "检查更新": "Kiểm tra cập nhật", "正在检查…": "Đang kiểm tra…", "已是最新版本": "Đã là phiên bản mới nhất", "正在下载 %@": "Đang tải %@", "%@ 已就绪，重启后生效": "Bản %@ đã sẵn sàng, có hiệu lực sau khi khởi động lại", "暂时无法检查更新": "Tạm thời không kiểm tra được bản cập nhật", "有新版本 %@": "Có phiên bản mới %@", "休息结束后安装": "Sẽ cài sau khi nghỉ xong", "立即重启": "Khởi động lại ngay", "自动检查更新": "Tự động kiểm tra cập nhật",
        "图标": "Biểu tượng", "水墨": "Mực", "玻璃": "Kính",
        "暂停提醒": "Tạm dừng nhắc nhở",
        "在以下情况下，暂时不提醒休息。": "Pausa sẽ không nhắc bạn nghỉ trong các trường hợp sau.",
        "图标的灵感来自泰国寺庙里的莲花。": "Biểu tượng lấy cảm hứng từ hoa sen ở chùa Thái Lan.",
        "菜单栏显示": "Thanh menu hiển thị", "剩余时间": "Thời gian còn lại", "进度圆环": "Vòng tiến độ",
        "rhythm.line1": "Nghỉ mỗi{1},", "rhythm.line2.other": "nghỉ dài sau{1}lần nghỉ ngắn.",
        "这一天": "Ngày này là",
        "免打扰时段": "Khung giờ yên lặng", "上班": "Ngày làm việc", "日期休息": "Ngày nghỉ", "添加日期": "Thêm ngày", "删除日期": "Xóa ngày", "这些日期按设置上班或休息，不按星期几。": "Những ngày này theo cài đặt của bạn thay vì theo thứ trong tuần.", "视频播放器和网页里的视频": "Trình phát video và video trên trang web",
        "已暂停：%@ 正在播放视频": "Đã tạm dừng: %@ đang phát video",
        "已暂停：正在共享屏幕（%@）": "Đã tạm dừng: đang chia sẻ màn hình (%@)",
        "已暂停：正在共享屏幕": "Đã tạm dừng: đang chia sẻ màn hình",
        "已暂停：正在录屏（%@）": "Đã tạm dừng: đang quay màn hình (%@)",
        "已暂停：正在录屏": "Đã tạm dừng: đang quay màn hình",
        "已推迟：%@ 在前台": "Đã hoãn: %@ ở phía trước",
        "等你打完这句…": "Chờ bạn gõ xong…",
        "短休息已暂停": "nghỉ ngắn đã tạm dừng",
        "休息已推迟": "nghỉ đã được hoãn",
        "专注模式「%@」：%@": "Tập trung “%@”: %@",
        "专注模式：%@": "Tập trung: %@",
        "视频结束 2 分钟后继续": "Tiếp tục 2 phút sau khi video kết thúc",
        "结束后补一次长休息": "Sẽ nghỉ dài khi kết thúc",
        "还可推迟 %lld 分钟": "Còn có thể hoãn %lld phút",
        "最多再等 %@": "Chờ tối đa %@",
        "版本 %@": "Phiên bản %@",
        "全天": "Cả ngày",
        "时段": "Khung giờ",
        "时段外": "Ngoài khung giờ",
        "下次开始 %@": "Bắt đầu lúc %@",
        "明天 %@": "Ngày mai %@",
        "开始": "Bắt đầu",
        "结束": "Kết thúc",
        "重复": "Lặp lại",
        "删除": "Xóa",
        "取消": "Hủy",
        "完成": "Xong",
        "添加日期…": "Thêm ngày…",
        "全天不提醒": "Không nhắc cả ngày",
        "自定义时段": "Khung giờ tùy chỉnh",
        "日期": "Ngày",
        "当天": "Trong ngày này",
        "从不": "Không bao giờ",
        "每天": "Hằng ngày",
        "周末": "Cuối tuần",
        "结束早于开始：时段跨过午夜。": "Giờ kết thúc sớm hơn giờ bắt đầu: khung giờ qua nửa đêm.",
        "登录时打开": "Mở khi đăng nhập", 
        "由 Bowen（debidong）开发": "Phát triển bởi Bowen (debidong)",
        "名字来自西班牙语中的“暂停”。": "Tên gọi bắt nguồn từ từ “tạm dừng” trong tiếng Tây Ban Nha.",
        
        "配色模式": "Chế độ", "appearance.system": "Tự động", "浅色": "Sáng", "深色": "Tối",
        "森林": "Rừng", "大海": "Biển", "晚霞": "Hoàng hôn", "夜空": "Bầu trời đêm", "跟随系统": "Theo hệ thống",
        "已暂停，%@ 后恢复": "Đã tạm dừng, tiếp tục sau %@",
        "你离开了电脑": "Bạn đang rời khỏi máy tính",
        "长休息中": "Đang nghỉ dài", "短休息中": "Đang nghỉ ngắn",
        "长休息：%@ 后": "Nghỉ dài sau %@", "短休息：%@ 后": "Nghỉ ngắn sau %@",
        "立即短休息": "Nghỉ ngắn ngay", "立即长休息": "Nghỉ dài ngay",
        
        "退出 Pausa": "Thoát Pausa",
        // menu popover
        "短休息": "Nghỉ ngắn", "%d 秒": "%d giây", "%d 分钟": "%d phút",
        "现在休息": "Nghỉ ngay", "已连续使用 90 分钟，长休息不能再推迟。": "Bạn đã làm việc 90 phút. Không thể hoãn lần nghỉ dài nữa.",
        "Pausa 已在运行，下次休息在 %@ 后。": "Pausa đang chạy. Lần nghỉ tiếp theo sau %@.",
        "分钟": "phút", "秒": "giây", 
        "主题": "Chủ đề", "预览": "Xem trước", "语言": "Ngôn ngữ",
        HealthNote.key: "Nếu mắt vẫn tiếp tục khó chịu, hãy đi khám bác sĩ kịp thời. Pausa không thể thay thế việc điều trị chuyên môn.",
        // Settings › 休息
        "休息节奏": "Lịch nghỉ", "每次": "mỗi lần", "提醒时段": "Khung giờ nhắc", "仅在指定时段提醒": "Chỉ nhắc trong khung giờ đã đặt", "会议进行时": "Khi đang họp", "麦克风或摄像头正在使用": "Micrô hoặc camera đang được dùng", "共享或录制屏幕时": "Khi chia sẻ hoặc ghi màn hình", "专注模式开启时": "Khi bật Tập trung", "尚未在系统设置中添加 Pausa 专注过滤器": "Chưa thêm bộ lọc Tập trung của Pausa trong Cài đặt hệ thống", "打开系统设置…": "Mở Cài đặt hệ thống…", "输入或拖移时延迟": "Chờ khi đang gõ hoặc kéo", "最长 2 分钟": "Tối đa 2 phút", "使用指定应用时": "Khi dùng ứng dụng được chọn", "移除": "Xóa", "位于前台且全屏": "Ở phía trước và toàn màn hình", "位于前台": "Ở phía trước", "运行时": "Đang chạy", "锁屏、睡眠，或全屏播放视频、玩游戏时，Pausa 会自动暂停。\n短休息最多推迟 10 分钟，长休息最多推迟 30 分钟。\n连续使用 90 分钟后，长休息不能再推迟。": "Pausa tự động tạm dừng khi màn hình bị khóa, máy đang ngủ, hoặc khi xem video hay chơi game toàn màn hình.\nNghỉ ngắn có thể hoãn tối đa 10 phút, nghỉ dài tối đa 30 phút.\nSau 90 phút sử dụng liên tục, không thể hoãn nghỉ dài nữa.", "低频提醒": "Ít nhắc hơn", "预设": "Cài sẵn", "标准": "Tiêu chuẩn", "护眼优先": "Bảo vệ mắt", "自定义": "Tùy chỉnh", "长休息": "Nghỉ dài", "特定日期": "Ngày cụ thể", "工作日": "Ngày làm việc", "播放视频时": "Khi phát video", "休息": "Nghỉ", "通用": "Cài đặt chung", "外观": "Giao diện", "关于": "Giới thiệu",
        "已暂停：%@ 全屏中": "Đã tạm dừng: %@ đang toàn màn hình",
        // Round 3
        "%@ 后开始短休息，%@": "%@ nữa nghỉ ngắn, %@", "%@ 后开始长休息，%@": "%@ nữa nghỉ dài, %@", "休息延后 %d 分钟": "Hoãn nghỉ %d phút", "break.short.ending": "Sắp kết thúc", "break.holdToSkip": "Nhấn giữ %@ để bỏ qua", "key.space": "Phím cách", "break.short.hint": "Nhìn ra xa", "已暂停：正在开会": "Tạm dừng: đang họp",
        "短休息时长": "Thời lượng nghỉ ngắn", "长休息时长": "Thời lượng nghỉ dài", "在程序坞显示": "Hiển thị trong Dock", "暂停范围": "Lần nghỉ được tạm dừng", "仅短休息": "Chỉ nghỉ ngắn", "所有休息": "Tất cả lần nghỉ",
        "预览休息界面": "Xem trước màn hình nghỉ", "生效条件": "Tạm dừng khi", "添加应用": "Thêm ứng dụng", 
        "编辑": "Sửa",
        "删除时段": "Xóa khung giờ",
        "添加": "Thêm",
        "设置": "Cài đặt",
        "暂停提醒 1 小时": "Tạm dừng nhắc 1 giờ", "恢复提醒": "Tiếp tục nhắc", "添加提醒时段": "Thêm khung giờ nhắc", "添加免打扰时段": "Thêm khung giờ yên lặng", "这些时段内不提醒休息，即使落在提醒时段内。": "Pausa không nhắc nghỉ trong các khung giờ này, kể cả khi nằm trong khung giờ nhắc.",
    ]

    static let th: [String: String] = [
        // pre-break card + cursor pill (SPEC-prebreak-v0.2 §2–3)
        "马上休息一下": "ใกล้ถึงเวลาพักสั้น", "长休息快到了": "ใกล้ถึงเวลาพักยาว", "休息 %d 秒": "พัก %d วินาที", "休息 %d 分钟": "พัก %d นาที", "跳过这次": "ข้ามครั้งนี้", "推迟 %d 分钟": "เลื่อน %d นาที", "还能推迟 %d 分钟": "เลื่อนได้อีก %d นาที", "推迟额度用完了": "เลื่อนไม่ได้แล้ว", "已连续工作 %d 分钟": "ทำงานมา %d นาที", "刚休息过": "เพิ่งพักไป", "%d 秒后休息": "พักใน %d วินาที", "写完这句再休息": "พิมพ์ให้จบประโยคก่อน", "收起": "ซ่อน",
        "随机": "สุ่ม",
        // Update UI (About row, popover line)
        "检查更新": "ตรวจหาอัปเดต", "正在检查…": "กำลังตรวจหา…", "已是最新版本": "เป็นเวอร์ชันล่าสุดแล้ว", "正在下载 %@": "กำลังดาวน์โหลด %@", "%@ 已就绪，重启后生效": "%@ พร้อมแล้ว จะมีผลหลังเปิดแอปใหม่", "暂时无法检查更新": "ยังตรวจหาอัปเดตไม่ได้ในขณะนี้", "有新版本 %@": "มีเวอร์ชันใหม่ %@", "休息结束后安装": "จะติดตั้งหลังพักเสร็จ", "立即重启": "เปิดใหม่ตอนนี้", "自动检查更新": "ตรวจหาอัปเดตโดยอัตโนมัติ",
        "图标": "ไอคอน", "水墨": "หมึก", "玻璃": "กระจก",
        HealthNote.key: "หากดวงตายังรู้สึกไม่สบายอย่างต่อเนื่อง โปรดไปพบแพทย์โดยเร็ว Pausa ไม่สามารถใช้แทนการรักษาจากผู้เชี่ยวชาญได้",
        "菜单栏显示": "แถบเมนูแสดง",
        "剩余时间": "เวลาที่เหลือ",
        "进度圆环": "วงแหวนความคืบหน้า",
        "rhythm.line1": "พักทุก{1}",
        "rhythm.line2.other": "และพักยาวหลังพักสั้นครบ{1}ครั้ง",
        "这一天": "วันนี้เป็น",
        "免打扰时段": "ช่วงเวลาห้ามรบกวน",
        "上班": "วันทำงาน",
        "日期休息": "วันหยุด",
        "添加日期": "เพิ่มวันที่",
        "删除日期": "ลบวันที่",
        "这些日期按设置上班或休息，不按星期几。": "วันที่เหล่านี้เป็นวันทำงานหรือวันหยุดตามที่ตั้งไว้ ไม่ขึ้นกับวันในสัปดาห์",
        "视频播放器和网页里的视频": "โปรแกรมเล่นวิดีโอและวิดีโอในหน้าเว็บ",
        "已暂停：%@ 正在播放视频": "หยุดชั่วคราว: %@ กำลังเล่นวิดีโอ",
        "已暂停：正在共享屏幕（%@）": "หยุดชั่วคราว: กำลังแชร์หน้าจอ (%@)",
        "已暂停：正在共享屏幕": "หยุดชั่วคราว: กำลังแชร์หน้าจอ",
        "已暂停：正在录屏（%@）": "หยุดชั่วคราว: กำลังบันทึกหน้าจอ (%@)",
        "已暂停：正在录屏": "หยุดชั่วคราว: กำลังบันทึกหน้าจอ",
        "已推迟：%@ 在前台": "เลื่อนออกไป: %@ อยู่ด้านหน้า",
        "等你打完这句…": "รอให้คุณพิมพ์ให้เสร็จก่อน…",
        "短休息已暂停": "หยุดพักสั้นชั่วคราว",
        "休息已推迟": "เลื่อนการพักออกไป",
        "专注模式「%@」：%@": "โฟกัส “%@”: %@",
        "专注模式：%@": "โฟกัส: %@",
        "视频结束 2 分钟后继续": "เริ่มต่อ 2 นาทีหลังวิดีโอจบ",
        "结束后补一次长休息": "จะมีพักยาวหนึ่งครั้งหลังจบ",
        "还可推迟 %lld 分钟": "เลื่อนได้อีก %lld นาที",
        "最多再等 %@": "รอได้อีกไม่เกิน %@",
        "版本 %@": "เวอร์ชัน %@",
        "全天": "ทั้งวัน",
        "时段": "ช่วงเวลาเตือน",
        "时段外": "นอกช่วงเวลาเตือน",
        "下次开始 %@": "เริ่มครั้งถัดไป %@",
        "明天 %@": "พรุ่งนี้ %@",
        "开始": "เริ่ม",
        "结束": "สิ้นสุด",
        "重复": "ทำซ้ำ",
        "删除": "ลบ",
        "取消": "ยกเลิก",
        "完成": "เสร็จสิ้น",
        "添加日期…": "เพิ่มวันที่…",
        "全天不提醒": "ไม่เตือนทั้งวัน",
        "自定义时段": "กำหนดช่วงเวลาเอง",
        "日期": "วันที่",
        "当天": "ในวันนั้น",
        "从不": "ไม่ทำซ้ำ",
        "每天": "ทุกวัน",
        "周末": "วันหยุดสุดสัปดาห์",
        "结束早于开始：时段跨过午夜。": "เวลาสิ้นสุดอยู่ก่อนเวลาเริ่ม: ช่วงเวลานี้ข้ามเที่ยงคืน",
        "登录时打开": "เปิดเมื่อเข้าสู่ระบบ",
        "由 Bowen（debidong）开发": "พัฒนาโดย Bowen (debidong)",
        "名字来自西班牙语中的“暂停”。": "ชื่อนี้มาจากคำภาษาสเปนที่แปลว่า “หยุดพัก”",
        "图标的灵感来自泰国寺庙里的莲花。": "ไอคอนได้แรงบันดาลใจจากดอกบัวในวัดไทย",
        "配色模式": "โหมด",
        "appearance.system": "อัตโนมัติ",
        "浅色": "สว่าง",
        "深色": "มืด",
        "森林": "ป่า",
        "大海": "ทะเล",
        "晚霞": "แสงเย็น",
        "夜空": "ฟ้ายามค่ำ",
        "跟随系统": "ตามระบบ",
        "已暂停，%@ 后恢复": "หยุดชั่วคราว เริ่มต่อในอีก %@",
        "你离开了电脑": "คุณไม่ได้อยู่หน้าคอมพิวเตอร์",
        "长休息中": "กำลังพักยาว",
        "短休息中": "กำลังพักสั้น",
        "长休息：%@ 后": "พักยาวในอีก %@",
        "短休息：%@ 后": "พักสั้นในอีก %@",
        "立即短休息": "พักสั้นเดี๋ยวนี้",
        "立即长休息": "พักยาวเดี๋ยวนี้",
        "退出 Pausa": "ออกจาก Pausa",
        "短休息": "พักสั้น",
        "%d 秒": "%d วินาที",
        "%d 分钟": "%d นาที",
        "现在休息": "พักเดี๋ยวนี้",
        "已连续使用 90 分钟，长休息不能再推迟。": "คุณใช้งานต่อเนื่องมา 90 นาทีแล้ว เลื่อนพักยาวออกไปอีกไม่ได้",
        "Pausa 已在运行，下次休息在 %@ 后。": "Pausa กำลังทำงาน พักครั้งถัดไปในอีก %@",
        "分钟": "นาที",
        "秒": "วินาที",
        "主题": "ธีม",
        "预览": "แสดงตัวอย่าง",
        "语言": "ภาษา",
        "休息节奏": "จังหวะการพัก",
        "每次": "ครั้งละ",
        "提醒时段": "ช่วงเวลาเตือน",
        "仅在指定时段提醒": "เตือนเฉพาะในช่วงเวลาเตือน",
        "暂停提醒": "หยุดเตือนชั่วคราว",
        "在以下情况下，暂时不提醒休息。": "Pausa จะไม่เตือนให้พักในกรณีต่อไปนี้",
        "会议进行时": "ระหว่างประชุม",
        "麦克风或摄像头正在使用": "ไมโครโฟนหรือกล้องกำลังทำงาน",
        "共享或录制屏幕时": "ขณะแชร์หรือบันทึกหน้าจอ",
        "专注模式开启时": "ขณะเปิดโฟกัส",
        "尚未在系统设置中添加 Pausa 专注过滤器": "ยังไม่ได้เพิ่มตัวกรองโฟกัสของ Pausa ในการตั้งค่าระบบ",
        "打开系统设置…": "เปิดการตั้งค่าระบบ…",
        "输入或拖移时延迟": "รอขณะพิมพ์หรือลาก",
        "最长 2 分钟": "ไม่เกิน 2 นาที",
        "使用指定应用时": "ขณะใช้แอปที่เลือก",
        "移除": "เอาออก",
        "位于前台且全屏": "อยู่ด้านหน้าและเต็มหน้าจอ",
        "位于前台": "อยู่ด้านหน้า",
        "运行时": "กำลังเปิดอยู่",
        "锁屏、睡眠，或全屏播放视频、玩游戏时，Pausa 会自动暂停。\n短休息最多推迟 10 分钟，长休息最多推迟 30 分钟。\n连续使用 90 分钟后，长休息不能再推迟。": "Pausa จะหยุดชั่วคราวเองเมื่อล็อกหน้าจอ Mac อยู่ในโหมดพักเครื่อง หรือเปิดวิดีโอหรือเกมเต็มหน้าจอ\nเลื่อนพักสั้นได้ไม่เกิน 10 นาที และพักยาวได้ไม่เกิน 30 นาที\nเมื่อใช้งานต่อเนื่องครบ 90 นาที จะเลื่อนพักยาวไม่ได้อีก",
        "低频提醒": "เตือนน้อยลง",
        "预设": "ค่าที่ตั้งไว้",
        "标准": "มาตรฐาน",
        "护眼优先": "ถนอมสายตา",
        "自定义": "กำหนดเอง",
        "长休息": "พักยาว",
        "特定日期": "วันที่เฉพาะ",
        "工作日": "วันธรรมดา",
        "播放视频时": "ขณะเล่นวิดีโอ",
        "休息": "การพัก",
        "通用": "ทั่วไป",
        "外观": "ลักษณะที่ปรากฏ",
        "关于": "เกี่ยวกับ",
        "已暂停：正在开会": "หยุดชั่วคราว: กำลังประชุม",
        "已暂停：%@ 全屏中": "หยุดชั่วคราว: %@ เต็มหน้าจออยู่",
        "%@ 后开始短休息，%@": "พักสั้นในอีก %@ นาน %@",
        "%@ 后开始长休息，%@": "พักยาวในอีก %@ นาน %@",
        "休息延后 %d 分钟": "เลื่อนพัก %d นาที",
        "break.short.ending": "ใกล้เสร็จแล้ว",
        "break.holdToSkip": "กด %@ ค้างเพื่อข้าม", "key.space": "Space", "break.short.hint": "มองไปไกลๆ",
        "短休息时长": "ระยะเวลาพักสั้น",
        "长休息时长": "ระยะเวลาพักยาว",
        "在程序坞显示": "แสดงใน Dock",
        "暂停范围": "การพักที่หยุดชั่วคราว",
        "仅短休息": "เฉพาะพักสั้น",
        "所有休息": "การพักทั้งหมด",
        "预览休息界面": "ดูตัวอย่างหน้าจอพัก",
        "生效条件": "หยุดเมื่อ",
        "添加应用": "เพิ่มแอป",
        "编辑": "แก้ไข",
        "删除时段": "ลบช่วงเวลา",
        "添加": "เพิ่ม",
        "设置": "การตั้งค่า",
        "暂停提醒 1 小时": "หยุดเตือน 1 ชั่วโมง",
        "恢复提醒": "เตือนต่อ",
        "添加提醒时段": "เพิ่มช่วงเวลาเตือน",
        "添加免打扰时段": "เพิ่มช่วงเวลาห้ามรบกวน",
        "这些时段内不提醒休息，即使落在提醒时段内。": "Pausa จะไม่เตือนให้พักในช่วงเวลาเหล่านี้ แม้จะอยู่ในช่วงเวลาเตือนก็ตาม",
    ]
}
