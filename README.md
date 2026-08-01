# arch_lib

将 AUR 包转换为可直接安装的 Arch Linux 二进制包，每个包独立发布到 GitHub Release，使用 GitHub Actions 每日自动更新。

## 特性

- **Matrix 并行构建** — 每个包独立 job，并行加速，互不影响
- **`-git` 包跳过** — 通过 `git ls-remote` 查询上游 HEAD commit hash，未变则跳过构建
- **每包独立 Release** — 每个包有自己的 Release tag（包名），每次构建覆盖更新
- **GPG 签名可选** — 支持对包进行签名，配置后自动生成 `.sig`
- **每日自动更新** — UTC 00:00 定时运行，也可手动触发

## 工作原理

```
packages.txt ──▶ prepare ──▶ build (matrix, 调 build-package.yaml)
                              ├── flutter-bin ──▶ Release flutter-bin
                              ├── yay          ──▶ Release yay
                              └── ...          ──▶ Release ...
                                              │
                                              ▼
                              publish ──▶ repo-add ──▶ Release latest (汇总数据库)
```

1. **prepare** — 解析 `packages.txt` 生成 matrix
2. **build** — 每个包并行构建（可复用工作流 `build-package.yaml`），直接上传到自己的 Release（tag = 包名，覆盖更新）；`-git` 包先检查上游 commit hash，未变则跳过
3. **publish** — 从每个包的 Release 下载产物，`repo-add` 生成 pacman 仓库数据库，上传数据库及公钥到 `latest` Release（不重复包含软件包构建产物）；完成后自动触发 GC 清理同一个软件包的老旧 Release

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

每个包在 Releases 页面有独立 Release（tag = 包名）：

```bash
gh release download yay --repo 你的用户名/arch_lib --pattern '*.pkg.tar.zst'
sudo pacman -U *.pkg.tar.zst
```

## `-git` 包跳过逻辑

对于名称以 `-git` 结尾的包，构建脚本会：

1. 克隆 AUR 仓库（仅 PKGBUILD），提取其中的 `git+` 源码 URL
2. 通过 `git ls-remote` 查询上游仓库当前 HEAD 的 commit hash
3. 从该包的上一个 Release 下载 `version.txt` 对比
4. 如果相同 → **跳过构建**，旧 Release 保持不变
5. 如果不同 → 正常构建，发布新版本

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

## 手动触发构建

在 GitHub 仓库的 **Actions → Build AUR Repository → Run workflow** 中可随时手动触发。

## 文件结构

```
arch_lib/
├── .github/workflows/
│   ├── build-repo.yaml        # 调度器：prepare + matrix + publish 汇总
│   ├── build-package.yaml     # 可复用：单包构建 + 上传到包名 Release
│   ├── build-keyring.yaml     # 构建 custom-keyring 密钥环包
│   └── manual-build.yaml      # 手动触发单包构建
├── scripts/
│   ├── build-package.sh       # 单包构建脚本（含 -git 跳过逻辑 + custom PKGBUILD）
│   ├── generate-signing-key.sh # 一键生成签名密钥（自动导入 pacman 密钥环）
│   ├── gc-releases.sh         # 自动 GC 清理老旧/重复软件包 Release 脚本
│   └── pre-build/             # 包级预构建钩子（可选）
├── custom-pkgs/              # 自定义 PKGBUILD（优先于 AUR）
│   ├── claude-code/PKGBUILD  # 从 CometixSpace/claude-code Release 下载
│   └── cscience-bin/PKGBUILD # 从 Haleclipse/cscience Release 下载（原生 Bun）
├── packages.txt              # 要构建的包列表（AUR 或 custom-pkgs）
├── arch_lib.pub.asc          # 签名公钥占位
└── README.md
```

## Release 产物结构

**汇总仓库**（tag = `latest`）— pacman 数据库及公钥（构建产物已放在各软件包单独 Release 中，无需重复包含）：

```
latest/
├── arch_lib.db.tar.gz           # pacman 仓库数据库
├── arch_lib.db
├── arch_lib.files.tar.gz
├── arch_lib.files
└── arch_lib.pub.asc             # GPG 签名公钥
```

**单包 Release**（tag = 包名）— 单独分发：

```
yay/
├── yay-12.4.2-1-x86_64.pkg.tar.zst
├── yay-12.4.2-1-x86_64.pkg.tar.zst.sig  # 如配置签名
└── version.txt                  # 版本号（用于 -git 跳过检查）
```

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