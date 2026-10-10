# Pausa（macOS）产品设计文档 v0.4

> 状态：草稿，待 Bowen 审阅。技术可行性一节由 Linus 补充。
> 范围：只做 macOS，暂不做 iPhone、iPad 同步。

## 1. 产品定位

一句话：在不打断工作的前提下，按时提醒用户休息眼睛、起身活动。

核心承诺是“不打扰”，不是“定时提醒”。用户卸载同类应用，最常见的原因是在会议、录屏或演示时被打断。因此第一版的所有取舍都服从一个指标：**误打扰率**。

不做的事：不宣称保护视力或预防近视；不做健康数据统计和打卡排行。

## 1.5 竞争优势

| 对比对象 | Pausa 的优势 |
|---|---|
| 收费成熟竞品（LookAway、Time Out） | 默认识别腾讯会议、飞书、钉钉、企业微信；中文文案与本地付款；比 Time Out 上手快（首次启动三步） |
| 开源竞品（Stretchly、BreakTimer） | 原生应用，常驻占用小、省电（上线前实测给出数字）；会议、全屏等自动暂停能力强得多；视觉与交互符合 macOS |
| 全部竞品 | 隐私讲清楚：不用摄像头、不联网、不收集数据，权限逐条说明；健康说法克制，每个默认设置都有依据 |

待核实：LookAway 是否显示暂停原因。核实前，“显示暂停原因”只作为基本功能，不作为卖点。

不比的：功能数量、跨设备同步。

## 2. 目标用户

- 每天在 Mac 前工作 6 小时以上的开发者、设计师和远程办公人员。
- 已经有眼疲劳或久坐的困扰，试过定时器，但因为被打断而放弃。

## 3. 竞品取舍

| 竞品 | 借鉴 | 避免 |
|---|---|---|
| LookAway | 自动暂停、预告提醒、跟随鼠标的倒计时、原生体验 | 功能铺得过广，设置项多 |
| Time Out | 按应用、日历、专注模式、全屏设规则；离开电脑的时间计入休息 | 规则配置复杂 |
| Stretchly | 默认每 10 分钟休息 20 秒、每 30 分钟休息 5 分钟；只能推迟一次；空闲 5 分钟自动暂停 | 界面不像原生 macOS 应用 |
| BreakTimer | 工作时段设置、休息前预告 | 智能暂停能力弱 |

注：Time Out、Stretchly、BreakTimer 的信息已由 Linus 对照官网核实；LookAway 的“避免”一栏是产品判断。

**借鉴决定**：锁屏、合盖、屏幕睡眠算真正离开，可同时抵扣短休息和长休息；仅键盘鼠标空闲只抵扣长休息，因为用户可能仍在看屏幕；增加工作时段设置，下班时间不提醒。

## 4. 默认参数（依据华佗的健康建议）

| 类型 | 频率 | 时长 | 内容 |
|---|---|---|---|
| 短休息 | 每 20 分钟 | 20 秒 | 鼠标旁小胶囊加屏幕轻微变暗，引导看远处、眨眼；不全屏，不抢焦点 |
| 长休息 | 每 50 分钟 | 3 分钟 | 起身走动，离开屏幕 |
| 眨眼提醒 | 可选，默认关闭 | 轻提示 | 不全屏，不发声 |

## 5. 核心流程

1. 计时到点前 30 秒：菜单栏图标变色，鼠标旁出现小型倒计时。
2. 到点时检查当前状态：
   - 处于需要暂停的场景（见第 6 节）：不弹提醒，菜单栏显示暂停原因，场景结束后再提醒。
   - 用户正在输入或操作：最多等待 30 秒，直到键盘和鼠标空闲后再进入休息。
3. 进入休息：短休息用鼠标旁小胶囊加屏幕轻微变暗；长休息用全屏柔和遮罩，显示倒计时和一句引导文案。
4. 休息结束：遮罩淡出，重新计时。

## 6. 自动暂停

第一版需要覆盖的场景：

- 视频会议或通话（麦克风或摄像头正在使用）
- 屏幕录制或屏幕共享
- 全屏视频播放
- 全屏游戏或全屏演示
- 用户自定义的专注应用名单

