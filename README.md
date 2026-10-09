# xadmin 安装管理包

## 环境依赖

- Linux x86_64
- Kernel 大于 4.0

## 安装部署

```bash
# 安装，版本是在 static.env 指定的
$ ./xadmin.sh install
```

## 管理

```
# 启动
$ ./xadmin.sh start

# 重启
$ ./xadmin.sh restart

# 停止并移除全部容器（含数据库容器）
$ ./xadmin.sh stop

# 仅停止业务容器（保留数据库运行）
$ ./xadmin.sh close

# 查看状态 / 日志
$ ./xadmin.sh status
$ ./xadmin.sh tail [服务名]

# 备份 / 恢复数据库
$ ./xadmin.sh backup_db
$ ./xadmin.sh restore_db <备份文件>

# 升级（可指定版本；停服迁移前自动执行数据库升级前体检，
#      旧迁移链路的库会被拦下并指引清库重建，SKIP_UPGRADE_CHECK=1 可跳过）
$ ./xadmin.sh upgrade [v4.x.y]

# 卸载
$ ./xadmin.sh uninstall

```

## 季度镜像核对（维护流程）

本包是离线安装包形态，**没有 renovate**——第三方基础镜像（`compose/*.yml` 的
`mariadb` / `postgres` / `redis`，以及构建期的 `node` / `python` / `nginx`）版本全部手工固定，
`utils/base-images.yml` 维护「上游镜像 → 私有仓库镜像」映射。每季度按下列三步核对一次：

```bash
# 1. 生成核对表（贴进季度记录；--online 追加 registry digest，需联网与 docker）
bash scripts/check_images.sh
bash scripts/check_images.sh --online

# 2. 对照上游发布说明检查安全更新（Docker Hub / 上游 release note），
#    有更新则：改 compose 固定版本 → 同步 utils/base-images.yml → 重打私有镜像 → 安装回归

# 3. 映射完整性校验（发版前必须通过；缺映射 = 离线安装拉不到镜像）
bash scripts/check_images.sh --check-mapping
```

核对记录模板（追加到季度维护记录）：

```markdown
### 镜像核对 YYYY-QN

| 镜像 | 当前固定 | 上游最新 | 结论 |
|---|---|---|---|
| pgvector:pg17 | pg17 | pg17.x | 2026-10 F4 起替换 postgres:17.11（知识库向量检索需 vector 扩展；上游 `docker.io/pgvector/pgvector:pg17`，同 PG17 大版本数据目录兼容） |
| redis:8.10.2 | 8.10.2 | 8.10.2 | 2026-Q3 完成 7.4.11 → 8.10.2 评估升级（应用侧回归通过） |
| mariadb:11.8.9 | 11.8.9 | 11.8.9 | 无更新 |

- digest 记录：见 `scripts/check_images.sh --online` 输出
- 回归：安装 → 升级 → `xadmin.sh status` 全 healthy → 抽测登录与列表页
```

> 服务端仓库（xadmin-server）的镜像版本由 renovate 覆盖（`renovate.json` 的
> `config:recommended` 含 docker / docker-compose manager），本流程只针对本包。

## deploy/web：前端托管反代栈（本地构建形态）

`deploy/web/` 是自包含的前端托管 + API 反代 + acme.sh 自动签发 TLS 栈
（自 xadmin-client 仓库迁入，第三方脚本不再混入前端源码仓）。安装器主路径使用
预发布镜像 `nineaiyu/xadmin-web`（`compose/web.yml`）；需要 DOMAIN/EMAIL 自动
签发证书或前端独立部署时，进 `deploy/web/` 设 `DIST_DIR` 指向前端 `dist/` 后
`docker compose up -d --build`，用法见其 [README.md](deploy/web/README.md)。

## 配置文件说明

配置文件将会放在 /opt/xadmin/config 中

```
[root@localhost config]# tree .
.
├── config.txt       # 主配置文件
|── mariadb
|   └── mariadb.cnf  # mariadb 配置文件
├── nginx            # nginx 配置文件
│   ├── cert
│   │   ├── server.crt
│   │   └── server.key
│   └── lb_http_server.conf
├── README.md
└── redis
    └── redis.conf  # redis 配置文件

```

### config.txt 说明

config.txt 文件是环境变量式配置文件，会挂在到各个容器中，这样可以不必为每个容器单独设置配置文件

