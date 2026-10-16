#!/usr/bin/env bash
# 失败即退：离线安装器不允许"半装"状态继续执行（目标机 CentOS 7 自带 bash 4.2，
# 勿用 4.4 才支持的构造：set -u 下展开空数组会报 unbound，须先判 ${#arr[@]}）
set -euo pipefail
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

VOLUME_DIR=$(get_config VOLUME_DIR)
BACKUP_DIR="${VOLUME_DIR}/db_backup"
CURRENT_VERSION=$(get_config CURRENT_VERSION)

DB_ENGINE=$(get_config DB_ENGINE "mysql")
DB_HOST=$(get_config DB_HOST)
DB_DATABASE=$(get_config DB_DATABASE)

function main() {
  # 显式初始化：脚本以 set -u 运行，数据库已在运行时 flag 不会被赋值
  local flag=0
  if [[ ! -d ${BACKUP_DIR} ]]; then
    mkdir -p ${BACKUP_DIR}
  fi
  echo "Backing up..."

  db_images=$(get_db_images)

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
      DB_FILE=${BACKUP_DIR}/${DB_DATABASE}-${CURRENT_VERSION}-$(date +%F_%T).sql
      backup_cmd='mariadb-dump --skip-add-locks --skip-lock-tables --single-transaction -h$DB_HOST -P$DB_PORT -u$DB_USER -p"$DB_PASSWORD" $DB_DATABASE > '${DB_FILE}
      ;;
    postgresql)
      DB_FILE=${BACKUP_DIR}/${DB_DATABASE}-${CURRENT_VERSION}-$(date +%F_%T).dump
      backup_cmd='PGPASSWORD=${DB_PASSWORD} pg_dump --format=custom --no-owner -U $DB_USER -h $DB_HOST -p $DB_PORT -d "$DB_DATABASE" -f '${DB_FILE}
      ;;
    *)
      log_error "Invalid DB Engine selection!"
      exit 1
      ;;
  esac

  if ! docker run --rm --env-file=${CONFIG_FILE} -i --network=xadmin_net -v "${BACKUP_DIR}:${BACKUP_DIR}" "${db_images}" bash -c "${backup_cmd}"; then
    log_error "Backup failed!"
    log_error "Backup failed!"
    rm -f "${DB_FILE}"
    exit 1
  else
    log_success "Backup succeeded! The backup file has been saved to: ${DB_FILE}"
  fi

  if [[ "${flag}" == "1" ]]; then
    down_db_ops_env
  fi
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi