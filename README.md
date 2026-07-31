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
Server = https://你的用户名.github.io/arch_lib/releases/download/latest/$arch
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
│   └── build-package.sh      # 单包构建脚本（含 -git 跳过逻辑）
├── packages.txt              # 要构建的 AUR 包列表
└── README.md
```

## Release 产物结构

每次构建完成后，`latest` Release 包含：

```
latest/
├── x86_64.tar.zst              # x86_64 仓库目录完整打包
├── last-versions.txt           # 版本追踪文件（下次运行用于 -git 跳过判断）
└── repos/x86_64/
    ├── arch_lib.db.tar.gz     # pacman 仓库数据库
    ├── arch_lib.db             # 数据库符号链接
    └── *.pkg.tar.zst          # 构建好的包文件
```

pacman 通过 `Server = .../releases/download/latest/$arch` 访问，GitHub Release 自动提供 `x86_64` 路径下的文件。

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

## 注意事项

- **构建时间**：`-git` 包首次构建需要时间，后续若上游无更新会自动跳过
- **构建失败**：`fail-fast: false`，单包失败不影响其他包
- **包签名**：仓库配置为 `SigLevel = Optional TrustAll`，不验证 GPG 签名
- **Release 覆盖**：每次运行覆盖 `latest` tag 的 Release，只保留最新版本

## License

MIT