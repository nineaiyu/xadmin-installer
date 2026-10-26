#!/usr/bin/env bash
# 失败即退：离线安装器不允许"半装"状态继续执行（目标机 CentOS 7 自带 bash 4.2，
# 勿用 4.4 才支持的构造：set -u 下展开空数组会报 unbound，须先判 ${#arr[@]}）
set -euo pipefail
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"
. "${BASE_DIR}/2_install_docker.sh"

target=$1
# 版本号归一化：文档形态是 `./xadmin.sh upgrade v5.0.1`，而镜像 tag 不含 v 前缀
# （`nineaiyu/xadmin-server:5.0.1`）。不归一化会去拉 `xadmin-server:v5.0.1` 并以
# manifest unknown 失败（实测）。
target="${target#[vV]}"

# 回滚指引要引用本次升级的真实备份路径（由备份脚本回填，见 backup_db）
db_backup_file=""
backup_config_file=""

function verify_upgrade_version() {
  # 版本门槛：低于 4.2.5 的库不在原地升级范围内，需「备份 + 清库重建 + 数据回灌」。
  # 版本号达标不等于结构达标——库结构是否等价由前置体检判定（legacy-chain-pre-split 表示库仍停留在
  # 按域分表之前，同样要走重建 + 回灌），见 xadmin-server docs/ops/upgrade-stock.md
  required_version="4.2.5"
  current_version=$(get_config CURRENT_VERSION)
  # 两侧都归一化 v 前缀：CURRENT_VERSION 由 set_current_version 写入（不带 v），
  # 早期写法用 ^v 匹配会让本函数恒早退（门禁形同不存在）
  current_version="${current_version#[vV]}"

  if [[ -z "${current_version}" ]]; then
    log_error "The current version is not detected, please check"
    exit 1
  fi

  if ! [[ "${current_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    log_warn "当前版本号 '${current_version}' 非 x.y.z 形态，跳过升级基线校验"
    return
  fi

  if [ "$(printf '%s\n' "$required_version" "$current_version" | sort -V | head -n1)" != "$required_version" ]; then
    log_error "Your current version does not meet the minimum requirements. Please upgrade to ${required_version}"
    log_error "Older databases cannot be upgraded in place: see xadmin-server docs/ops/upgrade-stock.md"
    exit 1
  fi
}

function preflight_check() {
  echo_yellow "\nPreflight checks"
  # 1) 磁盘空间：镜像加载 + 数据库体积余量（低于 5 GiB 中止）
  local volume_dir
  volume_dir=$(get_config VOLUME_DIR)
  local check_path="${volume_dir:-/}"
  local avail_kb
  avail_kb=$(df -Pk "${check_path}" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -n "${avail_kb}" && "${avail_kb}" -lt 5242880 ]]; then
    log_error "Insufficient disk space at ${check_path} (need >= 5 GiB). Free space before upgrading."
    exit 1
  fi
  echo "  - disk space ok (>= 5 GiB at ${check_path})"
  # 2) 关键容器健康（unhealthy 时人工确认；未运行视为冷升级放行）
  local name status
  for name in xadmin-postgresql xadmin-redis; do
    status=$(docker inspect -f '{{.State.Health.Status}}' "${name}" 2>/dev/null || true)
    if [[ -n "${status}" && "${status}" != "healthy" ]]; then
      confirm="n"
      read_from_input confirm "Container ${name} is '${status}'. Continue anyway?" "y/n" "${confirm}"
      [[ "${confirm}" == "y" ]] || exit 1
    fi
  done
  echo "  - key containers healthy (or confirmed)"
  # 3) 备份目录可写（升级流程依赖数据库备份产物）
  local backup_dir="${volume_dir}/db_backup"
  mkdir -p "${backup_dir}" 2>/dev/null || {
    log_error "Backup directory is not writable: ${backup_dir}"
    exit 1
  }
  echo "  - backup dir writable: ${backup_dir}"
}

function check_and_set_config() {
  local config_key=$1
  local default_value=$2
  local current_value
  current_value=$(get_config "${config_key}")
  if [ -z "${current_value}" ]; then
    set_config ${config_key} "${default_value}"
  fi
}

function upgrade_config() {
  if check_root; then
    check_docker_start
  fi
  if ! docker ps &>/dev/null; then
    log_error "Docker is not running, please install and start"
    exit 1
  fi
  local containers=("xadmin-nginx" "xadmin-lb")
  for container in "${containers[@]}"; do
    if docker ps -a | grep ${container} &>/dev/null; then
      docker stop ${container} &>/dev/null
      docker rm ${container} &>/dev/null
    fi
  done

  check_and_set_config "CURRENT_VERSION" "${VERSION}"
  check_and_set_config "CLIENT_MAX_BODY_SIZE" "4096m"
  check_and_set_config "SERVER_HOSTNAME" "${HOSTNAME}"
  check_and_set_config "USE_LB" "1"
}

function clean_file() {
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -f "${volume_dir}/server/data/flower" ]]; then
    rm -f "${volume_dir}/server/data/flower"
  fi
  if [[ -f "${volume_dir}/server/data/flower.db" ]]; then
    rm -f "${volume_dir}/server/data/flower.db"
  fi
}


