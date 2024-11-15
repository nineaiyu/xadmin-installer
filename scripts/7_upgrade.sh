#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"
. "${BASE_DIR}/2_install_docker.sh"

target=$1

function verify_upgrade_version() {
  required_version="v3.10.11"
  current_version=$(get_config CURRENT_VERSION)

  if ! [[ $current_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    return
  fi

  if [[ -z "${current_version}" ]]; then
    log_error "The current version is not detected, please check"
    exit 1
  fi

  if [ "$(printf '%s\n' "$required_version" "$current_version" | sort -V | head -n1)" != "$required_version" ]; then
    log_error "Your current version does not meet the minimum requirements. Please upgrade to ${required_version}"
    exit 1
  fi
}

function check_and_set_config() {
  local config_key=$1
  local default_value=$2
  local current_value=$(get_config ${config_key})
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
  if [[ "${SKIP_BACKUP_DB}" != "1" ]]; then
    if ! bash "${SCRIPT_DIR}/5_db_backup.sh"; then
      confirm="n"
      read_from_input confirm "Failed to backup the database. Continue to upgrade?" "y/n" "${confirm}"
      if [[ "${confirm}" == "n" ]]; then
        exit 1
      fi
    fi
  else
    echo "SKIP_BACKUP_DB=${SKIP_BACKUP_DB}, Skip database backup"
  fi
}

function db_migrations() {
  if docker ps | grep -E "server"&>/dev/null; then
    confirm="y"
    read_from_input confirm "Detected that the xAdmin container is running. Do you want to close the container and continue to upgrade?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo
      cd "${PROJECT_DIR}" || exit 1
      bash ./xadmin.sh stop
      sleep 2s
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
}

function clean_images() {
  current_version=$(get_config CURRENT_VERSION)
  if [[ "${current_version}" != "${to_version}" ]]; then
    old_images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "nineaiyu/" | grep "${current_version}")
    if [[ -n "${old_images}" ]]; then
      confirm="y"
      read_from_input confirm "Do you need to clean up the old version image?" "y/n" "${confirm}"
      if [[ "${confirm}" == "y" ]]; then
        echo "${old_images}" | xargs docker rmi -f
      fi
    fi
  fi
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
  if check_root && [[ -f "/usr/local/libexec/docker/cli-plugins/docker-compose" || -f "$HOME/.docker/cli-plugins/docker-compose" ]]; then
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

  echo_yellow "\n6. Cleanup Image"
  clean_images

  echo_yellow "\n7. Upgrade Docker"
  upgrade_docker
  upgrade_compose

  installation_log "upgrade"

  echo_yellow "\n8. Upgrade successfully. You can now restart the program"
  echo "cd ${PROJECT_DIR}"
  echo "./xadmin.sh start"
  echo -e "\n"
  set_current_version
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
