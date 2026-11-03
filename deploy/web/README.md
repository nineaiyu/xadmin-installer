# 本地构建形态的前端反代栈（自 xadmin-client 迁入，2026-09-30）

自包含的前端托管 + API 反代 + TLS（acme.sh 自动签发）栈，供两种场景：

1. **前端独立部署**：构建好的 `dist/` 交给本栈托管并反代 `/api`、`/ws`、`/media`、
   `/flower`、`/api-docs` 到后端；
2. **需要 DOMAIN/EMAIL 自动签发证书**的 HTTP → HTTPS 形态（安装器的
   `compose/web.yml` 用的是预发布镜像 `nineaiyu/xadmin-web`，不支持本栈的
   acme.sh 自动签发参数，需要 SSL 时用本目录）。

> 从 xadmin-client 仓库迁出原因：vendored acme.sh（第三方脚本）与 nginx/TLS
> 配置属于部署资产，不应混入前端源码仓。镜像构建时 acme.sh 已内置
> （`COPY acme.sh/ /web/acme.sh/`），无需再挂载仓库目录。

## 使用

```shell
# 1. 构建前端产物（在 xadmin-client 仓库）
pnpm build                      # 产出 dist/

# 2. 启动本栈（DIST_DIR 指向上一步的 dist 绝对/相对路径）
DIST_DIR=../../xadmin-client/dist docker compose up -d --build

# SSL（自动签发 + 续签）：编辑 .env 或导出环境变量后重建
DOMAIN=xadmin.example.com EMAIL=ops@example.com DIST_DIR=... docker compose up -d --build
```

## 文件

| 文件 | 说明 |
|---|---|
| `Dockerfile` | nginx + acme.sh 内置 + entrypoint |
| `entrypoint.sh` | 无 DOMAIN = 纯 HTTP；有 DOMAIN = acme.sh 签发/续签 + HTTPS（生成的 server 块统一下发安全头与静态缓存策略，见下） |
| `conf/nginx.conf` | nginx 全局配置（client_max_body_size 4096m，与安装器 `CLIENT_MAX_BODY_SIZE` 契约一致 / gzip / 代理超时 600s） |
| `conf/xadmin-api-conf` | `/api\|/ws\|/flower\|/media\|/api-docs` 反代片段，须与主线 `xadmin-web` 仓同名文件保持一致（改任一侧需整体同步） |
| `acme.sh/` | vendored 第三方脚本（上游 https://github.com/acmesh-official/acme.sh），季度核对随 `scripts/check_images.sh` 流程之外单独人工核对 |

数据目录：`data/.acme.sh`（账号与证书状态）、`data/cert`（签发的证书）、
`data/logs`（nginx 日志）均为运行期生成，挂载进容器。

## 安全与缓存口径（与主线 xadmin-web 对齐）

- **X-Forwarded-Host / X-Forwarded-Proto 按本机观测值覆写**（不透传客户端原值，
  防伪造 `is_secure()` 污染密码重置 / OAuth 回跳），与主线 `xadmin-api-conf` 一致；
  上层还有终止 TLS 的 SLB 时，按该文件内注释切回透传。
- **生成的 server 块统一下发** `X-Content-Type-Options: nosniff`、
  `Referrer-Policy: strict-origin-when-cross-origin` 与 **CSP**（策略串与
  `xadmin-server` 的 `server/settings/csp.py` 一致）；防点击劫持由 CSP
  `frame-ancestors 'self'` 承担，不另发 X-Frame-Options。
- **静态缓存策略**：`/static/`（带内容哈希）一年 `immutable` 长缓存；
  `index.html` / `platform-config.json` 禁缓存——发版后浏览器沿用旧入口引用
  已删 chunk 会白屏，勿移除禁缓存。
- **未设 DOMAIN = 纯 HTTP**：80 直接服务内容，不做 HTTPS 跳转（内网形态）；
  需要强制 HTTPS 请设置 DOMAIN 走 acme 签发。
- **设 DOMAIN 后固定发送 `Strict-Transport-Security: max-age=31536000;
  includeSubDomains`**，比主线「默认不发 HSTS」更激进：`includeSubDomains`
  会约束该域名的**全部子域**，子域尚有纯 HTTP 服务时须去掉该标记
  （`entrypoint.sh` 的 addHttpsConf 模板内）。
- **证书 / 私钥**落 `./data/cert`，容器进入 HTTPS 模式时收敛为 `600`。
