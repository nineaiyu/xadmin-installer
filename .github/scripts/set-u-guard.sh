#!/usr/bin/env bash
# 安装器「set -u 未定义变量」运行期守护。
#
# 背景：安装器全部脚本以 set -euo pipefail 运行，而 scripts-check 只做 bash -n
# 语法校验——「引用未初始化变量」这类运行期中止语法完全合法，检查不出来。
# 实际事故：prepare_check_required_pkg 里的 flag 只在「命令缺失」分支赋值，
# 依赖齐全的新机器上引用 $flag 直接 unbound 中止，安装停在「Install Docker」，
# 磁盘留下半装状态（用户机器上复现）。
#
# 做法：把 scripts/ 复制到临时目录并把 const.sh 的 CONFIG_DIR 改写到临时目录
# （绝不读写真实 /opt/xadmin/config），再用最小桩（依赖命令、docker）把几条
# 真实调用路径跑起来。任何一处 unbound 中止都会让本脚本非零退出 → CI 变红。
#
# 要求 bash >= 4.2（[[ -v ]]）。本地执行：bash .github/scripts/set-u-guard.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

fail() {
  echo "::error::$1"
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# 受限 PATH 场景下必须靠绝对路径调用 bash（否则 bash 自身会找不到）
BASH_BIN="$(command -v bash)"

# ---- 隔离副本：CONFIG_DIR 固定指向 /opt/xadmin/config，改写到临时目录 ----
work="${tmp}/repo"
mkdir -p "${work}"
cp -R scripts "${work}/scripts"
cp static.env "${work}/static.env" # const.sh 会 source 仓库根的 static.env
sed -i "s#^export CONFIG_DIR=.*#export CONFIG_DIR='${work}/cfg'#" "${work}/scripts/const.sh"
mkdir -p "${work}/cfg"
cat >"${work}/cfg/config.txt" <<EOF
VOLUME_DIR=${tmp}/vol
DB_ENGINE=postgresql
DB_HOST=postgresql
DB_DATABASE=xadmin
DB_USER=server
DB_PASSWORD=pg
CURRENT_VERSION=guard
EOF

# ---- 1. 依赖齐全时依赖检查必须正常返回（flag 不被赋值的分支） ----
stub_all="${tmp}/bin-all"
mkdir -p "${stub_all}"
for c in curl wget tar iptables; do
  printf '#!/bin/sh\nexit 0\n' >"${stub_all}/${c}"
  chmod +x "${stub_all}/${c}"
done
if ! PATH="${stub_all}:${PATH}" "${BASH_BIN}" -c "set -u; source '${work}/scripts/utils.sh'; prepare_check_required_pkg" >"${tmp}/out1" 2>&1; then
  cat "${tmp}/out1"
  fail "依赖齐全时 prepare_check_required_pkg 中止（flag 未初始化？）"
fi

# ---- 2. 缺依赖时必须打印可读提示并非零退出，而不是 unbound 中止 ----
# PATH 只给桩目录：确保 iptables 一定不可解析（宿主机 /usr/sbin 也不在搜索路径内）
stub_miss="${tmp}/bin-miss"
mkdir -p "${stub_miss}"
for c in curl wget tar; do
  printf '#!/bin/sh\nexit 0\n' >"${stub_miss}/${c}"
  chmod +x "${stub_miss}/${c}"
done
if PATH="${stub_miss}" "${BASH_BIN}" -c "set -u; source '${work}/scripts/utils.sh'; prepare_check_required_pkg" >"${tmp}/out2" 2>&1; then
  fail "缺少 iptables 时应当非零退出"
fi
grep -q "command not found" "${tmp}/out2" || {
  cat "${tmp}/out2"
  fail "缺少依赖时未打印可读提示"
}

# ---- 3. 非交互（stdin 已关闭）时 read_from_input 必须回落默认值而非中止 ----
# 提示语走 stdout，取值只看导出的变量，故把提示重定向丢弃
answer="$("${BASH_BIN}" -c "set -u; source '${work}/scripts/utils.sh'; read_from_input a 'Q' '' DFLT </dev/null >/dev/null; printf %s \"\${a}\"")"
[[ "${answer}" == "DFLT" ]] || fail "stdin 关闭时 read_from_input 未回落默认值（得到 '${answer}'）"

answer="$(printf 'yes\n' | "${BASH_BIN}" -c "set -u; source '${work}/scripts/utils.sh'; read_from_input a 'Q' '' DFLT >/dev/null; printf %s \"\${a}\"")"
[[ "${answer}" == "yes" ]] || fail "有输入时 read_from_input 未采用输入（得到 '${answer}'）"

answer="$("${BASH_BIN}" -c "set -u; source '${work}/scripts/utils.sh'; read_from_input a 'Q' 'y/n' '' </dev/null >/dev/null; printf %s \"\${a}\"")"
[[ -z "${answer}" ]] || fail "无默认值且 stdin 关闭时应取空值（得到 '${answer}'）"

# ---- 4. 环境变量未定义时不得 unbound（旧版 config.txt 缺键的升级场景） ----
answer="$("${BASH_BIN}" -c "set -u; source '${work}/scripts/utils.sh'; get_config_or_env NO_SUCH_KEY_XYZ fallback" 2>&1)" || {
  fail "get_config_or_env 对未定义的键中止：${answer}"
}
[[ "${answer}" == "fallback" ]] || fail "get_config_or_env 未回落默认值（得到 '${answer}'）"

