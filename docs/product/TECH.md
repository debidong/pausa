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