**暂停原因必须可见**：菜单栏下拉中显示“已暂停：正在会议中”。用户能看到它为什么没有打扰自己，才会信任这个功能。

**各场景的判断方式与显示文案**：
- 开会：检测麦克风或摄像头占用，只显示“正在开会”，无法显示具体应用；只听不说的会议靠会议应用名单补充。
- 全屏：默认只对视频、游戏和演示暂停。全屏写代码等工作照常提醒，可在设置里改。
- 录屏：系统无法直接检测，只能靠录屏应用名单，因此文案如实写“OBS 正在运行”，不写“正在录屏”。

**权限原则**：不需要系统权限的检测默认开启；需要屏幕录制、辅助功能等权限的检测放在设置里，由用户自己选择开启，并说明用途。

## 7. 推迟与跳过

- 推迟：在预告阶段或休息页中可推迟 1 分钟或 5 分钟，连续推迟最多 2 次。
- 跳过：休息页可跳过本次。跳过不弹窗、不说教，只在菜单栏的今日记录里显示。
- 紧急退出：快捷键立即结束本次休息，不设门槛。
- 休息页无法真正锁定电脑（Cmd+Tab、强制退出仍可用）。不做“强制锁屏”的承诺；可选的严格模式只延迟显示跳过按钮、减少推迟次数。

## 8. 界面清单

| 界面 | 要点 |
|---|---|
| 菜单栏 | 状态图标、下次休息时间、暂停原因、立即休息、暂停一小时 |
| 预告 | 鼠标旁小型倒计时，可点穿，不抢焦点 |
| 休息页 | 全屏覆盖所有显示器；倒计时、引导文案、推迟和跳过按钮 |
| 设置 | 休息节奏、自动暂停、外观、快捷键，四个分区 |
| 首次启动 | 没有向导：打开即开始计时；权限在首次需要时再请求（如首次开会时） |

## 9. 文案原则

- 写具体动作，不写空泛口号：“看看窗外 20 秒”“站起来走一走”。
- 不写“保护视力”“防近视”“告别头痛”等疗效说法。
- 语气平和，不用感叹号，不制造焦虑。

## 9.5 视觉与交互方向

设计原则：安静、克制、像系统自带的应用。用户感觉不到它在“设计”，只觉得舒服。

- **克制**：只有一种强调色，其余用系统灰阶。界面上的每个元素都要有存在的理由，宁可少一个按钮。
- **原生**：毛玻璃材质、SF Symbols 图标、系统字体与弹簧动画，深色和浅色模式自动跟随系统。
- **休息页**：不用大面积亮白。底色用柔和的深色渐变或模糊后的桌面，一行大字引导动作，倒计时用细圆环。进入和退出都用约 1 秒的渐变，夜间自动调暗。
- **预告**：鼠标旁的小胶囊，只显示数字和一个细进度环，不抢焦点。
- **菜单栏图标**：一个会随剩余时间慢慢“填满”的小圆，暂停时变为空心并显示原因。
- **无障碍**：尊重“减弱动态效果”和“增强对比度”设置；文字对比度满足 WCAG AA。
- **参考气质**：Things 3 的留白、Apple 健康“正念”应用的呼吸动画、Raycast 的精确感。

## 9.6 v0.3 修订（Mitchell、Guillermo 意见）

- 全屏遮罩只用于长休息。
- 会议结束后留 2 分钟缓冲再提醒；默认排除 Loopback、BlackHole 等虚拟音频设备。
- 状态模型：工作中、预告、休息中、已暂停（带原因集合，菜单栏显示优先级最高的原因）。
- 用单调时钟计时；睡眠、合盖期间算作离开电脑，唤醒后重新计时，不弹过期休息。
- 只在菜单栏，不出现在 Dock；SMAppService 开机自启；Cmd+, 打开设置；休息结束后焦点回到原窗口。
- 收费：免费版包含完整的自动暂停（含国内会议识别），因为“不打扰”是核心承诺，不能放进付费墙；Pro 一次性买断，包含自定义规则、统计、外观主题。价格待 Guillermo 核实竞品定价后定。
- 发布：Homebrew cask 加官网下载；种子用户来自 V2EX、即刻、少数派、小红书和 GitHub；核心计时开源。

