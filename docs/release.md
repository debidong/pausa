# Pausa 发布与自动更新

这篇文档说明 Pausa 怎么发布新版本，以及老用户怎么自动收到更新。

## 一、原理

Pausa 用 [Sparkle](https://sparkle-project.org) 做自动更新。流程很简单：

1. App 每 24 小时读一次更新清单 `https://debidong.github.io/pausa/appcast.xml`。
2. 清单里写着最新版本号和安装包地址，安装包放在 GitHub Releases。
3. 每个安装包都带一个 EdDSA 签名。App 内置公钥，签名对不上就拒绝安装。

我们没有 Apple Developer ID，所以 App 只做临时签名（`codesign -s -`），也不做公证。后果只有一个：用户第一次打开时会被 macOS 拦下，需要手动放行一次（见 README 的「安装」一节）。之后的自动更新不受影响，因为更新的真假靠 EdDSA 签名判断，不靠苹果证书。

## 二、怎么发布

推送一个以 `v` 开头的 tag 即可。

```bash
git tag v0.2.0
git push origin v0.2.0
```

工作流 `.github/workflows/release.yml` 依次执行：构建并临时签名 → 打 zip 和 dmg → 创建 GitHub Release（dmg 给首次安装，zip 给自动更新） → 用 EdDSA 签名 → 更新 gh-pages 上的 `appcast.xml`。

版本号取自 tag（`v0.2.0` 变成 `0.2.0`），构建号取自提交总数，保证每次都比上次大。

## 三、唯一的密钥：SPARKLE_ED_PRIVATE_KEY

整个流程只需要一个 secret。下面的步骤都在你自己的 Mac 上做，私钥不经过任何其他人。

**第一步，生成密钥。** 在仓库目录执行：

```bash
scripts/generate-keys.sh
```

它调用 Sparkle 自带的 `generate_keys`。私钥存进你的登录钥匙串，屏幕上打印公钥。

**第二步，填公钥。** 打开 `App/Info.plist`，把 `SUPublicEDKey` 的值 `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` 换成刚才打印的公钥，然后提交。公钥是公开的，放进仓库没问题。

**第三步，导出私钥并添加 secret。** 上面的脚本会顺便把私钥导出到 `sparkle_ed_private_key.txt`。打开 GitHub 仓库 → Settings → Secrets and variables → Actions → New repository secret，名称填 `SPARKLE_ED_PRIVATE_KEY`，内容贴这个文件的全文。

**第四步，备份，然后删除文件。** 把私钥存进密码管理器或离线 U 盘，再删掉 txt 文件。千万不要提交到仓库。

为什么备份这么重要？已经装好的 Pausa 只认这一把钥匙。私钥一旦丢失，新版本就签不出老用户认可的签名，所有老用户都收不到更新，只能手动重新下载。钥匙串里那份是一个备份，但换电脑、重装系统时很容易丢，所以要再存一份。

secret 没有设置时，工作流会在第一步报错退出，不会发出一个没签名的版本。

## 四、开启 GitHub Pages

更新清单放在 gh-pages 分支上，需要开启 Pages 一次：

仓库 → Settings → Pages → Build and deployment → Source 选 **Deploy from a branch** → 分支选 **gh-pages**，目录选 **/ (root)** → Save。

gh-pages 分支在第一次发布时由工作流自动创建。所以顺序是：先发布一次，再来这里选分支。

另外，仓库需要是公开的，否则用户下载不到安装包。

## 五、手动发布（备用）

不走 CI 时，在 Mac 上执行（私钥从钥匙串读取）：

```bash
VERSION=0.2.0 BUILD=42 App/build-app.sh
ditto -c -k --sequesterRsrc --keepParent build/Pausa.app build/Pausa-0.2.0.zip
scripts/update-appcast.sh build/Pausa-0.2.0.zip 0.2.0 42 \
  https://github.com/debidong/pausa/releases/download/v0.2.0/Pausa-0.2.0.zip appcast.xml
```

然后把 zip 传到 Release，把 `appcast.xml` 提交到 gh-pages 分支。

## 六、发布说明模板

每个版本的发布说明末尾都加上这一段：

> **系统要求**：macOS 13 或更新版本。安装包是通用二进制，同时支持 Apple 芯片和 Intel 芯片的 Mac。
>
> 注意：Intel Mac 未经实机测试。如果遇到问题，请提交 Issue。

## 七、第一次发布前的检查

- [ ] `SUPublicEDKey` 已经换成真实公钥。
- [ ] `SPARKLE_ED_PRIVATE_KEY` 已添加，私钥已备份。
- [ ] `lipo -archs build/Pausa.app/Contents/MacOS/Pausa` 输出 `x86_64 arm64`。
- [ ] 第一次发布后，Pages 已指向 gh-pages / (root)，`https://debidong.github.io/pausa/appcast.xml` 能打开。
