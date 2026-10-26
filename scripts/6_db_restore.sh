#!/usr/bin/env bash
# 失败即退：离线安装器不允许"半装"状态继续执行（目标机 CentOS 7 自带 bash 4.2，
# 勿用 4.4 才支持的构造：set -u 下展开空数组会报 unbound，须先判 ${#arr[@]}）
set -euo pipefail
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

DB_FILE="$1"
BACKUP_DIR=$(dirname "${DB_FILE}")

DB_ENGINE=$(get_config DB_ENGINE "mysql")
DB_HOST=$(get_config DB_HOST)
# 非交互（演练/自动化）跳过确认：YES_I_KNOW=1 ./xadmin.sh restore_db <file>
YES_I_KNOW=${YES_I_KNOW:-0}

function stop_app_services() {
  # 恢复会 --clean 重建对象，应用连接持有锁会让恢复失败或留下半恢复状态；
  # 强制停服（server 与 celery 全部退出），恢复完成后再由用户显式 start。
  local name
  for name in xadmin-server xadmin-celery-worker xadmin-celery-heavy xadmin-celery-beat; do
    if docker ps --format '{{.Names}}' | grep -qx "${name}"; then
      log_warn "Stopping ${name} before restoring the database"
      docker stop "${name}" >/dev/null || log_warn "Failed to stop ${name}"
    fi
  done
}

function main() {
  # 显式初始化：脚本以 set -u 运行，数据库已在运行时 flag 不会被赋值
  local flag=0
  echo_warn "Make sure you have a backup of data, this operation is not reversible! \n"

  if [[ ! -f "${DB_FILE}" ]]; then
    echo "file does not exist: ${DB_FILE}"
    exit 1
  fi

  if [[ "${YES_I_KNOW}" != "1" ]]; then
    local confirm="n"
    read_from_input confirm "This will overwrite the current database. Continue?" "y/n" "${confirm}"
    if [[ "${confirm}" != "y" ]]; then
      echo "Cancelled"
      exit 0
    fi
  fi

  stop_app_services
  db_images=$(get_db_images)

  echo "Start restoring database: $DB_FILE"

  if ! docker ps | grep -w "xadmin-server" &>/dev/null; then
    create_db_ops_env
    flag=1
  fi
  case "${DB_HOST}" in
    mysql|postgresql)
      while [[ "$(docker inspect -f "{{.State.Health.Status}}" xadmin-${DB_HOST})" != "healthy" ]]; do
        sleep 5s
      done
      ;;
  esac

  case "${DB_ENGINE}" in
    mysql)
      restore_cmd='mariadb -h$DB_HOST -P$DB_PORT -u$DB_USER -p"$DB_PASSWORD" $DB_DATABASE < '${DB_FILE}
      ;;
    postgresql)
      restore_cmd='PGPASSWORD=${DB_PASSWORD} pg_restore --if-exists --clean --no-owner -U $DB_USER -h $DB_HOST -p $DB_PORT -d $DB_DATABASE '${DB_FILE}
      ;;
    *)
      log_error "Invalid DB Engine selection!"
      exit 1
      ;;
  esac

  if ! docker run --rm --env-file=${CONFIG_FILE} -i --network=xadmin_net -v "${BACKUP_DIR}:${BACKUP_DIR}" "${db_images}" bash -c "${restore_cmd}"; then
    log_error "Database recovery failed. Please check whether the database file is complete or try to recover manually!"
    exit 1
  else
    log_success "Database recovered successfully!"
  fi

  if [[ "${flag}" == "1" ]]; then
    down_db_ops_env
  fi
  echo "Services were stopped for the restore. Run './xadmin.sh start' when you are ready."
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  # set -u 下直接引用 $1 会在「无参」时 unbound 中止（用户看不到用法提示）
  if [[ -z "${1:-}" ]]; then
    log_error "Format error! Usage: './xadmin.sh restore_db DB_Backup_file'"
    exit 1
  fi
  if [[ ! -f "${1}" ]]; then
    echo "The backup file does not exist: ${1}"
    exit 1
  fi
  main
fi