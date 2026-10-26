#!/usr/bin/env bash
#

VERSION=dev
DOWNLOAD_URL=https://github.com

function install_soft() {
    if command -v dnf &>/dev/null; then
      dnf -q -y install "$1"
    elif command -v yum &>/dev/null; then
      yum -q -y install "$1"
    elif command -v apt &>/dev/null; then
      apt-get -qqy install "$1"
    elif command -v zypper &>/dev/null; then
      zypper -q -n install "$1"
    elif command -v apk &>/dev/null; then
      apk add -q "$1"
    else
      echo -e "[\033[31m ERROR \033[0m] $1 command not found, Please install it first"
      exit 1
    fi
}

function prepare_install() {
  for i in curl wget tar iptables; do
    command -v $i &>/dev/null || install_soft $i
  done
}

function get_installer() {
  local tarball="/opt/xadmin-installer-${VERSION}.tar.gz"
  local md5_file="${tarball}.md5"
  local release_url="${DOWNLOAD_URL}/nineaiyu/xadmin-installer/releases/download/${VERSION}"
  echo "download install script to /opt/xadmin-installer-${VERSION}"
  cd /opt || exit 1
  if [ ! -d "/opt/xadmin-installer-${VERSION}" ]; then
    timeout 60 wget -qO "${tarball}" "${release_url}/xadmin-installer-${VERSION}.tar.gz" || {
      rm -f "${tarball}"
      echo -e "[\033[31m ERROR \033[0m] Failed to download xadmin-installer-${VERSION}"
      exit 1
    }
    # 供应链完整性：校验同 Release 的 .md5；缺失或不匹配一律拒绝安装（fail-closed）
    timeout 60 wget -qO "${md5_file}" "${release_url}/xadmin-installer-${VERSION}.tar.gz.md5" || {
      rm -f "${tarball}" "${md5_file}"
      echo -e "[\033[31m ERROR \033[0m] Failed to download checksum for xadmin-installer-${VERSION}; refusing to install"
      exit 1
    }
    if ! (cd /opt && md5sum -c "$(basename "${md5_file}")" >/dev/null 2>&1); then
      rm -f "${tarball}" "${md5_file}"
      echo -e "[\033[31m ERROR \033[0m] Checksum verification failed for xadmin-installer-${VERSION}"
      exit 1
    fi
    rm -f "${md5_file}"
    tar -xf "${tarball}" -C /opt || {
      rm -rf "/opt/xadmin-installer-${VERSION}" "${tarball}"
      echo -e "[\033[31m ERROR \033[0m] Failed to unzip xadmin-installer-${VERSION}"
      exit 1
    }
    rm -f "${tarball}"
  fi
}

function config_installer() {
  cd /opt/xadmin-installer-${VERSION} || exit 1
  ./xadmin.sh install
  ./xadmin.sh start
}

function main(){
  if [[ "${OS}" == 'Darwin' ]]; then
    echo
    echo "Unsupported Operating System Error"
    exit 1
  fi
  prepare_install
  get_installer
  config_installer
}

main
