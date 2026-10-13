# Pausa

为中文工作环境做的 macOS 休息提醒：开会、全屏时不打扰，到点轻轻提醒。当前阶段只给自己用。

## 安装 / Install

### 中文

1. 从 [Releases](https://github.com/debidong/pausa/releases) 下载最新的 `Pausa-x.y.z.dmg`，打开后把 Pausa 拖进「应用程序」。
2. 第一次打开时，macOS 会提示无法验证开发者，并拦下它。这是因为 Pausa 没有使用 Apple 开发者证书签名。
3. 打开「系统设置 › 隐私与安全性」，滚到「安全性」部分，点击 Pausa 旁边的「仍要打开」，再确认一次。

   <!-- TODO: 截图 docs/images/open-anyway.png -->

之后 Pausa 就能正常打开，后续版本会自动更新，不用再重复这一步。

### English

1. Download the latest `Pausa-x.y.z.dmg` from [Releases](https://github.com/debidong/pausa/releases), open it, and drag Pausa to Applications.
2. The first time you open it, macOS blocks it because the developer can't be verified. Pausa isn't signed with an Apple Developer certificate.
3. Open **System Settings › Privacy & Security**, scroll to **Security**, click **Open Anyway** next to Pausa, and confirm.

   <!-- TODO: screenshot docs/images/open-anyway.png -->

After that, Pausa opens normally. Later versions update automatically, so you only do this once.

发布流程见 / For releases, see `docs/release.md`.

## 许可 / License

Pausa 可以免费使用，包括在工作中使用。不能用 Pausa 的代码做与它竞争的产品。详见 [LICENSE](LICENSE)（PolyForm Shield 1.0.0）。

Pausa is free to use, including at work. You may not use its code to build a competing product. See [LICENSE](LICENSE) (PolyForm Shield 1.0.0).