function migrate_config() {
  prepare_config
}

function update_config_if_need() {
  migrate_config
  upgrade_config
  clean_file
}

function backup_config() {
  VOLUME_DIR=$(get_config VOLUME_DIR)
  BACKUP_DIR="${VOLUME_DIR}/db_backup"
  CURRENT_VERSION=$(get_config CURRENT_VERSION)
  backup_config_file="${BACKUP_DIR}/config-${CURRENT_VERSION}-$(date +%F_%T).conf"
  if [[ ! -d ${BACKUP_DIR} ]]; then
    mkdir -p ${BACKUP_DIR}
  fi
  cp "${CONFIG_FILE}" "${backup_config_file}"
  echo "Back up to ${backup_config_file}"
}

function backup_db() {
  # 可选环境开关必须带默认值：脚本以 set -u 运行，未设置时直接引用会中止升级
  # （实测：`./xadmin.sh upgrade 5.0.1` 走到「3. Backup database」即 unbound 退出）
  if [[ "${SKIP_BACKUP_DB:-0}" != "1" ]]; then
    local backup_out
    backup_out=$(mktemp)
    if ! DB_BACKUP_FILE_OUT="${backup_out}" bash "${SCRIPT_DIR}/5_db_backup.sh"; then
      rm -f "${backup_out}"
      confirm="n"
      read_from_input confirm "Failed to backup the database. Continue to upgrade?" "y/n" "${confirm}"
      if [[ "${confirm}" == "n" ]]; then
        exit 1
      fi
      return
    fi
    db_backup_file=$(cat "${backup_out}" 2>/dev/null || true)
    rm -f "${backup_out}"
  else
    echo "SKIP_BACKUP_DB=${SKIP_BACKUP_DB:-0}, Skip database backup"
  fi
}

function db_migrations() {
  if docker ps | grep -E "server"&>/dev/null; then
    confirm="y"
    read_from_input confirm "Detected that the xAdmin container is running. Do you want to close the container and continue to upgrade?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo
      cd "${PROJECT_DIR}" || exit 1
      # 停服会删除容器：先记下运行中的 PG 镜像，供大版本数据目录迁移用作导出源（如 4.x 的 PG16）
      OLD_PG_IMAGE=$(docker inspect -f '{{.Config.Image}}' xadmin-postgresql 2> /dev/null || true)
      export OLD_PG_IMAGE
      bash ./xadmin.sh stop
      sleep 2s
      # 大版本（pg16 → pg17）的数据目录不兼容：先导出 → 新目录初始化 → 恢复，再走迁移
      ensure_pg_data_version
      echo
    else
      exit 1
    fi
  fi
  if ! perform_db_migrations; then
    log_error "Failed to change the table structure!"
    confirm="n"
    read_from_input confirm "Failed to change the table structure. Continue to upgrade?" "y/n" "${confirm}"
    if [[ "${confirm}" != "y" ]]; then
      exit 1
    fi
  fi

  # 升级后数据补全（种子/权限点/语言包/配置缓存，幂等）：漏做会出现「新入口 403 / 文案回退英文」
  if ! docker exec -i xadmin-server bash -c 'python manage.py post_upgrade'; then
    log_warn "Post-upgrade tasks failed; run manually: docker exec -i xadmin-server python manage.py post_upgrade"
  fi
}

function clean_images() {
  current_version=$(get_config CURRENT_VERSION)
  if [[ "${current_version}" != "${to_version}" ]]; then
    # 无匹配镜像时 grep 返回 1；脚本以 set -e 运行，不兜底会让升级在此静默中止
    old_images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "nineaiyu/" | grep "${current_version}" || true)
    if [[ -n "${old_images}" ]]; then
      # 旧镜像是离线现场唯一的回滚路径，必须在新版本通过启动验证之后由用户
      # 显式确认；默认 n，回车不会删除。
      confirm="n"
      read_from_input confirm "Old images are kept for rollback. Clean them up now?" "y/n" "${confirm}"
      if [[ "${confirm}" == "y" ]]; then
        echo "${old_images}" | xargs docker rmi -f
      else
        echo "Old images kept: ${old_images}"
      fi
    fi
  fi
}

function wait_container_healthy() {
  local name=$1 timeout=${2:-300} waited=0 status
  while (( waited < timeout )); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "${name}" 2>/dev/null || true)
    case "${status}" in
      healthy) return 0 ;;
      unhealthy | exited | dead)
        log_error "${name} is ${status}"
        return 1
        ;;
    esac
    sleep 5
    waited=$((waited + 5))
  done
  log_error "Timed out waiting for ${name} to become healthy (last status: ${status:-missing})"
  return 1
}

