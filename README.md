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

# 升级（可指定版本）
$ ./xadmin.sh upgrade [v4.x.y]

# 卸载
$ ./xadmin.sh uninstall

```

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

