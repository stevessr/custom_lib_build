# arch_lib

将 AUR 包转换为可通过 `pacman` 直接安装的自托管 Arch Linux 仓库，使用 GitHub Actions 每日自动更新。

## 工作原理

1. **GitHub Actions** 每天 UTC 00:00 自动运行（也可手动触发）
2. 在 `archlinux:latest` 容器中构建 `packages.txt` 中列出的每个 AUR 包
3. 使用 `repo-add` 生成 pacman 兼容的仓库数据库
4. 自动推送到 `gh-pages` 分支，通过 **GitHub Pages** 分发

用户只需在 `/etc/pacman.conf` 中添加一行配置，即可用 `pacman` 直接安装这些包。

## 快速开始

### 1. Fork 本仓库

点击右上角 **Fork** 按钮，将仓库复制到你的 GitHub 账号下。

### 2. 配置要构建的包

编辑 `packages.txt`，每行一个 AUR 包名：

```txt
# 要构建的 AUR 包列表
yay
paru
hyprland-nvidia
```

### 3. 启用 GitHub Pages

在仓库 **Settings → Pages** 中配置：

- **Source**: `Deploy from a branch`
- **Branch**: `gh-pages`，目录 `/ (root)`
- 点击 **Save**

> 首次 CI 运行完成后会自动创建 `gh-pages` 分支。

### 4. 在你的 Arch Linux 上使用

编辑 `/etc/pacman.conf`，在文件末尾添加：

```ini
[arch_lib]
SigLevel = Optional TrustAll
Server = https://你的用户名.github.io/arch_lib/repos/$arch
```

然后同步并安装：

```bash
sudo pacman -Sy         # 刷新仓库元数据
sudo pacman -S 包名      # 安装包（例如: sudo pacman -S yay）
```

## 手动触发构建

在 GitHub 仓库的 **Actions → Build AUR Repository → Run workflow** 中可随时手动触发构建。

## 文件结构

```
arch_lib/
├── .github/workflows/
│   └── build-repo.yml      # GitHub Actions 工作流定义
├── scripts/
│   └── build-repo.sh       # 核心构建脚本
├── packages.txt            # 要构建的 AUR 包列表
├── repos/x86_64/           # 生成的仓库目录（推送到 gh-pages 分支）
│   ├── arch_lib.db.tar.gz  # 仓库数据库
│   ├── arch_lib.files.tar.gz
│   └── *.pkg.tar.zst       # 构建好的包文件
└── README.md
```

## 自定义

### 添加/删除包

编辑 `packages.txt`，提交到 `main` 分支即可。下次 CI 运行会自动生效。

### 修改构建频率

编辑 `.github/workflows/build-repo.yml` 中的 `cron` 表达式：

```yaml
schedule:
  - cron: '0 6 * * *'   # 每天 UTC 06:00
```

## 注意事项

- **构建时间**：AUR 包编译需要时间，首次构建可能较慢。后续构建会缓存源码，只拉取增量更新。
- **构建失败**：某个包构建失败不会影响其他包。失败的包会在日志中标记，成功构建的包仍会发布。
- **磁盘空间**：GitHub Actions 免费额度足够日常使用。每个包只保留最新版本。
- **包签名**：当前仓库配置为 `SigLevel = Optional TrustAll`，不验证 GPG 签名。如需签名，可自行添加 GPG 步骤。

## License

MIT