# AGENTS.md — xadmin-installer（离线安装器）

> 继承工作区根 `../AGENTS.md`。本仓库是**面向客户的交付入口**：脚本改坏的代价是用户装到一半失败，
> 因此改动必须同时过「语法门禁 + 真实流程复跑」。

## 一、仓库地图

| 路径 | 内容 |
|------|------|
| `xadmin.sh` | 入口：`install` `upgrade` `config` `reconfig` `start` `stop` `restart` `status` `down` `uninstall` `check_update` `load_image` `pull_images` `backup_db` `restore_db` `raw` `tail` |
| `scripts/0_prepare.sh` ~ `8_uninstall.sh` | 分步流程脚本（`3_load_images.sh` 加载镜像、`4_install_xadmin.sh` 安装、`5_db_backup.sh`/`6_db_restore.sh` 备份恢复、`7_upgrade.sh` 升级） |
| `scripts/utils.sh` | 公共函数（配置读写、容器健康、`perform_db_migrations`、`init_default_data`、`preflight_migration_check`…） |
| `scripts/const.sh` / `static.env` | 常量与版本（`VERSION` 在发版时被替换） |
| `compose/` | 服务编排（server / celery / web / init-db / postgres / mariadb / redis / lb / network） |
| `deploy/web/` | web 容器构建（nginx + acme.sh 证书） |
| `utils/base-images.yml` | 基础镜像清单（与 `sync-image-mirror.yml` / `check_images.sh` 联动） |
| `config_init/` / `config-example.txt` | 配置模板 |

## 二、改动约定

1. **所有 `*.sh` 必须过 `bash -n`**（CI `scripts-check.yml` 逐文件校验 + 入口脚本存在性）。
   本地自查：`for f in $(find . -name '*.sh' -type f); do bash -n "$f" || echo "FAIL $f"; done`
2. **失败即退**：脚本用 `set -euo pipefail`（bash ≥ 4.4）；交互确认用 `read_from_input`，
   不要裸 `read`。
3. **配置读写走 `get_config` / `set_config`**（写回 `config.txt`），不要在脚本里硬编码路径或密码；
   数据库/Redis 密码的权威定义处是应用的 `config.yml`，安装器侧只做透传与兜底。
4. **镜像 tag 由 `VERSION` 决定**（`compose/*.yml` 的 `${VERSION}`）：发布时同步 `static.env`，
   不要写死版本号。
5. **升级链路不可跳步**：`upgrade` 的顺序是「版本门槛 → 预检 → 配置迁移 → 加载镜像 → 备份 DB +
   配置 → 停服 → 迁移账本认领（`upgrade_ledger --apply`）→ `migrate` → `post_upgrade` → 清镜像 → 版本落账」。
   改这段必须保持幂等与「失败可回滚」（回滚指引在脚本末尾打印）。
6. **升级基线**：`verify_upgrade_version` 要求当前版本 ≥ `v4.2.5`——放宽前先确认服务端支持矩阵
   （`xadmin-server/docs/ops/upgrade-stock.md`）。
7. **演示模式**：`WITH_DEMO_DATA=1` 时 `init_default_data` 追加 `--with-demo`（演示账号
   `admin/admin123`），生产默认不启用。
8. **新增命令要三处一致**：`xadmin.sh` 的 case 分支、`usage` 帮助文本、`README.md` 命令表。

## 三、验证

```bash
bash -n xadmin.sh && for f in $(find . -name '*.sh' -type f); do bash -n "$f" || echo "FAIL $f"; done
./xadmin.sh version            # 只读命令冒烟
docker compose -f compose/postgres.yml config   # 编排语法
```

真实流程验证（起一台干净机器或本地 docker）走 `install` / `upgrade` 全流程；
无环境时至少说明「未做端到端验证」的边界，不要声称已验证。

## 四、发布与镜像同步（本仓库是镜像链路的末端）

链路：各仓库推 tag `v*` → 分别构建并推 Docker Hub（`xadmin-web` 的 Dockerfile 依赖
`nineaiyu/xadmin-client:VERSION`，链路最长）→ 本仓库 `sync-image-mirror.yml` 同步到阿里云仓
→ 安装器运行期统一从阿里云仓拉取（`utils.sh` 的 `pull_image` 按 `DOCKER_IMAGE_MIRROR` 加前缀），
自有镜像缺任一 tag 都装不起来。

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

失败补救：`gh workflow run sync-image-mirror.yml -R nineaiyu/xadmin-installer -f version=<版本>`
（tag 触发的 run 不能用 rerun 修复——rerun 走的是 tag 上的旧工作流）。
