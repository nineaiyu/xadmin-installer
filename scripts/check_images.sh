#!/usr/bin/env bash
# 第三方镜像核对（季度维护流程，见 README「季度镜像核对」）。
#
# 背景：本包没有 renovate（离线安装包形态，镜像版本手工固定），
# 第三方基础镜像的更新完全靠人工 —— 本脚本把「核对」固定为可复算的三步：
#   1) 列出 compose 里固定的第三方镜像与版本（含 base-images.yml 的离线镜像映射）；
#   2) --online 时逐个 `docker manifest inspect` 确认 tag 仍可解析并打印 digest（留档）；
#   3) --check-mapping 时校验每个第三方镜像都有离线映射（漏映射 = 离线安装拉不到镜像）。
#
# 用法：
#   bash scripts/check_images.sh                     # 打印 Markdown 表格（贴季度核对记录）
#   bash scripts/check_images.sh --online            # 追加 registry digest（需联网）
#   bash scripts/check_images.sh --check-mapping     # 只做映射完整性校验（CI / 发版前）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
COMPOSE_DIR="${ROOT}/compose"
MAPPING_FILE="${ROOT}/utils/base-images.yml"

ONLINE=0
CHECK_ONLY=0
for arg in "$@"; do
    case "${arg}" in
        --online) ONLINE=1 ;;
        --check-mapping) CHECK_ONLY=1 ;;
        -h | --help)
            sed -n '2,20p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "未知参数：${arg}" >&2
            exit 2
            ;;
    esac
done

# 第三方镜像 = compose 中 image: 不含 ${VERSION} 的行（自有镜像由 static.env 的 VERSION 决定）
collect_images() {
    local file line image
    for file in "${COMPOSE_DIR}"/*.yml; do
        while IFS= read -r line; do
            image="${line#*image:}"
            image="$(echo "${image}" | tr -d '[:space:]')"
            [[ -z "${image}" ]] && continue
            [[ "${image}" == *'${VERSION}'* ]] && continue
            printf '%s\t%s\n' "${image}" "$(basename "${file}")"
        done < <(grep -h 'image:' "${file}" 2> /dev/null || true)
    done
}

mapping_for() {
    # base-images.yml 是 "上游镜像（含 tag 与冒号）: 离线镜像" 的映射，按上游键取值
    local key=$1
    sed -n "s|^\"${key}\": *||p" "${MAPPING_FILE}" 2> /dev/null | head -n 1 | tr -d '"'
}

missing=0
rows=""
while IFS=$'\t' read -r image source; do
    [[ -z "${image}" ]] && continue
    upstream="docker.io/library/${image}"
    mapped="$(mapping_for "${upstream}")"
    mapped="${mapped//\"/}"
    if [[ -z "${mapped}" ]]; then
        missing=$((missing + 1))
        mapped="**缺失**"
    fi
    if [[ "${CHECK_ONLY}" == "1" ]]; then
        continue
    fi
    if [[ "${ONLINE}" == "1" ]]; then
        digest=""
        if command -v docker > /dev/null 2>&1; then
            digest="$(docker manifest inspect "${image}" 2> /dev/null | grep -m1 '"digest"' | sed 's/.*"digest": "//; s/".*//' || true)"
        fi
        rows+="| ${image} | ${source} | ${mapped} | ${digest:-unresolved} |"$'\n'
    else
        rows+="| ${image} | ${source} | ${mapped} |"$'\n'
    fi
done < <(collect_images)

if [[ "${CHECK_ONLY}" == "1" ]]; then
    if [[ "${missing}" -gt 0 ]]; then
        echo "第三方镜像缺少离线映射（utils/base-images.yml）：${missing} 个" >&2
        exit 1
    fi
    echo "镜像映射完整：compose 的第三方镜像均有离线映射。"
    exit 0
fi

echo "# 第三方镜像核对（生成时间：$(date '+%F %T')）"
echo
if [[ "${ONLINE}" == "1" ]]; then
    echo "| 镜像 | 引用处 | 离线镜像映射 | registry digest |"
    echo "|---|---|---|---|"
else
    echo "| 镜像 | 引用处 | 离线镜像映射 |"
    echo "|---|---|---|"
fi
printf '%s' "${rows}"
echo
echo "上游更新核对：对照 Docker Hub / 上游 release note 检查是否有安全更新（季度流程第 2 步）。"
if [[ "${missing}" -gt 0 ]]; then
    echo "警告：${missing} 个镜像缺少离线映射（离线安装会拉不到）——补 utils/base-images.yml。" >&2
    exit 1
fi
