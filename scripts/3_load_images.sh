#!/usr/bin/env bash
# 失败即退：离线安装器不允许"半装"状态继续执行（目标机 CentOS 7 自带 bash 4.2，
# 勿用 4.4 才支持的构造：set -u 下展开空数组会报 unbound，须先判 ${#arr[@]}）
set -euo pipefail
#
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

cd "${BASE_DIR}" || return
IMAGE_DIR="images"

function load_image_files() {
  images=$(get_images)
  for image in ${images}; do
    filename=$(basename "${image}").zst
    filename_windows=${filename/:/_}
    if [[ -f ${IMAGE_DIR}/${filename_windows} ]]; then
      filename=${filename_windows}
    fi
    if [[ ! -f ${IMAGE_DIR}/${filename} ]]; then
      echo_red "Docker image not found: ${IMAGE_DIR}/${filename}"
      continue
    fi

    echo -n "${image} <= ${IMAGE_DIR}/${filename} "
    md5_filename=$(basename "${image}").md5
    md5_path=${IMAGE_DIR}/${md5_filename}
    image_id=$(docker inspect -f "{{.ID}}" "${image}" 2&>/dev/null || echo "")
    saved_id=""

    if [[ -f "${md5_path}" ]]; then
      saved_id=$(cat "${md5_path}")
    fi
    if [[ ${image_id} != "${saved_id}" ]]; then
      echo
      docker load <"${IMAGE_DIR}/${filename}"
    else
      echo "Docker image loaded, skipping"
    fi
  done
}

function main() {
  if [[ -d "${IMAGE_DIR}" && $(find "${IMAGE_DIR}" -type f -name "*.zst" -print -quit 2>/dev/null) ]]; then
    load_image_files
  else
    pull_images
  fi
  echo_done
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
