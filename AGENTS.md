# AGENTS.md — xadmin-installer（离线安装器）

> 继承工作区根 `../AGENTS.md`。本仓库是**面向客户的交付入口**：脚本改坏的代价是用户装到一半失败，
> 因此改动必须同时过「语法门禁 + 真实流程复跑」。

## 一、仓库地图

| 路径 | 内容 |
|------|------|
| `xadmin.sh` | 入口，case 分支共 23 个命令：`install` `upgrade` `check_update` `config` `reconfig` `start` `restart` `stop` `pull` `close` `status` `down` `uninstall` `backup_db` `restore_db` `load_image` `pull_images` `cmd` `tail` `show_services` `init_db` `raw` `version` |
| `quick_start.sh` | 一键安装（下载 release tarball 并校验同 Release 的 `.md5` → `./xadmin.sh install && start`；CI 入口脚本存在性检查对象） |
| `scripts/0_prepare.sh` ~ `8_uninstall.sh` | 分步流程脚本（`3_load_images.sh` 加载镜像、`4_install_xadmin.sh` 安装、`5_db_backup.sh`/`6_db_restore.sh` 备份恢复、`7_upgrade.sh` 升级） |
| `scripts/utils.sh` | 公共函数（配置读写、容器健康、`perform_db_migrations`、`init_default_data`、`preflight_migration_check`、`ensure_pg_data_version`、`inplace_align_if_needed`、`pull_image`…） |
| `scripts/config.sh` | `config` 命令实现（子命令 ntp / init / port / ssl / env；`config ssl` 把证书拷进 `${CONFIG_DIR}/nginx/cert` 并 chmod 600） |
| `scripts/check_images.sh` | 镜像清单核对：`--check-mapping` 是**发版门禁**（缺映射 = 离线安装拉不到镜像）；季度核对流程见 README |
| `scripts/const.sh` / `static.env` | 常量与版本（`VERSION` 由 release-drafter 在 tarball 里 sed 替换） |
| `compose/` | 服务编排（server / celery / web / init-db / postgres / mariadb / redis / lb / network；`lb.yml` 是 HTTPS 443 TLS 终止形态，把 `${CONFIG_DIR}/nginx/lb_http_server.conf` 挂成 `https_server.conf`——上游必须是 `web:51980`） |
| `deploy/web/` | web 容器构建（nginx + acme.sh 证书） |
| `utils/base-images.yml` | 第三方基础镜像清单：`sync-base-image-mirror.yml` 按它同步到阿里云，`check_images.sh --check-mapping` 按它核对 |
| `.github/scripts/set-u-guard.sh` | `set -u` 陷阱回归用例（v 前缀归一化 / `SKIP_BACKUP_DB` / 回滚指引等 18 组），CI 跑 |
| `config_init/` / `config-example.txt` | 配置模板；**不携带任何证书/私钥**，HTTPS 需 `config ssl` 导入 |

`.env` 与 `compose/.env` 是指向 `config.txt` 的软链接——配置唯一来源是 `config.txt`；
`xadmin.sh` 在 Darwin / MINGW 上直接拒绝执行（只面向 Linux 目标机）。

## 二、改动约定

1. **所有 `*.sh` 必须过 `bash -n` 与 shellcheck（warning 级）**。CI `scripts-check.yml` 有八道门：
   bash -n 全量、入口脚本存在性（`xadmin.sh` / `quick_start.sh` / `scripts/7_upgrade.sh`）、
   `set-u-guard.sh` 用例（18 组，含回滚指引/恢复停服/备份回填）、`https-cert-guard.sh`
   （证书缺失/示例私钥 fail-closed）、shellcheck（0 warning 基线）、合并 compose config 校验、
   裸 `$SKIP_*` 引用 grep 门、inplace 对齐接线 grep 门。
   本地自查：`for f in $(find . -name '*.sh' -type f); do bash -n "$f" || echo "FAIL $f"; done`
