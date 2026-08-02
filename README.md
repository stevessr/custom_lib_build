<p align="center">
  <img src="assets/arch-lib-icon.png" alt="arch_lib 图标" width="160">
</p>

<h1 align="center">arch_lib</h1>

<p align="center">面向 Arch Linux 的可直接安装二进制软件包仓库</p>

将 AUR 包转换为可直接安装的 Arch Linux 二进制包，所有包集中发布到 GitHub Release 的 `latest` 版本，使用 GitHub Actions 每日自动更新。

## 特性

- **Matrix 并行构建** — 每个包独立 job，并行加速，互不影响
- **`-git` 包跳过** — 通过 `git ls-remote` 查询上游 HEAD commit hash，未变则跳过构建
- **统一 pacman Release** — 所有当前包文件、签名和数据库集中在 `latest` Release
- **GPG 签名可选** — 支持对包进行签名，配置后自动生成 `.sig`
- **产物体积保护** — 使用 zstd level 19 压缩 `.pkg.tar.zst`，并在上传前拒绝超过 GitHub Release 单资产上限的包
- **每日自动更新** — UTC 00:00 定时运行，也可手动触发

## 工作原理

```
packages.txt ──▶ prepare ──▶ build (matrix, 调 build-package.yaml)
                              ├── flutter-bin ──▶ Actions artifact
                              ├── yay          ──▶ Actions artifact
                              └── ...          ──▶ Actions artifact
                                              │
                                              ▼
                              publish ──▶ repo-add ──▶ Release latest
```

1. **prepare** — 解析 `packages.txt` 生成 matrix
2. **build** — 每个包并行构建并上传 Actions artifact；`-git` 包先检查上一次 `latest` 的元数据，未变则复用旧包
3. **publish** — 下载所有 artifact，`repo-add` 生成 pacman 仓库数据库，上传数据库、公钥、元数据及当前版本包文件到 `latest` Release


## 快速开始

### 1. Fork 本仓库

### 2. 配置要构建的包

编辑 `packages.txt`，每行一个包名：

```txt
# 常规包 — 每次重建
antigravity

# -git 包 — 仅 commit hash 变化时才重建
waybar-git

# 自定义 PKGBUILD 包（npm 等，见 custom-pkgs/）
claude-code
cscience
```

### 自定义 PKGBUILD（custom-pkgs/）

AUR 之外的软件可以在 `custom-pkgs/<包名>/PKGBUILD` 提供自定义构建脚本，构建时优先于 AUR 使用：

```
custom-pkgs/
├── claude-code/PKGBUILD   # Claude Code for Node.js（从 CometixSpace/claude-code Release 获取）
└── cscience-bin/PKGBUILD  # Claude Science BYOK（从 Haleclipse/cscience Release 获取，需 bun）
```

自定义包使用 `pkgver()` 动态获取最新版本号，从上游 GitHub Release 直接下载原生 tarball 构建，无需 npm。

### 3. 安装包

**方式一：作为 pacman 仓库（推荐）**

编辑 `/etc/pacman.conf`，添加汇总仓库：

```ini
[arch_lib]
SigLevel = Optional TrustAll
Server = https://你的用户名.github.io/arch_lib/releases/download/latest
```

然后直接安装：

```bash
sudo pacman -Sy
sudo pacman -S 包名
```

**方式二：单独下载某个包**

所有包文件也在 `latest` Release 中：

```bash
gh release download latest --repo 你的用户名/arch_lib --pattern '包名-*.pkg.tar.zst'
sudo pacman -U 包名-*.pkg.tar.zst
```

## `-git` 包跳过逻辑

对于名称以 `-git` 结尾的包，构建脚本会：

1. 克隆 AUR 仓库（仅 PKGBUILD），提取其中的 `git+` 源码 URL
2. 通过 `git ls-remote` 查询上游仓库当前 HEAD 的 commit hash
3. 从 `latest` Release 下载 `version-<包名>.txt` 和 `manifest-<包名>.txt`
4. 如果相同 → **跳过构建**，从 `latest` 复用清单中的旧包
5. 如果不同 → 正常构建并上传新的 Actions artifact

**不下载源码、不编译**，只做一次轻量远程查询，非常适合每日定时任务。

## GPG 签名（可选）

### 仓库所有者：启用签名

**一键配置**（需要已登录的 `gh` CLI，对仓库有 contents + secrets 权限）：

```bash
bash scripts/generate-signing-key.sh [owner/repo]
```

脚本自动完成：
1. 生成无口令 GPG 密钥对（RSA 4096）
2. `gh secret set GPG_PRIVATE_KEY` — 私钥写入 GitHub Secret
3. `gh commit/push` — 公钥 `arch_lib.pub.asc` 提交到仓库
4. `pacman-key --add + --lsign-key` — **同时导入本地 pacman 密钥环**（`/etc/pacman.d/gnupg`）并信任

之后每次构建会自动对包文件生成 `.sig` 签名。

> **注意**：pacman 使用独立密钥环 `/etc/pacman.d/gnupg`，与用户级 gpg 钥匙圈无关；自生成密钥从未上传 keyserver，pacman 远程查找必然失败，必须在本地导入并本地签名信任。

### 用户：验证签名

**方式一：安装 custom-keyring 包（推荐）**

项目提供单独的 `custom-keyring` 包（每日自动构建），一键导入公钥到 pacman 密钥环并信任：

```bash
# 下载并安装 keyring 包（tag = custom-keyring）
gh release download custom-keyring --repo 你的用户名/arch_lib --pattern '*.pkg.tar.zst'
sudo pacman -U custom-keyring-*.pkg.tar.zst

# 填充 pacman 密钥环（导入公钥 + 本地信任指纹）
sudo pacman-key --populate arch_lib
```

