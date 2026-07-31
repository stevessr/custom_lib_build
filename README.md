# arch_lib

将 AUR 包转换为可通过 `pacman` 直接安装的自托管 Arch Linux 仓库，使用 GitHub Actions 每日自动更新。

## 特性

- **Matrix 并行构建** — 每个包独立 job，并行加速，互不影响
- **`-git` 包跳过** — 对比 PKGBUILD 中 `pkgver()` 生成的 commit hash，版本未变则跳过构建
- **GitHub Releases 分发** — 构建产物发布到 Release，通过 `releases/download/latest/$arch` 直接 pacman 使用
- **每日自动更新** — UTC 00:00 定时运行，也可手动触发

## 工作原理

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  prepare    │────▶│  build (matrix)  │────▶│    publish      │
│ 读 packages │     │ 每包一个 job     │     │  repo-add +     │
│ 下载版本表  │     │ -git 跳过未变    │     │  GitHub Release │
└─────────────┘     └──────────────────┘     └─────────────────┘
```

1. **prepare** — 解析 `packages.txt` 生成 matrix，从最新 Release 下载 `last-versions.txt`
2. **build** — 每个包并行构建；`-git` 包先 source PKGBUILD 运行 `pkgver()`，若 commit hash 与上次相同则跳过
3. **publish** — 收集所有 `.pkg.tar.*` 包，`repo-add` 生成仓库数据库，覆盖创建 `latest` Release

## 快速开始

### 1. Fork 本仓库

### 2. 配置要构建的包

编辑 `packages.txt`，每行一个 AUR 包名：

```txt
# 常规包 — 每次重建
yay
paru

# -git 包 — 仅 commit hash 变化时才重建
waybar-git
hyprland-git
```

### 3. 在 Arch Linux 上使用

编辑 `/etc/pacman.conf`，在文件末尾添加：

```ini
[arch_lib]
SigLevel = Optional TrustAll
Server = https://你的用户名.github.io/arch_lib/releases/download/latest
```

> **注意**：将 `你的用户名` 替换为你的 GitHub 用户名，`arch_lib` 替换为你的仓库名。

然后同步并安装：

```bash
sudo pacman -Sy         # 刷新仓库元数据
sudo pacman -S 包名      # 安装包
```

## `-git` 包跳过逻辑

对于名称以 `-git` 结尾的包，构建脚本会：

1. 克隆 AUR 仓库（仅 PKGBUILD），提取其中的 `git+` 源码 URL
2. 通过 `git ls-remote` 查询上游仓库当前 HEAD 的 commit hash
3. 对比 `last-versions.txt` 中记录的上次构建 hash
4. 如果相同 → **跳过构建**，publish 阶段从上一个 Release 的产物中复用已构建的包
5. 如果不同 → 正常构建，更新版本记录

**不下载源码、不编译**，只做一次轻量远程查询，非常适合每日定时任务。这避免了每天重复编译没有上游更新的 `-git` 包，大幅节省构建时间。

## 手动触发构建

在 GitHub 仓库的 **Actions → Build AUR Repository → Run workflow** 中可随时手动触发。

## 文件结构

```
arch_lib/
├── .github/workflows/
│   └── build-repo.yaml        # GitHub Actions 工作流（matrix + release）
├── scripts/
│   ├── build-package.sh      # 单包构建脚本（含 -git 跳过逻辑）
│   └── pre-build/            # 包级预构建钩子（可选）
│       └── qoder-cli.sh      # 示例：修复安装脚本行为异常的包
├── packages.txt              # 要构建的 AUR 包列表
└── README.md
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

## Release 产物结构

每次构建完成后，`latest` Release 包含（每个包独立上传，避免 >2GiB 单文件限制）：

```
latest/
├── last-versions.txt           # 版本追踪文件（下次运行用于 -git 跳过判断）
├── arch_lib.db.tar.gz          # pacman 仓库数据库
├── arch_lib.db                 # 数据库（pacman 请求的另一个名字）
├── arch_lib.files.tar.gz
├── arch_lib.files
└── *.pkg.tar.zst              # 构建好的包文件（扁平上传）
```

pacman 通过 `Server = .../releases/download/latest` 访问，GitHub Release 会按数据库中的文件名提供每个包。

## 自定义

### 添加/删除包

编辑 `packages.txt`，提交到 `main` 分支即可。

### 修改构建频率

编辑 `.github/workflows/build-repo.yml` 中的 `cron` 表达式：

```yaml
schedule:
  - cron: '0 6 * * *'   # 每天 UTC 06:00
```

### 调整并行度

修改 workflow 中 `max-parallel` 的值（默认 10）：

```yaml
strategy:
  max-parallel: 10
```

## 签名与校验

仓库支持 GPG 签名（可选但推荐）。

### 仓库所有者：启用签名

**一键配置**（需要已登录的 `gh` CLI，且对仓库有 contents + secrets 权限）：

```bash
bash scripts/generate-signing-key.sh [owner/repo]
```

脚本自动完成三步：
1. 生成无口令 GPG 密钥对（RSA 4096，仅用于仓库签名）
2. `gh secret set GPG_PRIVATE_KEY` — 私钥写入 GitHub Secret
3. 用生成的公钥替换仓库根目录 `arch_lib.pub.asc` 并自动提交推送

之后每次构建，publish 阶段会自动：
- 对每个 `.pkg.tar.zst` 生成 `.sig` 签名
- `repo-add --sign` 签名数据库（`.db.sig` / `.db.tar.gz.sig`）
- 签名文件随 Release 一起上传

> 私钥只写入 GitHub Secret，本地不留副本；生成的是无口令密钥，仅限 CI 签名使用。

### 用户：验证签名

首次导入公钥（指纹见 Release 说明或自行查询）：

```bash
# 下载公钥并加入 pacman 密钥环
curl -fsSL https://你的用户名.github.io/arch_lib/releases/download/latest/arch_lib.pub.asc | sudo pacman-key --add -
# 本地信任（lsign-key 接受指纹或邮箱）
sudo pacman-key --lsign-key arch-lib@localhost
```

然后在 `/etc/pacman.conf` 中启用严格签名：

```ini
[arch_lib]
SigLevel = Required DatabaseOptional
Server = https://你的用户名.github.io/arch_lib/releases/download/latest
```

- `Required`：包必须带有效签名
- `DatabaseOptional`：数据库签名可选（`Required` 也可，但首次未签名时建议先 `DatabaseOptional`）

未配置密钥的仓库（无 `.sig` 文件）请继续使用 `SigLevel = Optional TrustAll`。

## 注意事项

- **构建时间**：`-git` 包首次构建需要时间，后续若上游无更新会自动跳过
- **构建失败**：`fail-fast: false`，单包失败不影响其他包
- **包签名**：仓库配置为 `SigLevel = Optional TrustAll`，不验证 GPG 签名
- **Release 覆盖**：每次运行覆盖 `latest` tag 的 Release，只保留最新版本

## License

MIT