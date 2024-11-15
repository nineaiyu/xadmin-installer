#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

function pre_install() {
  if ! command -v systemctl &>/dev/null; then
    docker version &>/dev/null || {
      log_error "The current Linux system does not support systemd management. Please deploy docker by yourself before running this script again"
      exit 1
    }
    docker compose version &>/dev/null || {
      log_error "The current Linux system does not support systemd management. Please deploy docker-compose by yourself before running this script again"
      exit 1
    }
  fi
}

function post_install() {
  echo_green "\n>>> The Installation is Complete"
  host=$(get_host_ip)
  if [[ -z "${host}" ]]; then
    host="127.0.0.1"
  fi
  http_port=$(get_config HTTP_PORT)
  https_port=$(get_config HTTPS_PORT)
  server_name=$(get_config SERVER_NAME)

  echo_yellow "1. You can use the following command to start, and then visit"
  echo "cd ${PROJECT_DIR}"
  echo "./xadmin.sh start"

  echo_yellow "\n2. Other management commands"
  echo "./xadmin.sh stop"
  echo "./xadmin.sh restart"
  echo "./xadmin.sh backup"
  echo "./xadmin.sh upgrade"
  echo "For more commands, you can enter ./xadmin.sh --help to understand"

  echo_yellow "\n3. Web access"
  if [ -n "${server_name}" ] && [ -n "${https_port}" ]; then
    echo "https://${server_name}:${https_port}"
  else
    echo "http://${host}:${http_port}"
  fi

  echo_yellow "\n More information"
  echo "Documentation: https://docs.dvcloud.xin/"
  echo -e "\n"
}

function main() {
  echo_logo
  pre_install
  prepare_config
  set_current_version

  echo_green "\n>>> Install and Configure Docker"
  if ! bash "${BASE_DIR}/2_install_docker.sh"; then
    exit 1
  fi

  echo_green "\n>>> Loading Docker Image"
  if ! bash "${BASE_DIR}/3_load_images.sh"; then
    exit 1
  fi
  echo_green "\n>>> Install and Configure xAdmin"
  if ! bash "${BASE_DIR}/1_config_xadmin.sh"; then
    exit 1
  fi
  installation_log "install"
  post_install
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
