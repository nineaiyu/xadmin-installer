#!/usr/bin/env bash
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

. "${BASE_DIR}/utils.sh"

action=${1-}
flag=0

function usage() {
    echo "Usage: "
    echo "  ./xadmin.sh config [ARGS...]"
    echo "  -h, --help"
    echo
    echo "Args: "
    echo "  ntp              Configuration ntp sync"
    echo "  init             Initialize configuration file"
    echo "  port             Configuration service port"
    echo "  ssl              Configuration web ssl"
    echo "  env              Configuration xadmin environment"
}

function backup_config() {
  volume_dir=$(get_config VOLUME_DIR)
  backup_dir="${volume_dir}/config_backup"
  backup_config_file="${backup_dir}/config.conf-$(date +%F_%T)"
  if [[ ! -d ${backup_dir} ]]; then
    mkdir -p "${backup_dir}"
  fi
  cp -f "${CONFIG_FILE}" "${backup_config_file}"
}

function restart_service() {
    confirm="n"
    read_from_input confirm "Do you want to restart the service?" "y/n" "${confirm}"
    if [[ "${confirm}" == "y" ]]; then
        xadmin restart
    fi
}

function set_ntp() {
    command -v ntpdate >/dev/null || {
        log_error "ntpdate is not installed, please install it first"
        exit 1
    }
    ntp_server="ntp.aliyun.com"
    read_from_input ntp_server "Please enter NTP SERVER" "" "${ntp_server}"
    ntpdate -u "${ntp_server}"
}

function set_port() {
    web_enable=$(get_config WEB_ENABLE)

    if [[ "${web_enable}" != "0" ]]; then
        http_port=$(get_config HTTP_PORT)
        https_port=$(get_config HTTPS_PORT)

        read_from_input http_port "Please enter HTTP PORT" "" "${http_port}"
        set_config HTTP_PORT "${http_port}"
        if [ -n "${https_port}" ]; then
            read_from_input https_port "Please enter HTTPS PORT" "" "${https_port}"
            set_config HTTPS_PORT "${https_port}"
        fi
    fi
    flag=1
}

function set_ssl() {
    http_port=$(get_config HTTP_PORT)
    https_port=$(get_config HTTPS_PORT)
    server_name=$(get_config SERVER_NAME)
    ssl_certificate=$(get_config SSL_CERTIFICATE)
    ssl_certificate_key=$(get_config SSL_CERTIFICATE_KEY)
    ssl_certificate_file=''
    ssl_certificate_key_file=''

    read_from_input http_port "Please enter HTTP PORT" "" "${http_port}"
    read_from_input https_port "Please enter HTTPS PORT" "" "${https_port}"
    read_from_input server_name "Please enter SERVER NAME" "" "${server_name}"

    if [[ -z "${ssl_certificate}" ]]; then
        ssl_certificate="${server_name}.pem"
    fi
    if [[ -z "${ssl_certificate_key}" ]]; then
        ssl_certificate_key="${server_name}.key"
    fi

    read_from_input ssl_certificate_file "Please enter SSL CERTIFICATE FILE Absolute path" "" "${ssl_certificate_file}"
    if [[ ! -f "${ssl_certificate_file}" ]]; then
        log_error "SSL CERTIFICATE FILE not exists: ${ssl_certificate_file}"
        exit 1
    fi
    cp -f "${ssl_certificate_file}" "${CONFIG_DIR}/nginx/cert/${ssl_certificate}"
    chmod 600 "${CONFIG_DIR}/nginx/cert/${ssl_certificate}"

    read_from_input ssl_certificate_key_file "Please enter SSL CERTIFICATE KEY FILE Absolute path" "" "${ssl_certificate_key_file}"
    if [[ ! -f "${ssl_certificate_key_file}" ]]; then
        log_error "SSL CERTIFICATE KEY FILE not exists: ${ssl_certificate_key_file}"
        exit 1
    fi
    cp -f "${ssl_certificate_key_file}" "${CONFIG_DIR}/nginx/cert/${ssl_certificate_key}"
    chmod 600 "${CONFIG_DIR}/nginx/cert/${ssl_certificate_key}"

    set_config HTTP_PORT "${http_port}"
    set_config HTTPS_PORT "${https_port}"
    set_config SERVER_NAME "${server_name}"
    set_config SSL_CERTIFICATE "${ssl_certificate}"
    set_config SSL_CERTIFICATE_KEY "${ssl_certificate_key}"
    flag=1
}

function set_env() {
    while true; do
        key=''
        value=''
        read_from_input key "Please enter the environment variable key" "" "${key}"
        if [[ -z "${key}" ]]; then
            break
        fi
        default_value=$(get_config "${key}")

        if [[ -n "${default_value}" ]]; then
            value="${default_value}"
        fi
        read_from_input value "Please enter the environment variable value" "" "${value}"
        echo ""
        if [[ "${value}" != "${default_value}" ]]; then
            echo_yellow "The operation changes are as follows"
            echo "(old) ${key}: ${default_value}"
            echo "(new) ${key}: ${value}"

            confirm="n"
            read_from_input confirm "Do you want to update the environment variable?" "y/n" "${confirm}"
            if [[ "${confirm}" != "y" ]]; then
                break
            fi
            set_config "${key}" "${value}"
            flag=1
        else
            echo_yellow "The environment variable has not changed"
        fi

        echo ""
        confirm="n"
        read_from_input confirm "Do you want to continue to add environment variables?" "y/n" "${confirm}"
        if [[ "${confirm}" != "y" ]]; then
            break
        fi
        echo ""
    done
}

function main() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "Configuration file not found: ${CONFIG_FILE}"
        exit 1
    fi

    case "${action}" in
    init)
        prepare_config
        ;;
    port)
        backup_config
        set_port
        ;;
    ntp)
        set_ntp
        ;;
    ssl)
        backup_config
        set_ssl
        ;;
    env)
        backup_config
        set_env
        ;;
    -h | --help)
        usage
        ;;
    *)
        usage
        ;;
    esac
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi

if [[ "${flag}" == "1" ]]; then
    restart_service
fi
