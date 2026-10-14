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
