#!/usr/bin/env bash
#

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/const.sh"

function check_root() {
  [[ "$(id -u)" == 0 ]]
}

function is_confirm() {
  read -r confirmed
  if [[ "${confirmed}" == "y" || "${confirmed}" == "Y" || ${confirmed} == "" ]]; then
    return 0
  else
    return 1
  fi
}

function random_str() {
  len=$1
  if [[ -z ${len} ]]; then
    len=24
  fi
  uuid=""
  if check_root && command -v dmidecode &>/dev/null; then
    if [[ ${len} -gt 24 ]]; then
      uuid=$(dmidecode -s system-uuid | sha256sum | awk '{print $1}' | head -c ${len})
    fi
  fi
  if [[ "${#uuid}" == "${len}" ]]; then
    echo "${uuid}"
  else
    head -c200 < /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c ${len}; echo
  fi
}

function has_config() {
  key=$1
  if grep "^[ \t]*${key}=" "${CONFIG_FILE}" &>/dev/null; then
    echo "1"
  else
    echo "0"
  fi
}

function get_config() {
  key=$1
  default=${2-''}
  value=$(grep "^${key}=" "${CONFIG_FILE}" | awk -F= '{ print $2 }' | awk -F' ' '{ print $1 }')
  if [[ -z "$value" ]];then
    value="$default"
  fi
  echo "${value}"
}

function get_env_value() {
  key=$1
  default=${2-''}
  value=""
  # 变量未定义时 ${!key} 会在 set -u 下直接中止脚本（旧版本 config.txt 缺键的
  # 升级/复用场景会命中），先判断存在性再取值；declare -p 比 [[ -v ]]（bash 4.2+）
  # 兼容更老的 bash。
  if declare -p "${key}" &>/dev/null; then
    value="${!key}"
  fi
  echo "${value}"
}

function get_config_or_env() {
  key=$1
  value=''
  default=${2-''}
  if [[ -f "${CONFIG_FILE}" ]];then
    value=$(get_config "$key")
  fi

  if [[ -z "$value" ]];then
    value=$(get_env_value "$key")
  fi

  if [[ -z "$value" ]];then
    value="$default"
  fi
  echo "${value}"
}

function set_config() {
  key=$1
  value=$2

  has=$(has_config "${key}")
  if [[ ${has} == "0" ]]; then
    echo "${key}=${value}" >>"${CONFIG_FILE}"
    return
  fi

  origin_value=$(get_config "${key}")
  if [[ "${value}" == "${origin_value}" ]]; then
    return
  fi

  # 替换串先转义、分隔符用 |：配置值可能含逗号（如 ALLOWED_HOSTS 的 JSON 数组
  # ["192.168.0.1","127.0.0.1"]）与 & \ | 等 sed 元字符，沿用 `,` 分隔会被 sed 判为非法
  local escaped
  escaped=$(printf '%s' "${value}" | sed 's/[\\&|]/\\&/g')
  sed -i "s|^[ \t]*${key}=.*$|${key}=${escaped}|g" "${CONFIG_FILE}"
}

function disable_config() {
  key=$1

  has=$(has_config "${key}")
  if [[ ${has} == "1" ]]; then
    sed -i "s,^[ \t]*${key}=.*$,# ${key}=,g" "${CONFIG_FILE}"
  fi
}

function check_volume_dir() {
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -d "${volume_dir}" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function check_db_data() {
  db_type=$1
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    return
  fi
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -d "${volume_dir}/${db_type}/data" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function get_db_info() {
  info_type=$1
  db_engine=$(get_config DB_ENGINE "mysql")
  db_host=$(get_config DB_HOST)
  check_volume_dir=$(check_volume_dir)
  if [[ "${check_volume_dir}" == "0" ]]; then
    db_engine=$(get_config DB_ENGINE "postgresql")
  fi

  mariadb_data_exists="0"
  postgres_data_exists="0"

  case "${db_engine}" in
    "mysql")
      mariadb_data_exists="1"
      ;;
    "postgresql")
      postgres_data_exists="1"
      ;;
  esac

  case "${info_type}" in
    "image")
      if [[ "${mariadb_data_exists}" == "1" ]]; then
        echo "mariadb:11.8.9"
      elif [[ "${postgres_data_exists}" == "1" ]]; then
        echo "pgvector:pg17"
      fi
      ;;
    "file")
      if [[ "${mariadb_data_exists}" == "1" ]]; then
        echo "compose/mariadb.yml"
      elif [[ "${postgres_data_exists}" == "1" ]]; then
        echo "compose/postgres.yml"
      fi
      ;;
    *)
      exit 1 ;;
  esac
}

function get_db_images() {
  get_db_info "image"
}

function get_db_images_file() {
  get_db_info "file"
}

