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
      command -v gettext &>/dev/null || {
      apk add -q gettext-dev python3
    }
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
  echo "download install script to /opt/xadmin-installer-${VERSION}"
  cd /opt || exit 1
  if [ ! -d "/opt/xadmin-installer-${VERSION}" ]; then
    timeout 60 wget -qO xadmin-installer-${VERSION}.tar.gz ${DOWNLOAD_URL}/nineaiyu/xadmin-installer/releases/download/${VERSION}/xadmin-installer-${VERSION}.tar.gz || {
      rm -f /opt/xadmin-installer-${VERSION}.tar.gz
      echo -e "[\033[31m ERROR \033[0m] Failed to download xadmin-installer-${VERSION}"
      exit 1
    }
    tar -xf /opt/xadmin-installer-${VERSION}.tar.gz -C /opt || {
      rm -rf /opt/xadmin-installer-${VERSION}
      echo -e "[\033[31m ERROR \033[0m] Failed to unzip xadmin-installer-${VERSION}"
      exit 1
    }
    rm -f /opt/xadmin-installer-${VERSION}.tar.gz
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
