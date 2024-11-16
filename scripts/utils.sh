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
  value="${!key}"
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

  sed -i "s,^[ \t]*${key}=.*$,${key}=${value},g" "${CONFIG_FILE}"
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
        echo "mariadb:11.5.2"
      elif [[ "${postgres_data_exists}" == "1" ]]; then
        echo "postgres:16.5"
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
    "redis:7.4.1"
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
  read -r input
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
  ignore_db="$1"
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
  ignore_db="$1"
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
  for i in curl wget tar iptables; do
    command -v $i &>/dev/null || {
        echo_red "$i: command not found, Please install it first $i"
        flag=1
    }
  done
  if [[ -n "$flag" ]]; then
    unset flag
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

  if [[ "$(uname -m)" == "aarch64" ]]; then
    sed -i "s/# ignore-warnings ARM64-COW-BUG/ignore-warnings ARM64-COW-BUG/g" "${CONFIG_DIR}/redis/redis.conf"
  fi
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

function create_db_ops_env() {
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
  create_db_ops_env
  docker exec -i xadmin-server bash -c 'python utils/init_data.py' || {
    log_error "Failed to import default data!"
    exit 1
  }
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
  case "${BUILD_ARCH}" in
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
  wait ${pids[*]}

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
