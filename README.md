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
packages.txt ──▶ prepare ──▶ build (matrix)
                              ├── flutter-bin ──▶ Release flutter-bin
                              ├── yay          ──▶ Release yay
                              └── ...          ──▶ Release ...
```

1. **prepare** — 解析 `packages.txt` 生成 matrix
2. **build** — 每个包并行构建；`-git` 包先检查上游 commit hash，未变则跳过
3. **发布** — 每个构建 job 直接将产物上传到自己的 Release（tag = 包名，覆盖更新）

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

### 3. 安装包

每个包在 Releases 页面有独立 Release（tag = 包名），可直接下载安装：

```bash
# 查看包列表 → 点击 Releases → 选择对应 tag
# 下载 .pkg.tar.zst 后用 pacman -U 安装
sudo pacman -U /path/to/package.pkg.tar.zst
```

或使用 `gh` CLI 直接下载并安装：

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

之后每次构建会自动对包文件生成 `.sig` 签名。

### 用户：验证签名

```bash
# 下载公钥
curl -fsSL https://github.com/你的用户名/arch_lib/releases/download/包名/arch_lib.pub.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key arch-lib@localhost

# 安装时验证
sudo pacman -U 包名-版本-架构.pkg.tar.zst
```

## 手动触发构建

在 GitHub 仓库的 **Actions → Build AUR Repository → Run workflow** 中可随时手动触发。

## 文件结构

```
arch_lib/
├── .github/workflows/
│   └── build-repo.yaml        # GitHub Actions 工作流（matrix + per-package release）
├── scripts/
│   ├── build-package.sh      # 单包构建脚本（含 -git 跳过逻辑）
│   ├── generate-signing-key.sh # 一键生成签名密钥
│   └── pre-build/            # 包级预构建钩子（可选）
│       └── qoder-cli.sh      # 示例：修复安装脚本行为异常的包
├── packages.txt              # 要构建的 AUR 包列表
├── arch_lib.pub.asc          # 签名公钥占位
└── README.md
```

## Release 产物结构

每个包独立 Release，tag = 包名：

```
latest (tag: yay/)
├── yay-12.4.2-1-x86_64.pkg.tar.zst
├── yay-12.4.2-1-x86_64.pkg.tar.zst.sig  # （如配置签名）
└── version.txt                            # 版本号（用于 -git 跳过检查）

latest (tag: flutter-bin/)
├── flutter-bin-3.35.1-1-x86_64.pkg.tar.zst
└── version.txt
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