## 9.7 v0.4 修订（华佗、Mitchell 意见）

- 文案不写“20 英尺”，写“看看 6 米外”或“看看窗外”。
- “关于”页加一句：眼睛持续疼痛、视力变化或长期干涩，请就医，Pausa 不能替代检查。
- 多显示器：任一屏幕处于需暂停的全屏场景时，整体暂停，不分屏处理，规则简单可预期。
- 第一版通过专注模式过滤器（Focus Filters）支持“跟随专注模式”：用户在系统设置里绑定后，该专注模式下暂停提醒。不需要授权，待真机验证。
- “打开即用、零授权”是否成立，取决于技术清单第 1 项和第 16 项的真机验证；验证前不对外宣传。

## 10. 第一版范围

**做**：短休息、长休息、预告、自动暂停及原因显示、推迟和跳过、菜单栏、设置、首次启动、开机自启。

**往后放**：眨眼和坐姿提醒的高级形态、自定义声音和背景、AppleScript 与快捷指令、iPhone 和 iPad 同步、统计报表。

## 11. 成功指标

- 误打扰率：用户在提醒后 3 秒内跳过的比例。
- 7 日留存率。
- 平均每天完成的休息次数。

## 12. 待定问题

1. 收费模式：一次性买断、订阅，还是免费加高级功能？
2. 分发渠道：建议第一版走官网下载（苹果公证、Sparkle 自动更新）加 Homebrew；App Store 等真机验证沙盒限制后再定。
3. 产品名称：暂定 Pausa，待商标和同名应用核查。

## 13. 技术可行性（Linus）

# 智能休息提醒（macOS）技术可行性

范围：只做 macOS，不做 iPhone/iPad 同步。下面每一项都写了：怎么检测、用什么接口、要什么权限、准不准、哪些做不到。
链接都在 2026-10-10 打开核对过（Apple 文档用 developer.apple.com 的 JSON 接口确认存在）。标了「推断」的地方是我根据接口行为推出来的，没有在真机上测过。

## 结论先说

- 核心的几个信号（开会、视频、全屏、空闲、锁屏）**都不需要弹系统权限框**，用公开接口就能做。
- 唯一麻烦的是「正在录屏 / 共享屏幕」：没有公开接口能直接问「有没有别人在录屏」，只能间接猜。
- 建议用原生 Swift（SwiftUI + AppKit），走「公证 + 官网直装 + Sparkle 自动更新」，最低支持 macOS 13。App Store 版可以以后再说，沙盒会限制一部分检测。

## 1. 各个自动暂停信号

### 1.1 开会 / 通话（麦克风或摄像头正在被用）
- **方法**：
  - 麦克风：遍历 CoreAudio 输入设备，读 `kAudioDevicePropertyDeviceIsRunningSomewhere`，并注册属性监听，变化时回调。
    https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertydeviceisrunningsomewhere
  - 摄像头：CoreMediaIO 的同名属性 `kCMIODevicePropertyDeviceIsRunningSomewhere`。
    https://developer.apple.com/documentation/coremediaio
  - 实际例子：Objective-See 的 OverSight 就是这么监控麦克风和摄像头的（源码 `AVMonitor.m` 里用了 `kAudioDevicePropertyDeviceIsRunningSomewhere`）。https://github.com/objective-see/OverSight
- **权限**：只读设备状态，**不需要**麦克风/摄像头权限，不弹 TCC 框，沙盒里也能用（推断：只查询属性，不打开音频流）。
- **准确度**：「有人在用麦克风/摄像头」很准，几乎是实时的。
- **误判**：
  - 误暂停：语音输入、听写、Siri、某些常驻的录音工具、虚拟音频设备（如 Loopback、BlackHole）一直开着，都会被当成开会。需要允许用户把某个设备排除掉，再加一个「持续超过 N 小时就提示一下」的保护。
  - 漏判：只听不说、麦克风和摄像头都关着的会议（比如纯旁听网络研讨会）检测不到。可以用 1.4 的「前台应用名单」（Zoom、腾讯会议、飞书会议、Teams）补上。
