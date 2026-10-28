# 部署指南（Deploy）

[![Deploy to Cloudflare Workers](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/stevessr/custom_lib_build)

> **一键部署按钮**：点击上方按钮 → 授权 Cloudflare → 自动导入本仓库
> （`wrangler.toml` 位于仓库根，服务可直接识别）→ 在 Cloudflare
> Dashboard 选择项目名并点 **Deploy** 即完成部署，随后按 §4 配置环境
> 变量即可。也可跳过按钮，按 §3 用 `wrangler` CLI 部署。

一键部署 Cloudflare Worker 代理私有 S3 桶，并配置 pacman 仓库的 S3 部署。

## 架构

```
pacman 客户端 ──> Cloudflare Worker ──> assets 命中：直接返回（<25MB 文件）
     │                                    └──> S3 签名代理（≥25MB 大包）
     └── 匿名请求（无需凭证）                 （凭证仅存于 Worker 环境变量）
```

- **GitHub Actions** 构建包 → 发布到 `latest` Release → 同步到私有桶（可配置）
- **Cloudflare Worker** 分流：`<25MB` 文件（db/files/签名/元数据/小包）托管为
  Workers 静态资源直接返回；`≥25MB` 大包走 SigV4 签名代理从私有桶拉取
  （支持 Range 断点续传与 CDN 缓存）

---

## 1. 前置要求

- Node.js 18+ 与 `wrangler` CLI（Cloudflare 原生工具）

```bash
npm install -g wrangler
wrangler login          # 首次：浏览器授权 Cloudflare 账号
```

## 2. 准备 S3 兼容存储凭证

### Cloudflare R2（推荐）

1. Cloudflare Dashboard → **R2** → 创建桶（如 `arch-lib`）
2. 右上角 **管理 R2 API 令牌** → 创建 API 令牌 → 权限选 *对象读和写*
3. 记录：**Access Key ID**、**Secret Access Key**、**S3 端点**
   （格式 `https://<accountid>.r2.cloudflarestorage.com`）

### AWS S3 / 其他 S3 兼容服务

IAM 用户需以下权限：`s3:ListBucket`、`s3:GetObject`、`s3:PutObject`、`s3:DeleteObject`。
记录 Access Key / Secret / Endpoint（AWS 可用 `https://s3.<region>.amazonaws.com`）。

## 3. 一键部署 Worker

```bash
npx wrangler deploy          # 仓库根执行，读取 wrangler.toml（main = cloudflare/worker.js）
```

首次运行会提示确认，之后每次更新 `worker.js` 后重新执行该命令即可。

## 进阶：自动部署 Workflow（推荐）

配置两个 secrets 后，`Build AUR Repository` 每次发布成功会自动重新部署
Worker，无需手动操作：

| Secret | 值 |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API 令牌（权限：Workers Scripts *Edit*、Account Settings *Read*） |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare 账户 ID |

```bash
# 在 Cloudflare Dashboard → My Profile → API Tokens 创建令牌
# 然后在仓库 Settings → Secrets and variables → Actions 添加上述两项
```

工作流（`.github/workflows/deploy-cloudflare.yaml`）每次运行：

1. 下载 `latest` Release 全部资产
2. **`<25MB` 文件收集到 `worker-assets/`**（Cloudflare Workers 静态资源
   单文件上限 25 MiB）——`arch_lib.db`/`.files`、所有 `.sig`、公钥、
   `version-*.txt`/`manifest-*.txt` 及小包直接由 Worker 托管
3. `wrangler deploy` 上传 Worker + assets（`wrangler.toml` 的 `[assets]`）
4. **`≥25MB` 大包**不在 assets 中，Worker 运行时回落 S3 签名代理——
   因此本模式依赖 §6 的 S3 部署已配置

也可在 Actions 页手动触发 **Deploy Cloudflare Worker**。

> 免费版 Workers 静态资源配额有限（约 512 MiB），若 `latest` 中小文件
> 总量超限，部署会失败；此时仅 S3 代理模式（跳过本工作流）不受影响。

## 4. 配置 Worker 环境变量

**敏感凭证**（用 Cloudflare 原生 `wrangler secret put`，加密存储、不可读回）：

```bash
npx wrangler secret put S3_ENDPOINT          # 如 https://<accountid>.r2.cloudflarestorage.com
npx wrangler secret put S3_BUCKET            # 如 arch-lib
npx wrangler secret put S3_ACCESS_KEY_ID
npx wrangler secret put S3_SECRET_ACCESS_KEY
```

**非敏感变量**（已写入 `wrangler.toml` 的 `[vars]`，可按需修改后重新 deploy）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `S3_REGION` | `us-east-1` | S3 区域 |
| `BASE_PATH` | 空 | 客户端 URL 前缀（见 §7），留空则 Worker 根路径即桶根 |
| `GITHUB_DISPATCH_REPOSITORY` | `stevessr/custom_lib_build` | Webhook 触发的目标构建仓库 |
| `OPENUUYC_UPSTREAM_REPOSITORY` | `stevessr/openuuyc-linux` | 允许触发更新的源仓库 |
| `OPENUUYC_UPSTREAM_BRANCH` | `linux-port` | 允许触发更新的源码分支，与 PKGBUILD 保持一致 |

> 修改 `wrangler.toml` 后重新 `npx wrangler deploy` 生效；全部变量也可在
> Cloudflare Dashboard → Workers → 你的 Worker → **设置 → 变量** 中可视化配置。

## 5. 验证代理

```bash
# 桶中应有 arch_lib.db / arch_lib.files / *.pkg.tar.zst（先完成 §6 部署）
curl -I "https://<你的worker域名>/arch_lib.db"
# 期望 HTTP 200 与 Content-Length；404 表示对象不存在或路径前缀不对
```

## 6. 配置 GitHub Actions 的 S3 部署（可选）

仓库 **Settings → Secrets and variables → Actions** 添加以下 secrets，
`Build AUR Repository` 每次发布后会自动同步到 S3（未配置则跳过）：

| Secret | 值 |
|---|---|
| `S3_ENDPOINT` | S3 端点（如 R2 端点） |
| `S3_BUCKET` | 桶名 |
| `S3_ACCESS_KEY_ID` | 凭证 |
| `S3_SECRET_ACCESS_KEY` | 凭证 |
| `S3_REGION` | 可选，默认 `us-east-1` |
| `S3_PREFIX` | 可选，桶内前缀（如 `arch-lib`），默认桶根 |

同步使用 `--delete`：远端与 `latest` Release 严格一致，旧版本包文件自动移除。

## 7. pacman 客户端配置

```ini
# /etc/pacman.conf
[arch_lib]
SigLevel = Optional TrustAll
Server = https://<你的worker域名>/<BASE_PATH>
```

然后：

```bash
sudo pacman -Sy
sudo pacman -S <包名>
```

> 若设置了 `BASE_PATH`，Server 需带上前缀，例如 `https://worker.example.com/arch-lib`；
> Worker 会剥掉前缀再访问桶内对象。

## OpenUUYC webhook（可选）

默认每日构建已包含 `openuuyc-git`。需要源分支更新后立即触发时，可在现有 Worker 启用 GitHub 原生 webhook 接收器；**只使用 webhook 时不需要 S3 凭证**。未配置以下两个 Secret 时，接收器返回 404，不影响现有下载代理和每日检查。

1. 先将包含 `openuuyc-update` 的 `build-repo.yaml` 部署到目标仓库的默认分支；GitHub 的 `repository_dispatch` 只从默认分支读取工作流。
2. 在 `wrangler.toml` 的 `[vars]` 核对目标仓库及源仓库/分支。Fork 本构建仓库时，修改 `GITHUB_DISPATCH_REPOSITORY`；源仓库/分支必须与 `custom-pkgs/openuuyc-git/PKGBUILD` 的 `source` 一致，这些变量不会切换实际构建输入。
3. 创建仅授权目标构建仓库的 GitHub fine-grained PAT，授予 **Contents: Read and write**。它用来创建 `repository_dispatch`，不要使用会暴露给客户端的令牌。
4. 为 Worker 配置两个加密 Secret，然后部署。命令通过交互输入值，不要把值写进 `wrangler.toml`、仓库或命令历史：

   ```bash
   npx wrangler secret put GITHUB_WEBHOOK_SECRET
   npx wrangler secret put GITHUB_DISPATCH_TOKEN
   npx wrangler deploy
   ```

   `GITHUB_WEBHOOK_SECRET` 使用随机高熵值；`GITHUB_DISPATCH_TOKEN` 使用上一步的 PAT。这两项是 **Worker Secret**，不是 GitHub Actions Secret。

5. 在 `stevessr/openuuyc-linux` 的 **Settings → Webhooks → Add webhook** 配置：

   | 设置 | 值 |
   |---|---|
   | Payload URL | `https://<Worker域名>/webhooks/openuuyc`；若 `BASE_PATH=arch-lib`，使用 `/arch-lib/webhooks/openuuyc` |
   | Content type | `application/json` |
   | Secret | 与 `GITHUB_WEBHOOK_SECRET` 完全相同 |
   | SSL verification | 启用 |
   | Events | Just the push event |
   | Active | 启用 |

接收器先用原始请求字节验证 `X-Hub-Signature-256`（HMAC-SHA256），再检查源仓库、分支、非删除 push 和 commit hash。符合条件时向目标仓库发送 `event_type=openuuyc-update`；无关分支或事件被忽略。签名密钥和 PAT 都不会返回给调用方。

在源仓库 Webhook 的 **Recent Deliveries** 检查响应：首次签名 `ping` 为 200，成功派发或忽略事件为 202（响应正文分别为 `Accepted` / `Ignored`），签名失败为 401，JSON 无效为 400，未配置 Secret 为 404，GitHub 派发失败为 502。确认 `Accepted` 后，在目标仓库 Actions 查看 **Build AUR Repository**。

Webhook 运行现有完整构建/复用/发布编排，不用单包数据库覆盖整个仓库；`-git` 源码 commit 未变时复用产物。停止即时触发可在源仓库停用此 webhook，每日检查仍继续。

本地验证：

```bash
node --test cloudflare/worker.test.mjs
```

协议参考：[GitHub 签名验证](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries)、[创建 repository dispatch](https://docs.github.com/en/rest/repos/repos#create-a-repository-dispatch-event)。