然后在 `/etc/pacman.conf` 启用严格签名：

```ini
[arch_lib]
SigLevel = Required DatabaseOptional
Server = https://你的用户名.github.io/arch_lib/releases/download/latest
```

**方式二：手动导入**

```bash
# 下载公钥
curl -fsSL https://github.com/你的用户名/arch_lib/releases/download/latest/arch_lib.pub.asc | sudo pacman-key --add -
# 本地签名信任
sudo pacman-key --lsign-key arch-lib@localhost

# 安装时验证
sudo pacman -U 包名-版本-架构.pkg.tar.zst
```

导入后在 `/etc/pacman.conf` 中可启用严格签名：

```ini
[arch_lib]
SigLevel = Required DatabaseOptional
Server = https://你的用户名.github.io/arch_lib/releases/download/latest
```

- `Required`：包必须带有效签名
- `DatabaseOptional`：数据库签名可选（首次可先用 `DatabaseOptional`，后续改为 `Required`）

未配置密钥的仓库（无 `.sig` 文件）请继续使用 `SigLevel = Optional TrustAll`。

## 产物大小与大文件分发

单包构建脚本会为它调用的每次 `makepkg` 生成临时配置，使用多线程 zstd level 19 压缩包文件。这样不会修改 runner 的 `/etc/makepkg.conf`，也不会覆盖用户已有的 makepkg 配置。需要在压缩时间和体积之间取舍时，可将 `PACKAGE_ZSTD_LEVEL` 设置为 1–19。

GitHub Release 的单个资产约有 2 GiB 上限。脚本默认用 `MAX_RELEASE_ASSET_BYTES=2147483648` 做预检，超限会在上传前明确失败，而不是让 `softprops/action-gh-release` 在发布阶段失败。聚合仓库下载还启用了重试和断点续传，临时网络中断不会从头下载整个包。

不要直接用 `split` 把 `.pkg.tar.zst` 拆成多个 Release 资产：pacman 和 `repo-add` 需要完整、原子性的包文件，分片不能直接安装。压缩后仍超限时，应在对应 PKGBUILD 中拆成多个 pacman split packages（`pkgname=(...)`，分别实现 `package_*()`），或移除不需要的内容；不要把不可安装的分片放进 `latest` 仓库。

## 手动触发构建

在 GitHub 仓库的 **Actions → Build AUR Repository → Run workflow** 中可随时手动触发完整构建并更新 `latest`。`Manual Build Package` 仅生成单包 Actions artifact，不会创建独立软件包 Release。
```
arch_lib/
├── .github/workflows/
│   ├── build-repo.yaml        # 调度器：prepare + matrix + publish 汇总
│   ├── build-package.yaml     # 可复用：单包构建 + 上传 Actions artifact
│   ├── build-keyring.yaml     # 构建 custom-keyring 密钥环包
│   └── manual-build.yaml      # 手动触发单包构建
├── scripts/
│   ├── build-package.sh       # 单包构建脚本（含 -git 跳过逻辑 + custom PKGBUILD）
│   ├── generate-signing-key.sh # 一键生成签名密钥（自动导入 pacman 密钥环）
│   ├── gc-releases.sh         # 旧包 Release 清理工具（迁移后不再自动调用）
│   └── pre-build/             # 包级预构建钩子（可选）
├── assets/                    # 项目标识
│   └── arch-lib-icon.png      # GitHub 仓库头像/社交预览用 PNG
├── custom-pkgs/              # 自定义 PKGBUILD（优先于 AUR）
│   ├── claude-code/PKGBUILD  # 从 CometixSpace/claude-code Release 下载
│   └── cscience-bin/PKGBUILD # 从 Haleclipse/cscience Release 下载（原生 Bun）
├── packages.txt              # 要构建的包列表（AUR 或 custom-pkgs）
├── arch_lib.pub.asc          # 签名公钥占位
└── README.md
```

**汇总仓库**（tag = `latest`）— pacman 数据库、公钥、元数据及**当前版本的所有包文件**（扁平，供 `Server = …/releases/download/latest` 直接安装；每次发布先删旧建新，不累积旧版本）：

```
latest/
├── arch_lib.db / arch_lib.db.tar.gz   # pacman 仓库数据库
├── arch_lib.files / arch_lib.files.tar.gz
├── arch_lib.pub.asc                   # GPG 签名公钥
├── <pkg>-<ver>-x86_64.pkg.tar.zst     # 当前版本包（含 .sig）
├── version-<pkg>.txt                  # 上次版本/commit 记录
├── manifest-<pkg>.txt                 # 该输入包对应的文件清单
└── …
```

不再为普通软件包创建或更新独立 Release；`latest` 是唯一的 pacman 软件包来源。`custom-keyring` 仍使用独立 Release，便于首次安装密钥环。

## 自定义

### 添加/删除包

编辑 `packages.txt`，提交到 `main` 分支即可。

### 修改构建频率

编辑 `.github/workflows/build-repo.yaml` 中的 `cron` 表达式：

```yaml
schedule:
  - cron: '0 6 * * *'   # 每天 UTC 06:00
```

### 调整并行度

```yaml
strategy:
  max-parallel: 10
```

## 预构建钩子（Pre-build hooks）

某些 AUR 包的 PKGBUILD 有 bug（如安装脚本依赖当前目录、缺失编译依赖等）。
可以在 `scripts/pre-build/<包名>.sh` 添加钩子，在 `makepkg` 前执行：

```bash
#!/bin/bash
# scripts/pre-build/<包名>.sh
# 参数：$1=包目录  $2=包名
PKG_DIR="$1"
echo "自定义构建准备..."
# 例如：预下载缺失的二进制
# curl -fsSL https://example.com/binary -o "$PKG_DIR/src/binary"
```

## License

MIT