# ---- 5. 数据库已在运行时（flag 不被赋值的分支）备份/恢复脚本不得中止 ----
# 桩 docker：ps 输出 xadmin-server（命中「已在运行」分支）；inspect 一律 healthy（跳过等待）
cat >"${tmp}/docker" <<'EOS'
#!/bin/sh
case "$*" in
  *inspect*) echo healthy ;;
  ps*) echo xadmin-server ;;
esac
exit 0
EOS
chmod +x "${tmp}/docker"

if ! PATH="${tmp}:${PATH}" bash "${work}/scripts/5_db_backup.sh" >"${tmp}/out5" 2>&1; then
  cat "${tmp}/out5"
  fail "备份脚本在「数据库已在运行」路径中止（flag 未初始化？）"
fi

printf 'guard-dummy\n' >"${tmp}/guard.dump"
if ! PATH="${tmp}:${PATH}" bash "${work}/scripts/6_db_restore.sh" "${tmp}/guard.dump" >"${tmp}/out6" 2>&1; then
  cat "${tmp}/out6"
  fail "恢复脚本在「数据库已在运行」路径中止（flag 未初始化？）"
fi

# ---- 6. 无参调用 compose 命令行/服务列表函数不得中止（xadmin.sh 的 start/stop/status 路径）----
for fn in get_docker_compose_cmd_line get_docker_compose_services; do
  out=$("${BASH_BIN}" -c "set -u; source '${work}/scripts/utils.sh'; ${fn}" 2>&1) || {
    echo "${out}"
    fail "${fn} 无参调用中止（\$1 未绑定？）"
  }
  [[ -n "${out}" ]] || fail "${fn} 无参调用没有输出"
done

# ---- 7. ALLOWED_HOSTS 推导：值必须是服务端可 json.loads 的数组 ----
"${BASH_BIN}" -c "set -u; source '${work}/scripts/utils.sh'; ensure_allowed_hosts > /dev/null" >"${tmp}/out7" 2>&1 || {
  cat "${tmp}/out7"
  fail "ensure_allowed_hosts 中止（空数组展开？）"
}
allowed_hosts=$("${BASH_BIN}" -c "source '${work}/scripts/utils.sh'; get_config ALLOWED_HOSTS")
if command -v jq > /dev/null 2>&1; then
  printf '%s' "${allowed_hosts}" | jq -e 'type == "array" and length > 0' > /dev/null ||
    fail "ALLOWED_HOSTS 不是合法 JSON 数组：'${allowed_hosts}'"
else
  # 无 jq 的环境（如 CentOS 7 目标机）退化为结构检查
  [[ "${allowed_hosts}" =~ ^\[\"[^\"]+\"(,\"[^\"]+\")*\]$ ]] ||
    fail "ALLOWED_HOSTS 不是 JSON 数组形态：'${allowed_hosts}'"
fi

# ---- 8. 库不可达时全新库判定必须保守返回非零（否则会跳过升级前体检）----
mkdir -p "${tmp}/bin-nodocker"
printf '#!/bin/sh\nexit 1\n' >"${tmp}/bin-nodocker/docker"
chmod +x "${tmp}/bin-nodocker/docker"
if PATH="${tmp}/bin-nodocker:${PATH}" "${BASH_BIN}" -c "set -u; source '${work}/scripts/utils.sh'; is_fresh_database" > /dev/null 2>&1; then
  fail "库不可达时 is_fresh_database 不应判定为全新库"
fi

# ---- 9. 数据目录属主修正不得中止（镜像未就绪时回落 1001，无权限时仅告警）----
PATH="${tmp}/bin-nodocker:${PATH}" "${BASH_BIN}" -c "set -u; source '${work}/scripts/utils.sh'; ensure_data_dir_owner" >"${tmp}/out9" 2>&1 || {
  cat "${tmp}/out9"
  fail "ensure_data_dir_owner 中止"
}

# ---- 10. upgrade 目标版本归一化（文档形态带 v 前缀；镜像 tag 不含 v）----
out=$("${BASH_BIN}" -c "set -u; set -- v5.0.1; source '${work}/scripts/7_upgrade.sh'; printf %s \"\${target}\"")
[[ "${out}" == "5.0.1" ]] || fail "upgrade 目标未归一化 v 前缀（得到 '${out}'）"

# ---- 11. 升级基线门禁：低于 4.2.5 阻断，带 v 前缀的当前版本可通过 ----
baseline_case() {
  sed -i "s/^CURRENT_VERSION=.*/CURRENT_VERSION=$1/" "${work}/cfg/config.txt"
  "${BASH_BIN}" -c "set -u; set -- ''; source '${work}/scripts/7_upgrade.sh'; verify_upgrade_version" > /dev/null 2>&1
}
baseline_case 4.2.4 && fail "当前版本 4.2.4 应被升级基线门禁阻断" || true
baseline_case v4.2.5 || fail "当前版本 v4.2.5（带 v 前缀）应通过基线门禁"
baseline_case 5.0.1 || fail "当前版本 5.0.1 应通过基线门禁"

# ---- 12. 备份开关未设置时不得中止（SKIP_BACKUP_DB 必须带 :- 默认值）----
# 走真实备份脚本（docker 桩见第 5 项），对应 upgrade 的「3. Backup database」步骤
if ! PATH="${tmp}:${PATH}" "${BASH_BIN}" -c "set -u; set -- ''; source '${work}/scripts/7_upgrade.sh'; backup_db" >"${tmp}/out12" 2>&1; then
  cat "${tmp}/out12"
  fail "backup_db 在 SKIP_BACKUP_DB 未设置时中止（可选开关缺 :- 默认值？）"
fi

echo "set -u runtime guard passed"
