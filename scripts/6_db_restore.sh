#!/usr/bin/env bash
# 失败即退：离线安装器不允许"半装"状态继续执行（目标机 CentOS 7 自带 bash 4.2，
# 勿用 4.4 才支持的构造：set -u 下展开空数组会报 unbound，须先判 ${#arr[@]}）
set -euo pipefail
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

# 参数与存在性检查集中在顶部：set -u 下顶层先引用裸 $1 会在「无参直调」时以
# unbound 中止，底部的友好用法提示永远走不到（经 xadmin.sh 传空串调用同样命中这里）
DB_FILE="${1:-}"
if [[ -z "${DB_FILE}" ]]; then
  log_error "Format error! Usage: './xadmin.sh restore_db DB_Backup_file'"
  exit 1
fi
if [[ ! -f "${DB_FILE}" ]]; then
  echo "The backup file does not exist: ${DB_FILE}"
  exit 1
fi
BACKUP_DIR=$(dirname "${DB_FILE}")

DB_ENGINE=$(get_config DB_ENGINE "mysql")
DB_HOST=$(get_config DB_HOST)
# 非交互（演练/自动化）跳过确认：YES_I_KNOW=1 ./xadmin.sh restore_db <file>
YES_I_KNOW=${YES_I_KNOW:-0}

function stop_app_services() {
  # 恢复会 --clean 重建对象，应用连接持有锁会让恢复失败或留下半恢复状态；
  # 强制停服（server 与 celery 全部退出），恢复完成后再由用户显式 start。
  # celery 按候选名单停「实际在跑」的容器：安装器是单容器 xadmin-celery，
  # 拆分形态（worker/heavy/beat）同样覆盖，写死单一形态会让另一种形态停不掉
  local name
  for name in xadmin-server $(celery_container_candidates); do
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

  # 备份格式预检提示：本脚本恢复安装器 backup_db 的产物——PG custom 格式
  # （首 5 字节 PGDMP，pg_restore 恢复）；server 仓 ops/db_backup.sh 的纯 SQL
  # （.sql.gz）备份与这里不兼容，误用会落到难以理解的 pg_restore 报错
  if [[ "${DB_ENGINE}" == "postgresql" && "$(head -c 5 "${DB_FILE}")" != "PGDMP" ]]; then
    log_warn "Not a PostgreSQL custom-format dump: if this is an ops/db_backup.sh plain-SQL(.sql.gz) backup, it cannot be restored here"
    log_warn "Plain SQL restore: gunzip -c <file> | docker exec -i xadmin-postgresql psql -U <DB_USER> -d <DB_DATABASE>"
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
      # 有界等待（300s）替代无超时轮询：DB 卡在 unhealthy 时恢复快速失败，不无限挂起
      if ! wait_container_healthy "xadmin-${DB_HOST}" 300; then
        log_error "Database container xadmin-${DB_HOST} failed to become healthy; check 'docker logs xadmin-${DB_HOST}'"
        exit 1
      fi
      ;;
  esac

  case "${DB_ENGINE}" in
    mysql)
      restore_cmd='mariadb -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" "$DB_DATABASE" < "$DB_FILE"'
      ;;
    postgresql)
      restore_cmd='PGPASSWORD="$DB_PASSWORD" pg_restore --if-exists --clean --no-owner -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_DATABASE" "$DB_FILE"'
      ;;
    *)
      log_error "Invalid DB Engine selection!"
      exit 1
      ;;
  esac

  # 备份文件路径经 DB_FILE 环境变量传入容器（路径含空格/元字符时不再拼进命令串）
  if ! docker run --rm --env-file="${CONFIG_FILE}" -e DB_FILE="${DB_FILE}" -i --network=xadmin_net -v "${BACKUP_DIR}:${BACKUP_DIR}" "${db_images}" bash -c "${restore_cmd}"; then
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
  main
fi