- **做不到**：公开接口查不出**是哪个应用**在用麦克风。OverSight 是靠解析系统日志定位进程的，这种方法脆弱，不建议照搬。菜单栏写「正在开会」就够了，不写具体应用。
- 可选补充：读日历判断「现在在会议时间里」（EventKit，**会弹日历权限框**）。MeetingBar 就是靠日历做的：https://github.com/leits/MeetingBar 。建议放到以后，MVP 不做。

### 1.2 录屏 / 共享屏幕
- **现实情况**：没有公开接口能问「系统里现在有没有别的应用在录屏」。ScreenCaptureKit（https://developer.apple.com/documentation/screencapturekit ）是给**自己**录屏用的，不能用来查别人。
- **可行的间接办法**（按可靠程度排）：
  1. 前台或正在运行的应用在名单里：QuickTime、OBS、CleanShot、Loom、ScreenFlow、Kap 等（`NSWorkspace.runningApplications` / `frontmostApplication`，不需要权限）。
     https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication
  2. 共享屏幕基本都伴随开会，1.1 的麦克风/摄像头信号已经覆盖了大部分情况。
  3. macOS 14 以后菜单栏会出现紫色的录屏指示图标，理论上可以用 `CGWindowListCopyWindowInfo` 找到这个系统窗口（推断，未验证；而且从 macOS 10.15 起读其他应用窗口的名字需要屏幕录制权限，会弹框，不值得）。
- **权限**：方法 1、2 不需要权限。
- **误判**：OBS 开着但没在录也会暂停（误暂停）；名单里没有的录屏工具检测不到（漏判）。
- **做不到**：准确判断「正在录」，而不只是「录屏软件开着」。在菜单栏写清楚原因（「OBS 正在运行」），让用户自己能看懂、能一键关掉这条规则。

### 1.3 看视频
- **方法**：读电源管理的「阻止显示器睡眠」断言。浏览器、QuickTime、IINA、VLC 播放视频时会创建 `PreventUserIdleDisplaySleep` 一类的断言，命令行 `pmset -g assertions` 看到的就是这个。接口在 IOKit 的 `IOPMLib.h`（`IOPMCopyAssertionsByProcess` 可以拿到是哪个进程创建的）。
  https://developer.apple.com/documentation/iokit/iopmlib_h
- **权限**：不需要，不弹框。沙盒下是否能读其他进程的断言，我没查到 Apple 的明确说明，需要真机验证。
- **误判**：
  - 误暂停：Amphetamine、caffeinate、下载工具、某些会议应用也会创建这类断言。按进程名再过滤一次。
  - 漏判：网页里静音的自动播放视频有时不创建断言（推断）；小窗看视频但在全屏以外，用户其实希望照样提醒。建议规则是「有显示器睡眠断言 **并且** 那个应用在前台或全屏」才暂停。
- **做不到**：判断视频是不是真的有人在看。

### 1.4 全屏应用 / 游戏
- **方法**：
  - `CGWindowListCopyWindowInfo` 列出屏幕上的窗口，找到前台应用的窗口，比较它的边界和所在显示器的尺寸，相等就是全屏。只读边界、层级、所属进程**不需要**屏幕录制权限（窗口标题才需要）。
    https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)
  - 前台切换用 `NSWorkspace.didActivateApplicationNotification` 监听；游戏可以用应用的 `LSApplicationCategoryType`（public.app-category.games 等）辅助判断。
- **权限**：不需要。
- **误判**：有人习惯把浏览器、IDE 全屏用，这时候用户**希望**照样被提醒。所以默认只对「游戏类 + 视频播放器 + 演示类（Keynote 放映、PowerPoint）」全屏暂停，其他全屏应用默认不暂停，可以在设置里改。
- **做不到**：区分「全屏打游戏」和「全屏写代码」只能靠应用名单，没有更聪明的办法。