2. **失败即退**：脚本用 `set -euo pipefail`。目标机（CentOS 7）自带 **bash 4.2**，不要用 4.4
   才支持的构造——尤其 `set -u` 下展开空数组会报 unbound，必须先判 `${#arr[@]}` 再展开。
   交互确认用 `read_from_input`，不要裸 `read`（非交互场景 stdin 已关闭，裸 `read` 会因
   EOF + `set -e` 静默中止安装）。**可选环境开关一律写 `${VAR:-默认值}`**（`SKIP_BACKUP_DB`
   等裸引用会在未设置时中止升级）；**版本号入参要归一化 `v` 前缀**（镜像 tag 不含 v，
   文档命令形态是 `./xadmin.sh upgrade vX.Y.Z`）。两条都有 set-u-guard 用例守护。
3. **配置读写走 `get_config` / `set_config`**（写回 `config.txt`），不要在脚本里硬编码路径或密码；
   数据库/Redis 密码的权威定义处是应用的 `config.yml`，安装器侧只做透传与兜底。
   `init_default_data` 会把超管初始密码回写 `XADMIN_ADMIN_PASSWORD` 到 config.txt——它是
   初始密码的权威来源。
4. **镜像引用分两类**：自有镜像 `${REGISTRY:-docker.io}/nineaiyu/...:${VERSION}`
   （server / celery / init-db / web 四个 yml）；第三方镜像写死固定 tag（redis / mariadb /
   pgvector）。**改第三方镜像版本要四处同步**：`compose/*.yml`、`scripts/utils.sh`
   （`get_images` / `get_db_info` 里硬编码同一串）、`utils/base-images.yml`、
   `check_images.sh --check-mapping`——漏任何一处就是离线安装/备份恢复拉不到镜像。
5. **升级链路不可跳步**：`upgrade` 的顺序是「版本门槛 → preflight（磁盘 ≥5GiB / 关键容器
   健康 / 备份目录可写）→ 配置迁移 → 加载镜像 → 备份 DB + 配置 → 停服 → 迁移账本认领
   （`upgrade_ledger --apply`）→ `migrate` → `post_upgrade` → Docker 工具升级 →
   **启动并健康校验** → 清镜像（默认 `n`）→ 版本落账」。
   启动校验失败必须保留旧镜像并打印回滚指引；`print_rollback_guide` 自动带入本次 DB /
   配置备份路径。附带机制：PG 大版本数据目录迁移（`ensure_pg_data_version`，开关
   `OLD_PG_IMAGE` / `SKIP_PG_DATA_MIGRATION=1`）；原地对齐探询 `inplace_align_if_needed`
   （**不能只看退出码**，开关 `SKIP_INPLACE_ALIGN=1` / `INPLACE_ALIGN=1` 无人值守）。
   改这段必须保持幂等与「失败可回滚」。
6. **升级基线**：`verify_upgrade_version` 要求当前版本 ≥ `v4.2.5`——放宽前先确认服务端支持矩阵
   （`xadmin-server/docs/ops/upgrade-stock.md`）；注意版本串非 `x.y.z` 形态时该门禁会跳过
   （log_warn + 放行），dev 版不受限是有意设计。
7. **演示模式**：`WITH_DEMO_DATA=1` 时 `init_default_data` 追加 `--with-demo`（演示账号
   `admin/admin123`），生产默认不启用。
8. **新增命令要三处一致**：`xadmin.sh` 的 case 分支、`usage` 帮助文本、`README.md` 命令表。
   新增/改名命令时三处同步修改；当前 23 个命令已对齐。
9. **配置要满足服务端 fail-fast 校验**：`SECRET_KEY` 由 `set_secret_key` 生成；`ALLOWED_HOSTS`
   由 `prepare_config` 调 `ensure_allowed_hosts` 推导（服务端 5.0 起 `DEBUG=false` 时必须配置，
   缺失即拒绝启动；4.2.x 旧配置没有该键，升级路径同样依赖它）。`set_config` 的替换已做 sed
   转义，值里可以出现逗号/引号（JSON 数组）等字符。
10. **运行期约束（5.0 起）**：应用镜像以 `USER 1001` 运行（4.2.x 为 root），`${VOLUME_DIR}/server/data`
    必须归该用户，由 `ensure_data_dir_owner`（`create_db_ops_env` 内调用）保证；容器健康检查脚本
    在镜像的 `ops/`（不是 `utils/`）；全新库由 `is_fresh_database` 判定后跳过升级前体检
    （`upgrade_check` 面向存量库，空库缺表会被判 schema-drift）。
