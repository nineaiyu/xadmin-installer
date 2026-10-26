#!/usr/bin/env bash
# HTTPS 证书 fail-closed 回归（不依赖 Docker，秒级）：
# 1) 交付包不得携带证书/私钥（历史示例私钥已公开）；
# 2) 启用 HTTPS_PORT 但证书未配置 / 文件缺失 / 沿用历史示例私钥时必须拒绝；
# 3) 有效证书必须通过，未启用 HTTPS 时不得要求证书。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/utils.sh
. "${REPO_DIR}/scripts/utils.sh"

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required by this guard"
  exit 1
}

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

CONFIG_DIR="${workdir}/config"
CONFIG_FILE="${CONFIG_DIR}/config.txt"
CERT_DIR="${CONFIG_DIR}/nginx/cert"
mkdir -p "${CERT_DIR}"

fail() {
  echo "FAIL: $*"
  exit 1
}

expect_fail() {
  local reason="$1"
  if (ensure_https_certificates) >/dev/null 2>&1; then
    fail "expected rejection: ${reason}"
  fi
}

expect_ok() {
  local reason="$1"
  if ! (ensure_https_certificates) >/dev/null 2>&1; then
    fail "expected success: ${reason}"
  fi
}

# 1) 交付包不得携带证书或私钥
if find "${REPO_DIR}/config_init" -type f \( -name '*.key' -o -name '*.pem' -o -name '*.crt' \) | grep -q .; then
  fail "config_init must not ship certificate or private key files"
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
  -keyout "${CERT_DIR}/server.key" -out "${CERT_DIR}/server.crt" >/dev/null 2>&1
test_key_hash="$(sha256sum "${CERT_DIR}/server.key" | awk '{print $1}')"

# 2) 未启用 HTTPS：无需证书
printf 'HTTP_PORT=80\n' >"${CONFIG_FILE}"
expect_ok "HTTPS disabled"

# 3) 启用 HTTPS 但未配置证书名
printf 'HTTP_PORT=80\nHTTPS_PORT=443\n' >"${CONFIG_FILE}"
expect_fail "HTTPS enabled without SSL_CERTIFICATE / SSL_CERTIFICATE_KEY"

# 4) 配置了证书名但文件缺失
printf 'HTTPS_PORT=443\nSSL_CERTIFICATE=server.crt\nSSL_CERTIFICATE_KEY=server.key\n' >"${CONFIG_FILE}"
mv "${CERT_DIR}/server.crt" "${workdir}/server.crt"
expect_fail "certificate file missing"
mv "${workdir}/server.crt" "${CERT_DIR}/server.crt"

# 5) 沿用历史示例私钥（用测试密钥的指纹临时覆盖该常量，避免把真实示例私钥带入仓库）
LEGACY_EXAMPLE_TLS_KEY_SHA256="${test_key_hash}" expect_fail "legacy example private key"

# 6) 有效证书（默认常量是真实示例私钥指纹，与测试密钥不同）
expect_ok "valid certificate and key"

echo "HTTPS certificate fail-closed guard passed"