### 1.5 专注类应用名单
- **方法**：`NSWorkspace.shared.frontmostApplication` 的 bundle ID 和用户名单比较。不需要权限，沙盒里可用。
- Stretchly 有现成的类似功能（`app/utils/appExclusionsManager.js`）：https://github.com/hovancik/stretchly
- **注意**：只能知道是哪个应用，不知道打开的是哪个网页或文件。「在浏览器里开着腾讯会议网页版」只能靠 1.1 的麦克风信号。

### 1.6 用户空闲 / 打字中（用来挑提醒的时机）
- **方法**：`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)`（查询全部输入类型），每秒轮询一次就够。也可以分别查键盘和鼠标。
  https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:)
- **权限**：只读空闲秒数，**不需要**辅助功能权限，也不需要输入监控权限（推断：这个接口不读按键内容；如果改用全局事件监听 `CGEventTap` 才需要，不要用）。
- **用法**：
  - 时机：到点后，等用户连续 2–3 秒没有输入再弹提示，最多再等 N 秒（比如 60 秒），超时就直接提示，避免一直打字一直拖。
  - 自然休息：空闲超过 5 分钟就算已经休息过，重置计时。Stretchly 默认也是空闲 5 分钟就暂停（README 写明），Time Out 也有「离开电脑算作自然休息」。
- **误判**：看长文章、看视频时没有输入，会被当成空闲。和 1.3 结合：有视频断言时不算空闲。

### 1.7 系统「专注模式」
- **方法**：Intents 框架的 `INFocusStatusCenter`，可以读当前**是否**处于专注模式。
  https://developer.apple.com/documentation/intents/infocusstatuscenter
- **权限**：需要用户授权读取专注状态，**会弹一次系统框**；需要 Communication Notifications 相关能力（推断，按文档要求配置）。
- **做不到**：读不出是**哪个**专注模式（工作、睡眠、勿扰）。想按模式区分，要用「专注模式过滤器」（App Intents 的 `SetFocusFilterIntent`，macOS 13+），让用户在系统设置里给某个专注模式配「暂停休息提醒」。LookAway 官网写了支持 Focus Filters，就是这个思路。
- 参考：Stretchly 在 macOS 上是读 `com.apple.controlcenter` 的 defaults 值判断的（`app/utils/dndManager.js`），而且代码注释里提到 macOS 26 上这个键的行为变了。这种做法不稳，不建议。
- **建议**：MVP 用专注模式过滤器，不弹权限框；`INFocusStatusCenter` 以后再说。

### 1.8 锁屏 / 睡眠
- **方法**：`NSWorkspace` 的 `screensDidSleepNotification` / `screensDidWakeNotification`、`willSleepNotification` / `didWakeNotification`；锁屏和解锁用分布式通知 `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`（没有正式文档，但很多应用在用，属于推断可用）。
  https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification
- **权限**：不需要。
- **处理**：锁屏或睡眠超过一次休息的时长，就当作休息过，重新计时。

### 1.9 多显示器
- **方法**：`NSScreen.screens` 列出所有显示器，监听 `NSApplication.didChangeScreenParametersNotification` 处理插拔。
- 全屏判断要按「前台窗口所在的那块屏」算，不能只看主屏。
- 跟随鼠标的倒计时：`NSEvent.mouseLocation` 轮询（不需要权限），窗口放在鼠标所在的屏。
- **待定**：一块屏全屏看视频、另一块屏在工作时要不要提醒？建议只在「当前有输入的那块屏」显示提醒，PM 来定。

## 2. 休息遮罩：覆盖所有显示器、所有桌面、包括全屏应用
- 每块屏建一个无边框 `NSWindow`/`NSPanel`，窗口层级设到 `.screenSaver` 或更高，`collectionBehavior` 加上：
  - `.canJoinAllSpaces`（所有桌面都显示）https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces
  - `.fullScreenAuxiliary`（能盖在别的应用的全屏空间上）https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary
  - `.stationary`、`.ignoresCycle`