11. **目录与权限约定**：备份落 `${VOLUME_DIR}/db_backup`（DB / 配置 / PG 迁移 dump 统一在这）、
    配置备份落 `${VOLUME_DIR}/config_backup`、证书落 `${CONFIG_DIR}/nginx/cert`；
    `prepare_config` 收敛权限（config.txt 600、CONFIG_DIR 700、redis.conf/mariadb.cnf 644）。
12. **`pull_image` 运行期形态**：阿里云前缀 `registry.cn-beijing.aliyuncs.com` 硬编码在
    `utils.sh`；`IMAGE_PULL_POLICY=Always` 强制重拉；`BUILD_ARCH` 映射 `--platform`；
    拉取后 retag 回本地短名（与 compose 的 `${REGISTRY:-docker.io}` 形态配合）。

## 三、验证

```bash
bash -n xadmin.sh && for f in $(find . -name '*.sh' -type f); do bash -n "$f" || echo "FAIL $f"; done
bash .github/scripts/set-u-guard.sh            # set -u 陷阱回归
bash .github/scripts/https-cert-guard.sh       # HTTPS 证书 fail-closed（缺失/示例私钥拒绝）
shellcheck -S warning xadmin.sh quick_start.sh scripts/*.sh .github/scripts/*.sh   # 0 warning
./xadmin.sh version            # 只读命令冒烟
# 编排语法：单个 compose 文件依赖 network/env，需合并并给必要变量（CONFIG_FILE 文件需存在）
VERSION=dev CONFIG_FILE=/tmp/xadmin-config.txt VOLUME_DIR=/tmp/xadmin-data CONFIG_DIR=/tmp/xadmin-conf \
  docker compose --env-file config-example.txt -f compose/network.yml -f compose/server.yml \
  -f compose/celery.yml -f compose/web.yml -f compose/redis.yml -f compose/postgres.yml \
  -f compose/lb.yml config -q
```

真实流程验证（起一台干净机器或本地 docker）走 `install` / `upgrade` 全流程；
无环境时至少说明「未做端到端验证」的边界，不要声称已验证。**HTTPS 形态必须单独验证**：
启用 `HTTPS_PORT` 后 `curl -k https://<host>:<HTTPS_PORT>/web/health/` 应返回
`{"status": "ok"}`，不能只测 HTTP 直连。

## 四、发布与镜像同步（本仓库是镜像链路的末端）

链路：各仓库推 tag `v*` → 分别构建并推 Docker Hub（`xadmin-web` 的 Dockerfile 依赖
`nineaiyu/xadmin-client:VERSION`，链路最长）→ 本仓库 `sync-image-mirror.yml` 同步到阿里云仓
→ 安装器运行期统一从阿里云仓拉取（`utils.sh` 的 `pull_image` 按 `DOCKER_IMAGE_MIRROR` 加前缀），
运行时自有镜像（server / web）缺任一 tag 都装不起来。

三条硬约束：

1. **同步必须等源镜像**：同批 tag 推送时同步会先起跑，工作流内置「等待源镜像出现」的有界轮询，
   不要改回「一次性失败退出」。
2. **带构建溯源附件的 index 推不进阿里云**：附件（`config.mediaType` 为
   `application/vnd.oci.empty.v1+json` 的 OCI 1.1 artifact）会被目标仓拒（"unknown manifest class"），
   且 image-syncer 时代一个子 manifest 失败即整 tag 判败。故同步只挑 `linux/amd64` /
   `linux/arm64` 两个平台 manifest 重建 index；构建侧同时关闭 registry 内溯源附件
   （`provenance: false`，GitHub 侧 attestation 不受影响）。
3. **发版 tag 必须打在包含本工作流修复的提交上**：tag 事件运行的是 tag 所指提交里的工作流定义，
   `main` 上改过但 tag 指向旧提交时，同步仍走旧逻辑。
4. **tag 顺序**：`server` / `client` 镜像构建成功 → `web`（依赖 client 镜像）→ `docs` →
   本仓库 `installer`（同步必需 server/web；docs 可选、只做镜像分发）。installer 放最后推；
   同步失败用上面的 `workflow_dispatch` 补跑，不要只 rerun。

失败补救：`gh workflow run sync-image-mirror.yml -R nineaiyu/xadmin-installer -f version=<版本>`
（tag 触发的 run 不能用 rerun 修复——rerun 走的是 tag 上的旧工作流）。
