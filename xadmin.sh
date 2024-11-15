#!/usr/bin/env bash
#
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

cd "${PROJECT_DIR}" || exit 1

. "${PROJECT_DIR}/scripts/utils.sh"

action=${1-}
target=${2-}
args=("$@")

function check_config_file() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "未找到配置文件: ${CONFIG_FILE}"
    return 3
  fi
  if [[ -f .env ]]; then
    if ! ls -l .env | grep "${CONFIG_FILE}" &>/dev/null; then
      echo ".env 软连接存在问题, 重新更新"
      rm -f .env
    fi
  fi

  if [[ ! -f ".env" ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi

  if [[ ! -f "./compose/.env" ]]; then
    ln -s "${CONFIG_FILE}" ./compose/.env
  fi
}

function pre_check() {
  check_config_file || return 3
}

function usage() {
  echo "xAdmin Deployment Management Script"
  echo
  echo "Usage: "
  echo "  ./xadmin.sh [COMMAND] [ARGS...]"
  echo "  ./xadmin.sh --help"
  echo
  echo "Installation Commands: "
  echo "  install           Install xAdmin"
  echo "  upgrade           Upgrade xAdmin"
  echo
  echo "Management Commands: "
  echo "  config            Configuration  Tools"
  echo "  start             Start     xAdmin"
  echo "  stop              Stop      xAdmin"
  echo "  restart           Restart   xAdmin"
  echo "  status            Check     xAdmin"
  echo "  down              Offline   xAdmin"
  echo "  uninstall         Uninstall xAdmin"
  echo
  echo "More Commands: "
  echo "  load_image        Loading docker image"
  echo "  backup_db         Backup database"
  echo "  restore_db [file] Data recovery through database backup file"
  echo "  raw               Execute the original docker compose command"
  echo "  tail [service]    View log"
  echo
}

function service_to_docker_name() {
  service=$1
  if [[ "${service:0:3}" != "jms" ]]; then
    service=xadmin-${service}
  fi
  echo "${service}"
}

EXE=""

function start() {
  ${EXE} up -d
}

function stop() {
  if [[ -n "${target}" ]]; then
    ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
    return
  fi
  ${EXE} down -v
}

function close() {
  if [[ -n "${target}" ]]; then
    ${EXE} stop "${target}"
    return
  fi
  services=$(get_docker_compose_services ignore_db)
  for i in ${services}; do
    ${EXE} stop "${i}"
  done
}

function pull() {
   if [[ -n "${target}" ]]; then
    ${EXE} pull "${target}"
    return
  fi
  ${EXE} pull
}

function restart() {
  stop
  echo -e "\n"
  start
}

function check_update() {
  current_version=$(get_current_version)
  latest_version=$(get_latest_version)
  if [[ "${current_version}" == "${latest_version}" ]]; then
    echo_green "The current version is up to date: ${latest_version}"
    echo
    return
  fi
  if [[ -n "${latest_version}" ]] && [[ ${latest_version} =~ v.* ]]; then
    echo -e "\033[32mThe latest version is: ${latest_version}\033[0m"
  else
    exit 1
  fi
}

function main() {
  if [[ "${OS}" == 'Darwin' ]]; then
    echo
    echo "Unsupported Operating System Error"
    exit 0
  fi
  if [[ "${OS}" =~ MINGW.* ]]; then
    echo
    echo "Unsupported Operating System Error"
    exit 0
  fi

  if [[ "${action}" == "help" || "${action}" == "h" || "${action}" == "-h" || "${action}" == "--help" ]]; then
    echo ""
  elif [[ "${action}" == "install" || "${action}" == "config" || "${action}" == "reconfig" ]]; then
    echo ""
  else
    pre_check || return 3
    EXE=$(get_docker_compose_cmd_line)
  fi
  case "${action}" in
  install)
    bash "${SCRIPT_DIR}/4_install_xadmin.sh"
    ;;
  upgrade)
    bash "${SCRIPT_DIR}/7_upgrade.sh" "$target"
    ;;
  check_update)
    check_update
    ;;
  config)
    bash "${SCRIPT_DIR}/config.sh" "$target"
    ;;
  reconfig)
    ${EXE} down -v
    bash "${SCRIPT_DIR}/1_config_xadmin.sh"
    ;;
  start)
    start
    ;;
  restart)
    restart
    ;;
  stop)
    stop
    ;;
  pull)
    pull
    ;;
  close)
    close
    ;;
  status)
    ${EXE} ps
    ;;
  down)
    if [[ -z "${target}" ]]; then
      ${EXE} down -v
    else
      ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
    fi
    ;;
  uninstall)
    bash "${SCRIPT_DIR}/8_uninstall.sh"
    ;;
  backup_db)
    bash "${SCRIPT_DIR}/5_db_backup.sh"
    ;;
  restore_db)
    bash "${SCRIPT_DIR}/6_db_restore.sh" "$target"
    ;;
  load_image)
    bash "${SCRIPT_DIR}/3_load_images.sh"
    ;;
  pull_images)
    pull_images
    ;;
  cmd)
    echo "${EXE}"
    ;;
  tail)
    if [[ -z "${target}" ]]; then
      ${EXE} logs --tail 100 -f
    else
      docker_name=$(service_to_docker_name "${target}")
      docker logs -f "${docker_name}" --tail 100
    fi
    ;;
  show_services)
    get_docker_compose_services
    ;;
  init_db)
    perform_db_migrations
    ;;
  raw)
    ${EXE} "${args[@]:1}"
    ;;
  version)
    get_current_version
    ;;
  help)
    usage
    ;;
  --help)
    usage
    ;;
  -h)
    usage
    ;;
  *)
    echo "No such command: ${action}"
    usage
    ;;
  esac
}

main "$@"
