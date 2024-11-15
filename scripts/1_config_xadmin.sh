#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

function set_secret_key() {
  echo_yellow "1. Configure Private Key"
  secret_key=$(get_config SECRET_KEY)
  if [[ -z "${secret_key}" ]]; then
    secret_key=$(random_str 48)
    set_config SECRET_KEY "${secret_key}"
    echo "SECRETE_KEY:     ${secret_key}"
  fi
  if command -v hostname&>/dev/null; then
    SERVER_HOSTNAME=$(hostname)
    set_config SERVER_HOSTNAME "${SERVER_HOSTNAME}"
  fi
}

function set_volume_dir() {
  echo_yellow "\n2. Configure Persistent Directory"
  volume_dir=$(get_config VOLUME_DIR "/opt/xadmin")
  confirm="n"
  read_from_input confirm "Do you need custom persistent store, will use the default directory ${volume_dir}?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    echo
    echo "To modify the persistent directory such as logs video, you can select your largest disk and create a directory in it, such as /data/xadmin"
    echo "Note: you can not change it after installation, otherwise the database may be lost"
    echo
    df -h | grep -Ev "devfs|tmpfs|overlay|shm|snap|boot"
    echo
    read_from_input volume_dir "Persistent storage directory" "" "${volume_dir}"
    if [[ "${volume_dir}" == "y" ]]; then
      echo_failed
      echo
      set_volume_dir
    fi
  fi
  if [[ ! -d "${volume_dir}" ]]; then
    mkdir -p ${volume_dir}
    chmod 700 ${volume_dir}
  fi
  set_config VOLUME_DIR ${volume_dir}
}

function set_db_config() {
  local db_engine=$1
  local db_host=$2
  local db_port=$3
  local db_user=$4
  local db_password=$5
  local db_name=$6

  set_config DB_ENGINE "${db_engine}"
  set_config DB_HOST "${db_host}"
  set_config DB_PORT "${db_port}"
  set_config DB_USER "${db_user}"
  set_config DB_PASSWORD "${db_password}"
  set_config DB_DATABASE "${db_name}"
}

function set_external_db() {
  local db_engine=$1
  db_host=$(get_config DB_HOST)
  read_from_input db_host "Please enter DB server IP" "" "${db_host}"
  if [[ "${db_host}" == "127.0.0.1" || "${db_host}" == "localhost" ]]; then
    log_error "Can not use localhost as DB server IP"
  fi
  db_port=$(get_config DB_PORT)
  read_from_input db_port "Please enter DB server port" "" "${db_port}"
  db_name=$(get_config DB_DATABASE)
  read_from_input db_name "Please enter DB database name" "" "${db_name}"
  db_user=$(get_config DB_USER)
  read_from_input db_user "Please enter DB username" "" "${db_user}"
  db_password=$(get_config DB_PASSWORD)
  read_from_input db_password "Please enter DB password" "" "${db_password}"

  set_db_config "${db_engine}" "${db_host}" "${db_port}" "${db_user}" "${db_password}" "${db_name}"
}

function set_internal_db() {
  local db_engine=$1
  local db_host=$2
  local db_port=$3
  local db_user=$4
  db_password=$(get_config DB_PASSWORD)
  if [[ -z "${db_password}" ]]; then
    db_password=$(random_str 26)
  fi
  db_name=$(get_config DB_DATABASE)
  if [[ -z "${db_name}" ]]; then
    db_name=server
  fi

  set_db_config "${db_engine}" "${db_host}" "${db_port}" "${db_user}" "${db_password}" "${db_name}"
}

function set_db() {
  echo_yellow "\n3. Configure DB"
  db_engine=$(get_config DB_ENGINE "mysql")
  db_host=$(get_config DB_HOST)

  case "${db_engine}" in
    mysql)
      confirm="n"
      if [[ "${db_host}" != "mysql" ]]; then
        confirm="y"
      fi
      read_from_input confirm "Do you want to use external MySQL?" "y/n" "${confirm}"
      if [[ "${confirm}" == "y" ]]; then
        set_external_db "mysql"
      else
        set_internal_db "mysql" "mysql" "3306" "root"
      fi
      ;;
    postgresql)
      confirm="n"
      if [[ "${db_host}" != "postgresql" ]]; then
        confirm="y"
      fi
      read_from_input confirm "Do you want to use external PostgreSQL?" "y/n" "${confirm}"
      if [[ "${confirm}" == "y" ]]; then
        set_external_db "postgresql"
      else
        set_internal_db "postgresql" "postgresql" "5432" "postgres"
      fi
      ;;
    *)
      echo "Invalid DB Engine selection"
      exit 1
      ;;
  esac
}

function set_external_redis() {
  redis_host=$(get_config REDIS_HOST)
  read_from_input redis_host "Please enter Redis server IP" "" "${redis_host}"
  if [[ "${redis_host}" == "127.0.0.1" || "${redis_host}" == "localhost" ]]; then
    log_error "Can not use localhost as Redis server IP"
  fi
  redis_port=$(get_config REDIS_PORT)
  read_from_input redis_port "Please enter Redis server port" "" "${redis_port}"
  redis_password=$(get_config REDIS_PASSWORD)
  read_from_input redis_password "Please enter Redis password" "" "${redis_password}"

  set_config REDIS_HOST "${redis_host}"
  set_config REDIS_PORT "${redis_port}"
  set_config REDIS_PASSWORD "${redis_password}"
}

function set_internal_redis() {
  redis_password=$(get_config REDIS_PASSWORD)
  if [[ -z "${redis_password}" ]]; then
    REDIS_PASSWORD=$(random_str 26)
    set_config REDIS_PASSWORD "${REDIS_PASSWORD}"
  fi
  disable_config REDIS_SENTINEL_HOSTS
  disable_config REDIS_SENTINEL_PASSWORD
  set_config REDIS_HOST redis
  set_config REDIS_PORT 6379
}

function set_redis() {
  echo_yellow "\n4. Configure Redis"
  redis_host=$(get_config REDIS_HOST)
  confirm="n"
  if [[ "${redis_host}" != "redis" ]]; then
      confirm="y"
  fi
  read_from_input confirm "Do you want to use external Redis?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
      set_external_redis
  else
      set_internal_redis
  fi
}

function set_service() {
  echo_yellow "\n5. Configure External Access"
  http_port=$(get_config HTTP_PORT)
  confirm="n"
  read_from_input confirm "Do you need to customize the xAdmin external port?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    read_from_input http_port "xAdmin web port" "" "${http_port}"
    set_config HTTP_PORT "${http_port}"
  fi
}

function init_db() {
  echo_yellow "\n6. Init xAdmin Database"
  if ! perform_db_migrations; then
    log_error "Failed to change the table structure!"
    exit 1
  fi
}

function main() {
  if set_secret_key; then
    echo_done
  fi
  if set_volume_dir; then
    echo_done
  fi
  if set_db; then
    echo_done
  fi
  if set_redis; then
    echo_done
  fi
  if set_service; then
    echo_done
  fi
  if init_db; then
    echo_done
  fi
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
