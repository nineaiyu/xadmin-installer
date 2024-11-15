#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

function stop_services() {
  docker compose version &>/dev/null || return
  if [ -f "${CONFIG_FILE}" ]; then
    cd "${PROJECT_DIR?}" || exit 1
    bash ./xadmin.sh down
    sleep 2s
    echo
  fi
}

function remove_xadmin_ctl() {
  if check_root && [ -f "/usr/bin/xadmin" ]; then
    echo -e "Cleaning up /usr/bin/xadmin"
    rm -f /usr/bin/xadmin
  fi
}

function remove_docker() {
  if check_root && [ -f "/etc/systemd/system/docker.service" ]; then
    echo
    confirm="n"
    read_from_input confirm "Do you need to clean up the Docker binaries?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      systemctl stop docker
      systemctl disable docker
      systemctl daemon-reload
      echo -e "Cleaning up /usr/local/bin/docker"
      rm -f /usr/local/bin/docker*
      rm -f /usr/local/bin/container*
      rm -f /usr/local/bin/ctr
      rm -f /usr/local/bin/runc
      echo -e "Cleaning up /etc/systemd/system/docker.service"
      rm -f /etc/systemd/system/docker.service
    fi
  fi
}

function remove_compose() {
  if check_root && [ -f "/usr/local/libexec/docker/cli-plugins/docker-compose" ]; then
    echo
    confirm="n"
    read_from_input confirm "Do you need to clean up the Docker Compose binaries?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo -e "Cleaning up /usr/local/libexec/docker/cli-plugins/docker-compose"
      rm -f /usr/local/libexec/docker/cli-plugins/docker-compose
    fi
  fi
  if [ -f "$HOME/.docker/cli-plugins/docker-compose" ]; then
    echo
    confirm="n"
    read_from_input confirm "Do you need to clean up the Docker Compose binaries?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
      echo -e "Cleaning up $HOME/.docker/cli-plugins/docker-compose"
      rm -f $HOME/.docker/cli-plugins/docker-compose
    fi
  fi
}

function remove_xadmin() {
  if [ ! -f "${CONFIG_FILE}" ]; then
    return
  fi
  echo
  echo_warn "Make sure you have a backup of data, this operation is not reversible! \n"
  images=$(get_images)
  volume_dir=$(get_config VOLUME_DIR)
  confirm="n"
  read_from_input confirm "Are you clean up xAdmin files?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    if [[ -d "${volume_dir}" ]]; then
      echo -e "Cleaning up ${volume_dir}"
      rm -rf "${volume_dir?}"
    fi
    if [[ -d "${CONFIG_DIR}" ]]; then
      echo -e "Cleaning up ${CONFIG_DIR}"
      rm -rf "${CONFIG_DIR?}"
      rm -f .env compose/.env
    fi
  fi
  echo
  confirm="n"
  read_from_input confirm "Do you need to clean up the Docker image?" "y/n" "${confirm}"
  if [[ "${confirm}" == "y" ]]; then
    for image in ${images}; do
      docker rmi "${image}"
      echo
    done
  fi
  echo_green "Cleanup complete!"
}

function main() {
  echo_yellow "\n>>> Uninstall xAdmin"
  stop_services
  installation_log "uninstall"
  remove_xadmin_ctl
  remove_xadmin
  remove_compose
  remove_docker
}

main