function get_images() {
  db_images=$(get_db_images)
  images=(
    "redis:8.10.2"
    "${db_images}"
  )
  for image in "${images[@]}"; do
    echo "${image}"
  done
  echo "nineaiyu/xadmin-server:${VERSION}"
  echo "nineaiyu/xadmin-web:${VERSION}"
}

function read_from_input() {
  var=$1
  msg=$2
  choices=$3
  default=$4
  if [[ -n "${choices}" ]]; then
    msg="${msg} (${choices}) "
  fi
  if [[ -z "${default}" ]]; then
    msg="${msg} (no default)"
  else
    msg="${msg} (default ${default})"
  fi
  echo -n "${msg}: "
  # 非交互安装（quick_start.sh 的 curl ... | bash、stdin 已关闭等）下 read 会因 EOF 失败，
  # set -e 会让脚本静默中止；此处按默认值继续，保证一键安装可无人值守完成
  input=""
  read -r input || true
  if [[ -z "${input}" && -n "${default}" ]]; then
    export "${var}"="${default}"
  else
    export "${var}"="${input}"
  fi
}

function get_file_md5() {
  file_path=$1
  if [[ -f "${file_path}" ]]; then
    if [[ "${OS}" == "Darwin" ]]; then
      md5 "${file_path}" | awk -F= '{ print $2 }'
    else
      md5sum "${file_path}" | awk '{ print $1 }'
    fi
  fi
}

function check_md5() {
  file=$1
  md5_should=$2

  md5=$(get_file_md5 "${file}")
  if [[ "${md5}" == "${md5_should}" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function echo_red() {
  echo -e "\033[1;31m$1\033[0m"
}

function echo_green() {
  echo -e "\033[1;32m$1\033[0m"
}

function echo_yellow() {
  echo -e "\033[1;33m$1\033[0m"
}

function echo_done() {
  sleep 0.5
  echo "complete"
}

function echo_check() {
  echo -e "$1 \t [\033[32m √ \033[0m]"
}

function echo_warn() {
  echo -e "[\033[33m WARNING \033[0m] $1"
}

function echo_failed() {
  echo_red "fail"
}

function log_success() {
  echo_green "[SUCCESS] $1"
}

function log_warn() {
  echo_yellow "[WARN] $1"
}

function log_error() {
  echo_red "[ERROR] $1"
}

function get_docker_compose_services() {
  # 可选参数：show_services / close 等调用点不传参
  ignore_db="${1-}"
  db_engine=$(get_config DB_ENGINE "mysql")
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)

  services="server celery web"

  if [[ "${ignore_db}" != "ignore_db" ]]; then
    case "${db_engine}" in
      mysql)
        [[ "${db_host}" == "mysql" ]] && services+=" mysql"
        ;;
      postgresql)
        [[ "${db_host}" == "postgresql" ]] && services+=" postgresql"
        ;;
    esac
    [[ "${redis_host}" == "redis" ]] && services+=" redis"
  fi

  for service in server celery web; do
    enabled=$(get_config "${service^^}_ENABLED")
    [[ "${enabled}" == "0" ]] && services="${services//${service}/}"
  done

  echo "${services}"
}

function get_docker_compose_cmd_line() {
  # ${1-}：本函数由 xadmin.sh 无参调用，set -u 下直接取 $1 会中止
  ignore_db="${1-}"
  https_port=$(get_config HTTPS_PORT)
  db_images_file=$(get_db_images_file)
  cmd="docker compose -f compose/network.yml"

  services=$(get_docker_compose_services "$ignore_db")

  for service in server celery web redis; do
    if [[ "${services}" =~ ${service} ]]; then
      cmd+=" -f compose/${service}.yml"
    fi
  done

  if [[ "${services}" =~ "mysql" || "${services}" =~ "postgresql" ]]; then
    cmd+=" -f ${db_images_file}"
  fi

  if [[ -n "${https_port}" ]]; then
    cmd+=" -f compose/lb.yml"
  fi

  echo "${cmd}"
}

function prepare_check_required_pkg() {
  # 局部变量必须显式初始化：脚本以 set -u 运行，依赖齐全时 flag 不会被赋值，
  # 直接引用 $flag 会以 "unbound variable" 中止整个安装流程
  local flag=0
  for i in curl wget tar iptables; do
    command -v $i &>/dev/null || {
        echo_red "$i: command not found, Please install it first $i"
        flag=1
    }
  done
  if [[ "${flag}" == "1" ]]; then
    echo
    exit 1
  fi
}