- 应用本身设成 `LSUIElement`（只有菜单栏，没有 Dock 图标），弹遮罩时 `NSApp.activate`。
- **做不到 / 风险**：
  - 有些独占全屏的游戏（直接用 Metal 独占显示）可能盖不住，或者盖住后会掉帧。正好这类场景本来就默认暂停。
  - 不能真正「锁住」电脑：`Cmd+Tab`、强制退出、调度中心都拦不住，除非用 `NSApplication.presentationOptions` 禁用进程切换（只在自己是前台时有效）。严格模式也只能做到「按钮延迟出现」，这其实也够了（Time Out 的做法：开始几秒禁用按钮，限制推迟和跳过次数）。
- 姿势、眨眼提醒用不抢焦点的 `NSPanel`（`.nonactivatingPanel`），小卡片，不全屏。

## 3. 开机自启
- macOS 13+ 用 `SMAppService.mainApp.register()`，用户可以在「系统设置 → 通用 → 登录项」里看到和关掉，不需要 helper 应用，沙盒里也能用。
  https://developer.apple.com/documentation/servicemanagement/smappservice
- 现成封装：https://github.com/sindresorhus/LaunchAtLogin-Modern
- 注意：首次开启时系统会发一条「已添加登录项」的通知，这是系统行为，关不掉。

## 4. 分发
| | Mac App Store | 公证 + 官网直装 + Sparkle |
|---|---|---|
| 沙盒 | 必须 | 不需要 |
| 检测能力 | 麦克风/摄像头、空闲、全屏边界、前台应用应该都能用；读别的进程的电源断言（1.3）和锁屏通知在沙盒里能不能用要实测 | 全部可用 |
| 运行 AppleScript / 快捷指令 | 受限，需要临时例外权限，审核麻烦 | 可以 |
| 更新 | App Store 管 | Sparkle：https://github.com/sparkle-project/Sparkle |
| 收费 | Apple 抽成，内购简单 | 自己接 Paddle/LemonSqueezy 等 |

**建议**：先做直装版（Developer ID 签名 + 公证 + Sparkle + Homebrew cask）。LookAway 官网也写了「Install via Homebrew」。等功能稳定、确认沙盒下哪些检测能用之后，再考虑做一个能力少一点的 App Store 版。

## 5. 最低系统版本
**macOS 13 Ventura**。理由：`SMAppService`、专注模式过滤器（App Intents）、SwiftUI 的 `MenuBarExtra` 都从 13 开始有。LookAway 当前版本也要求 macOS 13+（官网写明）。

## 6. 技术栈：建议原生 Swift（SwiftUI + AppKit）
- 上面几乎每个检测都是 CoreAudio、CoreMediaIO、IOKit、CoreGraphics、NSWorkspace 这些 C/Objective-C 接口，Swift 直接调；Electron/Tauri 都要写原生插件，等于写两遍。
- 遮罩窗口要控制窗口层级和桌面行为（第 2 节），这是 AppKit 的东西，Electron 只能部分做到（`setVisibleOnAllWorkspaces`），盖全屏应用这块不稳。
- 常驻菜单栏应用要省电省内存：原生大约几十 MB，Electron 常驻一两百 MB，对一个一直开着的小工具不划算。
- 反面例子：Stretchly、BreakTimer 都是 Electron，跨平台，但在 macOS 上的自动暂停只做到了空闲和勿扰这类基础信号（Stretchly 的勿扰检测还是读 defaults）。
- 分工：设置窗口、菜单栏面板、引导页用 SwiftUI；遮罩窗口、浮动倒计时、通知卡片用 AppKit 的 `NSPanel` 包 SwiftUI 视图。

## 7. 需要真机验证的点
1. 沙盒下能不能读其他进程的电源断言（1.3）、能不能收到锁屏分布式通知（1.8）。
2. 虚拟音频设备常开时，1.1 会不会一直判成「开会」，排除规则好不好用。
3. 遮罩能不能盖住 Keynote 放映、各类游戏的独占全屏。
4. 系统录屏指示图标能不能在不要权限的情况下检测到（1.2 方法 3）。
5. 每秒轮询空闲 + 窗口列表的耗电（目标：活动监视器里能耗影响接近 0）。