function verify_app_health() {
  local name
  for name in xadmin-server xadmin-celery-worker xadmin-celery-heavy xadmin-web; do
    if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
      # server 是硬性要求；celery / web 可能被模块裁剪关闭
      if [[ "${name}" == "xadmin-server" ]]; then
        log_error "xadmin-server is not running after upgrade"
        return 1
      fi
      continue
    fi
    wait_container_healthy "${name}" 300 || return 1
  done
  echo "  - containers are healthy"
}

function start_and_verify() {
  echo_yellow "\n7. Start and verify"
  cd "${PROJECT_DIR}" || exit 1
  if ! bash ./xadmin.sh start; then
    log_error "Unable to start services after upgrade"
    return 1
  fi
  if ! verify_app_health; then
    log_error "The new version failed health verification; old images are kept for rollback."
    return 1
  fi
}

function print_rollback_guide() {
  echo_yellow "Rollback (if the new version is abnormal):"
  echo "  1) Stop services:  bash ./xadmin.sh stop"
  if [[ -n "${db_backup_file}" ]]; then
    echo "  2) Restore database: bash ${BASE_DIR}/6_db_restore.sh ${db_backup_file}"
  else
    echo "  2) Restore database: bash ${BASE_DIR}/6_db_restore.sh <this-upgrade DB backup in ${VOLUME_DIR}/db_backup>"
  fi
  if [[ -n "${backup_config_file}" ]]; then
    echo "  3) Restore config:  cp ${backup_config_file} ${CONFIG_FILE}"
  else
    echo "  3) Restore config:  cp <config backup printed above> ${CONFIG_FILE}"
  fi
  echo "  4) Revert VERSION in static.env and re-run ${BASE_DIR}/3_load_images.sh, then ./xadmin.sh start"
  echo "  Note: old images are kept unless you explicitly cleaned them; offline rollback needs them."
  echo -e "\n"
}

function upgrade_docker() {
  if check_root && [[ -f "/usr/local/bin/docker" ]]; then
    if ! /usr/local/bin/docker -v | grep ${DOCKER_VERSION} &>/dev/null; then
      echo -e "$(docker -v) \033[33m-->\033[0m Docker version \033[32m${DOCKER_VERSION}\033[0m"
      confirm="n"
      read_from_input confirm "Do you need upgrade Docker binaries?" "y/n" "${confirm}"
      if [[ "${confirm}" == "y" ]]; then
        echo
        cd "${PROJECT_DIR}" || exit 1
        bash ./xadmin.sh down
        sleep 2s
        echo
        systemctl stop docker
        cd "${BASE_DIR}" || exit 1
        install_docker
        check_docker_install
        check_docker_start
      fi
    fi
  fi
}

function upgrade_compose() {
  if check_root && [[ -f "/usr/local/libexec/docker/cli-plugins/docker-compose" || -f "${HOME:-/root}/.docker/cli-plugins/docker-compose" ]]; then
    if ! docker compose version | grep ${DOCKER_COMPOSE_VERSION} &>/dev/null; then
      echo
      echo -e "$(docker compose version) \033[33m-->\033[0m Docker Compose version \033[32m${DOCKER_COMPOSE_VERSION}\033[0m"
      confirm="n"
      read_from_input confirm "Do you need upgrade Docker Compose?" "y/n" "${confirm}"
      if [[ "${confirm}" == "y" ]]; then
        echo
        cd "${BASE_DIR}" || exit 1
        check_compose_install
        check_docker_compose
      fi
    fi
  fi
}

function main() {
  confirm="y"
  to_version="${VERSION}"
  if [[ -n "${target}" ]]; then
    to_version="${target}"
  fi

  read_from_input confirm "Are you sure you want to update the current version to ${to_version} ?" "y/n" "${confirm}"
  if [[ "${confirm}" != "y" || -z "${to_version}" ]]; then
    exit 3
  fi

  if [[ "${to_version}" && "${to_version}" != "${VERSION}" ]]; then
    sed -i "s@VERSION=.*@VERSION=${to_version}@g" "${PROJECT_DIR}/static.env"
    export VERSION=${to_version}
  fi
  echo
  verify_upgrade_version
  preflight_check
  update_config_if_need
  echo
  check_compose_install

  echo_yellow "\n2. Loading Docker Image"
  bash "${BASE_DIR}/3_load_images.sh"

  echo_yellow "\n3. Backup database"
  backup_db

  echo_yellow "\n4. Backup Configuration File"
  backup_config

  echo_yellow "\n5. Apply database changes"
  echo "Changing database schema may take a while, please wait patiently"
  db_migrations

  echo_yellow "\n6. Upgrade Docker"
  upgrade_docker
  upgrade_compose

  # 启动并校验健康：失败时旧镜像仍在，按下方指引可完整回滚；健康通过后才询问清理
  if ! start_and_verify; then
    print_rollback_guide
    exit 1
  fi

  echo_yellow "\n8. Cleanup Image"
  clean_images

  installation_log "upgrade"

  echo_yellow "\n9. Upgrade successfully. The new version is running and healthy"
  echo "Manage services: cd ${PROJECT_DIR} && ./xadmin.sh status"
  echo
  print_rollback_guide
  set_current_version
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