function prepare_set_redhat_firewalld() {
  if command -v firewall-cmd&>/dev/null; then
    if firewall-cmd --state &>/dev/null; then
      docker_subnet=$(get_config DOCKER_SUBNET)
      if ! firewall-cmd --list-rich-rule | grep "${docker_subnet}"&>/dev/null; then
        firewall-cmd --zone=public --add-rich-rule="rule family=ipv4 source address=${docker_subnet} accept" >/dev/null
        firewall-cmd --permanent --zone=public --add-rich-rule="rule family=ipv4 source address=${docker_subnet} accept" >/dev/null
      fi
    fi
  fi
}

function prepare_config() {
  cd "${PROJECT_DIR}" || exit 1
  if check_root; then
    echo -e "#!/usr/bin/env bash\n#" > /usr/bin/xadmin
    echo -e "cd ${PROJECT_DIR}" >> /usr/bin/xadmin
    echo -e './xadmin.sh $@' >> /usr/bin/xadmin
    chmod 755 /usr/bin/xadmin
  fi

  echo_yellow "1. Check Configuration File"
  echo "Path to Configuration file: ${CONFIG_DIR}"
  if [[ ! -d ${CONFIG_DIR} ]]; then
    mkdir -p "${CONFIG_DIR}"
    cp config-example.txt "${CONFIG_FILE}"
  fi
  if [[ ! -f ${CONFIG_FILE} ]]; then
    cp config-example.txt "${CONFIG_FILE}"
  else
    echo_check "${CONFIG_FILE}"
  fi
  # 权限收敛（幂等，覆盖安装/升级/配置变更三条路径）：config.txt 含 DB/Redis 密码与 SECRET_KEY
  chmod 700 "${CONFIG_DIR}"
  chmod 600 "${CONFIG_FILE}"
  if [[ ! -f ".env" ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi
  if [[ ! -f "./compose/.env" ]]; then
    ln -s "${CONFIG_FILE}" ./compose/.env
  fi

  # shellcheck disable=SC2045
  for d in $(ls "${PROJECT_DIR}/config_init"); do
    if [[ -d "${PROJECT_DIR}/config_init/${d}" ]]; then
      for f in $(ls "${PROJECT_DIR}/config_init/${d}"); do
        if [[ -f "${PROJECT_DIR}/config_init/${d}/${f}" ]]; then
          if [[ ! -f "${CONFIG_DIR}/${d}/${f}" ]]; then
            \cp -rf "${PROJECT_DIR}/config_init/${d}" "${CONFIG_DIR}"
          else
            echo_check "${CONFIG_DIR}/${d}/${f}"
          fi
        fi
      done
    fi
  done

  nginx_cert_dir="${CONFIG_DIR}/nginx/cert"
  if [[ ! -d ${nginx_cert_dir} ]]; then
    mkdir -p "${nginx_cert_dir}"
    \cp -rf "${PROJECT_DIR}/config_init/nginx/cert" "${CONFIG_DIR}/nginx"
  fi

  # shellcheck disable=SC2045
  for f in $(ls "${PROJECT_DIR}/config_init/nginx/cert"); do
    if [[ -f "${PROJECT_DIR}/config_init/nginx/cert/${f}" ]]; then
      if [[ ! -f "${nginx_cert_dir}/${f}" ]]; then
        \cp -f "${PROJECT_DIR}/config_init/nginx/cert/${f}" "${nginx_cert_dir}"
      else
        echo_check "${nginx_cert_dir}/${f} "
      fi
    fi
  done
  chmod 700 "${CONFIG_DIR}/../"
  find "${CONFIG_DIR}" -type d -exec chmod 700 {} \;
  find "${CONFIG_DIR}" -type f -exec chmod 600 {} \;
  chmod 644 "${CONFIG_DIR}/redis/redis.conf"
  chmod 644 "${CONFIG_DIR}/mariadb/mariadb.cnf"

  # 数据目录收紧（敏感文件权限审计的可选加固项）：运行期数据（日志/上传/备份）
  # 不做全局可读；仅调整目录位 750，不递归改文件（保留容器内既有属主/权限语义）。
  # 幂等：安装 / 升级 / 配置三个调用路径共用 prepare_config，目录不存在时跳过
  local volume_dir data_dir
  volume_dir="$(get_config VOLUME_DIR)"
  data_dir="${volume_dir}/server/data"
  if [[ -n "${volume_dir}" && -d "${data_dir}" ]]; then
    chmod 750 "${data_dir}"
  fi

  if [[ "$(uname -m)" == "aarch64" ]]; then
    sed -i "s/# ignore-warnings ARM64-COW-BUG/ignore-warnings ARM64-COW-BUG/g" "${CONFIG_DIR}/redis/redis.conf"
  fi

  ensure_allowed_hosts
}

# 服务端 5.0 起在 DEBUG=false 时强制要求 Host 白名单，缺失会直接拒绝启动
# （容器起不来 → 安装中断在「Init xAdmin Database」，或升级后容器反复重启），
# 且 4.2.x 的旧配置没有该键，升级路径同样要补。安装/升级/配置三条路径共用
# prepare_config，故在此按本机 IP + 回环 + DOMAINS 推导；已配置则不覆盖（幂等）。
function ensure_allowed_hosts() {
  local allowed_hosts host entry
  allowed_hosts=$(get_config ALLOWED_HOSTS)
  if [[ -n "${allowed_hosts}" ]]; then
    return
  fi

  local hosts=()
  host=$(get_host_ip)
  if [[ -n "${host}" ]]; then
    hosts+=("${host}")
  fi
  hosts+=("127.0.0.1" "localhost")

  # DOMAINS 是外部访问地址（逗号分隔、可能带端口），去掉端口并入白名单。
  # 先判数组长度再展开：set -u 下展开空数组在 bash 4.2/4.3（CentOS 7 自带）会报
  # "unbound variable"
  local _domains=()
  IFS=',' read -r -a _domains <<<"$(get_config DOMAINS)"
  if [[ ${#_domains[@]} -gt 0 ]]; then
    for entry in "${_domains[@]}"; do
      entry="${entry// /}"
      if [[ -z "${entry}" ]]; then
        continue
      fi
      hosts+=("${entry%%:*}")
    done
  fi

  # 必须是 JSON 数组：服务端按 json.loads 解析，非 JSON 值会原样当字符串返回，
  # Django 侧逐字符匹配 Host → 全站 400
  allowed_hosts="[$(printf '%s\n' "${hosts[@]}" | awk '!seen[$0]++' | sed 's/^/"/; s/$/"/' | paste -sd, -)]"
  set_config ALLOWED_HOSTS "${allowed_hosts}"
  echo "ALLOWED_HOSTS= ${allowed_hosts}（按本机 IP / 回环 / DOMAINS 推导，可在 ${CONFIG_FILE} 调整）"
}

function echo_logo() {
  cat <<"EOF"

                                                              dddddddd
                                   AAA                        d::::::d                          iiii
                                  A:::A                       d::::::d                         i::::i
                                 A:::::A                      d::::::d                          iiii
                                A:::::::A                     d:::::d
xxxxxxx      xxxxxxx           A:::::::::A            ddddddddd:::::d    mmmmmmm    mmmmmmm   iiiiiiinnnn  nnnnnnnn
 x:::::x    x:::::x           A:::::A:::::A         dd::::::::::::::d  mm:::::::m  m:::::::mm i:::::in:::nn::::::::nn
  x:::::x  x:::::x           A:::::A A:::::A       d::::::::::::::::d m::::::::::mm::::::::::m i::::in::::::::::::::nn
   x:::::xx:::::x           A:::::A   A:::::A     d:::::::ddddd:::::d m::::::::::::::::::::::m i::::inn:::::::::::::::n
    x::::::::::x           A:::::A     A:::::A    d::::::d    d:::::d m:::::mmm::::::mmm:::::m i::::i  n:::::nnnn:::::n
     x::::::::x           A:::::AAAAAAAAA:::::A   d:::::d     d:::::d m::::m   m::::m   m::::m i::::i  n::::n    n::::n
     x::::::::x          A:::::::::::::::::::::A  d:::::d     d:::::d m::::m   m::::m   m::::m i::::i  n::::n    n::::n
    x::::::::::x        A:::::AAAAAAAAAAAAA:::::A d:::::d     d:::::d m::::m   m::::m   m::::m i::::i  n::::n    n::::n
   x:::::xx:::::x      A:::::A             A:::::Ad::::::ddddd::::::ddm::::m   m::::m   m::::mi::::::i n::::n    n::::n
  x:::::x  x:::::x    A:::::A               A:::::Ad:::::::::::::::::dm::::m   m::::m   m::::mi::::::i n::::n    n::::n
 x:::::x    x:::::x  A:::::A                 A:::::Ad:::::::::ddd::::dm::::m   m::::m   m::::mi::::::i n::::n    n::::n
xxxxxxx      xxxxxxxAAAAAAA                   AAAAAAAddddddddd   dddddmmmmmm   mmmmmm   mmmmmmiiiiiiii nnnnnn    nnnnnn


EOF

  echo -e "\t\t\t\t\t\t\t\t   Version: \033[33m $VERSION \033[0m \n"
}

function get_latest_version() {
  curl -s 'https://api.github.com/repos/nineaiyu/xadmin-server/releases/latest' |
    grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' |
    sed 's/\"//g;s/,//g;s/ //g'
}

function image_has_prefix() {
  if [[ $1 =~ xadmin.* ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function get_db_migrate_compose_cmd() {
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)

  cmd="docker compose -f compose/init-db.yml"
  if [[ "${db_host}" == "mysql" ]] || [[ "${db_host}" == "postgresql" ]]; then
    db_images_file=$(get_db_images_file)
    cmd+=" -f ${db_images_file}"
  fi
  if [[ "${redis_host}" == "redis" ]]; then
    cmd+=" -f compose/redis.yml"
  fi
  cmd+=" -f compose/network.yml"

  echo "$cmd"
}

# 数据目录属主修正：5.0 起镜像声明 `USER 1001`（4.2.x 为 root），而镜像里预建并
# chown 的 /data/xadmin-server/data 会被 compose 的 bind 挂载遮蔽 —— 宿主目录由 docker
# 以 root 创建，应用（uid 1001）无权在其中创建 logs/uploads，安装/升级会中断在
# 「Init xAdmin Database」（PermissionError）。属主按镜像声明的运行用户推导，取不到镜像
# 时回落 1001:1001（与镜像 Dockerfile 的 USER 一致；对 root 运行的旧镜像无副作用）。
function ensure_data_dir_owner() {
  local volume_dir data_dir app_user image current_owner
  volume_dir="$(get_config VOLUME_DIR)"
  if [[ -z "${volume_dir}" ]]; then
    return
  fi
  data_dir="${volume_dir}/server/data"
  mkdir -p "${data_dir}"

  app_user=""
  for image in "nineaiyu/xadmin-server:$(get_current_version)" "nineaiyu/xadmin-server:${VERSION}"; do
    if docker image inspect "${image}" > /dev/null 2>&1; then
      app_user=$(docker image inspect -f '{{.Config.User}}' "${image}")
      [[ -z "${app_user}" ]] || break
    fi
  done
  if [[ -z "${app_user}" ]]; then
    app_user="1001"
  fi
  if [[ "${app_user}" != *:* ]]; then
    app_user="${app_user}:${app_user}"
  fi

  # 仅在属主不一致时递归调整（数据目录可能很大，install/upgrade 期间重复调用要避免全量遍历）
  current_owner=$(stat -c '%u:%g' "${data_dir}" 2> /dev/null || true)
  if [[ "${current_owner}" != "${app_user}" ]]; then
    chown -R "${app_user}" "${data_dir}" || log_warn "调整 ${data_dir} 属主为 ${app_user} 失败，容器可能无法写入"
  fi
  chmod 750 "${data_dir}"
}

function create_db_ops_env() {
  ensure_data_dir_owner
  cmd=$(get_db_migrate_compose_cmd)
  ${cmd} up -d || {
    exit 1
  }
}

function down_db_ops_env() {
  docker stop xadmin-server &>/dev/null
  docker rm xadmin-server &>/dev/null
}

function init_mariadb_tz_info() {
  DB_HOST=$(get_config DB_HOST)

  if [[ "${DB_HOST}" == "mysql" ]]; then
    while [[ "$(docker inspect -f "{{.State.Health.Status}}" xadmin-${DB_HOST})" != "healthy" ]]; do
      sleep 5s
    done
    sql_cmd='mariadb-tzinfo-to-sql /usr/share/zoneinfo | mariadb -P$DB_PORT -p$MARIADB_ROOT_PASSWORD  mysql'
    docker exec -it xadmin-${DB_HOST} bash -c "${sql_cmd}"  || {
      log_error "Failed to import tz info!"
      exit 1
      }
  fi
}

function init_default_data() {
  # 首次安装时生成并持久化超管初始密码（回写 config.txt，供 post_install 与用户查阅）；
  # 库中已有用户时 init_data 会跳过创建，此处密码仅作为记录。
  local admin_password
  admin_password=$(get_config XADMIN_ADMIN_PASSWORD)
  if [[ -z "${admin_password}" ]]; then
    admin_password=$(random_str 16)
    set_config XADMIN_ADMIN_PASSWORD "${admin_password}"
  fi

  # 演示模式（可选）：WITH_DEMO_DATA=1 时灌入演示数据并创建演示账号 admin/admin123。
  # 权限受控（挂「演示模式」角色，破坏性写操作已裁剪），适合对外体验环境；
  # 重置：docker exec -i xadmin-server python manage.py seed_demo_all --reset
  local init_args=""
  if [[ "${WITH_DEMO_DATA:-0}" == "1" ]]; then
    init_args="--with-demo"
    log_info "WITH_DEMO_DATA=1: demo data and demo account (admin/admin123) will be created"
  fi

  create_db_ops_env
  # shellcheck disable=SC2086
  docker exec -i -e XADMIN_ADMIN_PASSWORD="${admin_password}" xadmin-server bash -c "python ops/init_data.py ${init_args}" || {
    log_error "Failed to import default data!"
    exit 1
  }
  log_success "Superuser 'xadmin' initial password: ${admin_password} (saved in ${CONFIG_FILE})"
  if [[ "${WITH_DEMO_DATA:-0}" == "1" ]]; then
    log_success "Demo account: admin / admin123 (role 'demo', destructive writes pruned)"
  fi
}

# 全新库判定（无任何业务表 = 首次安装）：升级前体检面向存量库，空库「缺表」会被
# upgrade_check 判成 schema-drift（5.0.0 镜像的既有行为），首次安装因此被拦下。
# 只读查询；库不可达或查询失败时返回「非空」（保守：照旧走体检）。
function is_fresh_database() {
  local db_host db_name tables sql
  db_host=$(get_config DB_HOST)
  db_name=$(get_config DB_DATABASE)
  case "${db_host}" in
    postgresql)
      sql="select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema');"
      tables=$(printf '%s\n' "${sql}" |
        docker exec -i xadmin-postgresql sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA' 2> /dev/null || true)
      ;;
    mysql)
      sql="select count(*) from information_schema.tables where table_schema = '${db_name}';"
      tables=$(printf '%s\n' "${sql}" |
        docker exec -i xadmin-mysql sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -N -B' 2> /dev/null || true)
      ;;
    *)
      return 1
      ;;
  esac
  [[ "${tables//[[:space:]]/}" == "0" ]]
}

# 迁移前体检（python manage.py upgrade_check 的包装）：识别旧迁移链路的库或结构漂移的库，
# 默认中止并指引「备份 + 清库重建 + 数据回灌」（见 xadmin-server docs/ops/upgrade-stock.md）。
# SKIP_UPGRADE_CHECK=1 显式跳过；体检命令不可用（极旧镜像）时走同一下降级询问。
function preflight_migration_check() {
  if [[ "${SKIP_UPGRADE_CHECK:-0}" == "1" ]]; then
    echo "SKIP_UPGRADE_CHECK=1, skip pre-upgrade database check"
    return 0
  fi
  if docker exec -i xadmin-server bash -c 'python manage.py upgrade_check' 2>/dev/null; then
    return 0
  fi
  log_error "Pre-upgrade check failed: the database may come from an incompatible migration chain"
  log_error "or have schema drift. See docs/ops/upgrade-stock.md (backup + clean rebuild)."
  log_error "Databases created before the domain split (tables named system_userinfo / system_uploadfile)"
  log_error "cannot be upgraded in place: clean rebuild then re-import with"
  log_error "  python manage.py legacy_export --output /tmp/xadmin-legacy   (on the old version)"
  log_error "  python manage.py legacy_import --input /tmp/xadmin-legacy   (on the new version)"
  confirm="n"
  read_from_input confirm "Run database migration anyway? (NOT recommended)" "y/n" "${confirm}"
  if [[ "${confirm}" != "y" ]]; then
    exit 1
  fi
}

# PostgreSQL 数据目录主版本（如 16 / 17）。
function pg_data_major_version() {
  local volume_dir version_file
  volume_dir=$(get_config VOLUME_DIR)
  version_file="${volume_dir}/postgresql/data/PG_VERSION"
  if [[ -f "${version_file}" ]]; then
    tr -d "[:space:]" < "${version_file}"
  fi
}

# 目标 PG 镜像名：compose/postgres.yml 的镜像行（本地 tag 形态，拉取阶段已打本地名）。
function pg_image_name() {
  grep -E "^[[:space:]]*image:" "${PROJECT_DIR}/compose/postgres.yml" 2> /dev/null |
    head -n 1 | awk '{print $2}'
}

# 目标 PG 镜像主版本：从镜像 tag 解析（pgvector:pg17 → 17）。
function pg_image_major_version() {
  local image
  image=$(pg_image_name)
  if [[ -z "${image}" ]]; then
    return 0
  fi
  printf '%s' "${image}" | grep -oE "pg[0-9]+" | head -n 1 | tr -d "pg"
}

# PostgreSQL 大版本迁移：数据目录版本低于目标镜像主版本时（4.x 的 PG16 → 5.0 的 PG17），
# 用旧镜像导出逻辑备份、让新镜像在新目录初始化、再恢复数据——大版本的数据目录不兼容，
# 直接换镜像启动会循环重启（server / worker 因依赖 PG 健康也起不来）。
# 前置：容器已停；OLD_PG_IMAGE 为升级前运行中的 PG 镜像（由升级流程在停服前记录）。
# 开关 SKIP_PG_DATA_MIGRATION=1 跳过；无法判定版本（目录不存在/镜像 tag 无 pgNN）时直接返回。
function ensure_pg_data_version() {
  local volume_dir data_version image_version dump_file timestamp
  if [[ "${SKIP_PG_DATA_MIGRATION:-0}" == "1" ]]; then
    echo "SKIP_PG_DATA_MIGRATION=1, skip PostgreSQL data directory migration"
    return 0
  fi
  volume_dir=$(get_config VOLUME_DIR)
  data_version=$(pg_data_major_version)
  image_version=$(pg_image_major_version)
  if [[ -z "${data_version}" || -z "${image_version}" || "${data_version}" == "${image_version}" ]]; then
    return 0
  fi
  if [[ "${data_version}" -gt "${image_version}" ]]; then
    log_error "PostgreSQL data directory is version ${data_version}, newer than the target image (pg${image_version})."
    log_error "Downgrade is not supported; restore a backup taken on the matching major version."
    exit 1
  fi
  if [[ -z "${OLD_PG_IMAGE:-}" ]]; then
    log_error "Cannot determine the running PostgreSQL image; set OLD_PG_IMAGE (e.g. registry.../postgres:16.8)"
    exit 1
  fi

  local db_user db_password db_name
  db_user=$(get_config DB_USER)
  db_password=$(get_config DB_PASSWORD)
  db_name=$(get_config DB_DATABASE)
  dump_file="${volume_dir}/db_backup/pg${data_version}-to-pg${image_version}-$(date +%F_%T).dump"
  timestamp=$(date +%F_%T)

  echo "PostgreSQL major version migration: ${data_version} -> ${image_version}"
  mkdir -p "$(dirname "${dump_file}")"

  echo "  - exporting logical backup with ${OLD_PG_IMAGE}"
  docker rm -f xadmin-pg-migrate &> /dev/null
  docker run -d --name xadmin-pg-migrate -e POSTGRES_PASSWORD="${db_password}" \
    -v "${volume_dir}/postgresql/data:/var/lib/postgresql/data" "${OLD_PG_IMAGE}" > /dev/null || {
    log_error "Failed to start the source PostgreSQL container for export"
    exit 1
  }
  local i
  for i in $(seq 1 30); do
    docker exec xadmin-pg-migrate pg_isready -q -U "${db_user}" &> /dev/null && break
    sleep 2s
  done
  if ! docker exec xadmin-pg-migrate pg_dump -U "${db_user}" -d "${db_name}" -Fc > "${dump_file}"; then
    log_error "pg_dump failed; the data directory is untouched"
    docker rm -f xadmin-pg-migrate &> /dev/null
    exit 1
  fi
  docker rm -f xadmin-pg-migrate &> /dev/null
  echo "  - backup written to ${dump_file}"

  echo "  - archiving old data directory and initializing pg${image_version}"
  mv "${volume_dir}/postgresql/data" "${volume_dir}/postgresql/data.pg${data_version}-${timestamp}"
  mkdir -p "${volume_dir}/postgresql/data"
  docker rm -f xadmin-pg-restore &> /dev/null
  docker run -d --name xadmin-pg-restore -e POSTGRES_DB="${db_name}" -e POSTGRES_USER="${db_user}" \
    -e POSTGRES_PASSWORD="${db_password}" \
    -v "${volume_dir}/postgresql/data:/var/lib/postgresql/data" \
    "$(pg_image_name)" > /dev/null || {
    log_error "Failed to initialize the pg${image_version} data directory"
    exit 1
  }
  for i in $(seq 1 45); do
    docker exec xadmin-pg-restore pg_isready -q -U "${db_user}" &> /dev/null && break
    sleep 2s
  done
  echo "  - restoring data"
  if ! docker exec -i xadmin-pg-restore pg_restore -U "${db_user}" -d "${db_name}" --no-owner --no-acl \
    < "${dump_file}"; then
    log_warn "pg_restore reported non-fatal warnings; verify the row counts below"
  fi
  echo -n "  - restored migrations/users: "
  docker exec xadmin-pg-restore psql -U "${db_user}" -d "${db_name}" -tAc \
    "select count(*) from django_migrations" | tr -d "[:space:]"
  docker rm -f xadmin-pg-restore &> /dev/null
  echo "  - PostgreSQL data directory is now pg${image_version}"
  echo "    (old directory kept at ${volume_dir}/postgresql/data.pg${data_version}-${timestamp})"
}

function perform_db_migrations() {
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)

  create_db_ops_env
  case "${db_host}" in
    mysql|postgresql)
      while [[ "$(docker inspect -f "{{.State.Health.Status}}" xadmin-${db_host})" != "healthy" ]]; do
        sleep 5s
      done
      ;;
  esac

  if [[ "${redis_host}" == "redis" ]]; then
    while [[ "$(docker inspect -f "{{.State.Health.Status}}" xadmin-redis)" != "healthy" ]]; do
      sleep 5s
    done
  fi

  if is_fresh_database; then
    echo "检测到全新数据库（无业务表），跳过升级前体检"
  else
    preflight_migration_check
  fi

  # 迁移账本认领（4.x → 5.0 迁移链合并）：删除旧链游离记录并把合并链迁移记为已应用，
  # 不执行 DDL；全新库与已认领库为 no-op。旧镜像无该命令时告警跳过（走原有迁移路径）。
  if ! docker exec -i xadmin-server bash -c 'python manage.py upgrade_ledger --apply'; then
    log_warn "Migration ledger reconcile skipped/failed; continuing (see docs/ops/upgrade-stock.md)"
  fi

  docker exec -i xadmin-server bash -c 'python manage.py migrate' || {
    log_error "Failed to change the table structure!"
    exit 1
  }
}

function set_current_version() {
  current_version=$(get_config CURRENT_VERSION)
  if [ "${current_version}" != "${VERSION}" ]; then
    set_config CURRENT_VERSION "${VERSION}"
  fi
}

function get_current_version() {
  current_version=$(get_config CURRENT_VERSION "${VERSION}")
  echo "${current_version}"
}

function pull_image() {
  image=$1
  DOCKER_IMAGE_MIRROR=$(get_config_or_env 'DOCKER_IMAGE_MIRROR')
  IMAGE_PULL_POLICY=$(get_config_or_env 'IMAGE_PULL_POLICY')

  if [[ "${DOCKER_IMAGE_MIRROR}" == "1" ]]; then
    DOCKER_IMAGE_PREFIX="registry.cn-beijing.aliyuncs.com"
  else
    DOCKER_IMAGE_PREFIX=$(get_config_or_env 'DOCKER_IMAGE_PREFIX')
  fi

  if docker image inspect -f '{{ .Id }}' "$image" &>/dev/null; then
    exists=0
  else
    exists=1
  fi

  if [[ "$exists" == "0" && "$IMAGE_PULL_POLICY" != "Always" ]]; then
    echo "[${image}] exist, pass"
    return
  fi

  pull_args=""
  case "${BUILD_ARCH-}" in
    "x86_64") pull_args="--platform linux/amd64" ;;
    "aarch64") pull_args="--platform linux/arm64" ;;
  esac

  echo "[${image}] pulling"
  full_image_path="${image}"
  if [[ -n "${DOCKER_IMAGE_PREFIX}" ]]; then
    if [[ $(image_has_prefix "${image}") != "1" ]]; then
      full_image_path="${DOCKER_IMAGE_PREFIX}/nineaiyu/${image}"
    else
      full_image_path="${DOCKER_IMAGE_PREFIX}/${image}"
    fi
  fi

  docker pull ${pull_args} "${full_image_path}"
  if [[ "${full_image_path}" != "${image}" ]]; then
    docker tag "${full_image_path}" "${image}"
    docker rmi -f "${full_image_path}"
  fi
  echo ""
}

function check_images() {
  images_to=$(get_images)
  failed=0

  for image in ${images_to}; do
    if ! docker image inspect -f '{{ .Id }}' "$image" &>/dev/null; then
      pull_image "$image"
    fi
  done
  for image in ${images_to}; do
    if ! docker image inspect -f '{{ .Id }}' "$image" &>/dev/null; then
      echo_red "Failed to pull image ${image}"
      failed=1
    fi
  done

  if [ $failed -eq 1 ]; then
    exit 1
  fi
}

function pull_images() {
  images_to=$(get_images)
  pids=()

  trap 'kill ${pids[*]}' SIGINT SIGTERM

  for image in ${images_to}; do
    pull_image "$image" &
    pids+=($!)
  done
  # 逐个 wait 且容忍失败：set -e 下 `wait ${pids[*]}` 会因最后一个拉取任务失败而直接退出，
  # 导致 check_images 的可读失败清单（Failed to pull image ...）永远不打印
  if [[ ${#pids[@]} -gt 0 ]]; then
    for pid in "${pids[@]}"; do
      wait "${pid}" || true
    done
  fi

  trap - SIGINT SIGTERM

  check_images
}

function installation_log() {
  return
#  if [ -d "${BASE_DIR}/images" ]; then
#    return
#  fi
#  product=js
#  install_type=$1
#  version=$(get_current_version)
#  url="https://xadmin.dvcloud.xin/api/install/analytics?product=${product}&type=${install_type}&version=${version}"
#  curl --connect-timeout 5 -m 10 -k $url &>/dev/null
}

function get_host_ip() {
  local default_ip="127.0.0.1"
  host=$(command -v hostname &>/dev/null && hostname -I | cut -d ' ' -f1)
  if [ ! "${host}" ]; then
      host=$(command -v ip &>/dev/null && ip addr | grep 'inet ' | grep -Ev '(127.0.0.1|inet6|docker)' | awk '{print $2}' | head -n 1 | cut -d / -f1)
  fi
  if [[ ${host} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "${host}"
  else
      echo "${default_ip}"
  fi
}
