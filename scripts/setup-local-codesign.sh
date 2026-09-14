#!/bin/zsh
# setup-local-codesign.sh
#
# 为本地/开发构建建立「稳定」的自签名代码签名身份，解决 ad-hoc（--sign -）
# 每次重编译 CDHash 漂移导致钥匙串 ACL 失效、反复弹「登录钥匙串密码」的问题。
#
# 原理：以固定证书签名的应用，其 designated requirement 引用该证书（稳定），
# 与二进制内容无关；钥匙串项 ACL 只需一次性信任该证书即长期生效。
#
# 用法：zsh scripts/setup-local-codesign.sh [身份名]
# 默认身份名：WorkBuddy Switch Local Development
# 幂等：身份已存在时直接退出。

set -euo pipefail

identity_name="${1:-WorkBuddy Switch Local Development}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '\033[1;36m[setup-local-codesign]\033[0m %s\n' "$*"; }

# 优先 Homebrew OpenSSL 3（其 PKCS#12 与 macOS Security 兼容；系统自带 LibreSSL 的
# PKCS#12 会出现 "MAC verification failed"），否则回退系统 openssl。
if [[ -x "/opt/homebrew/opt/openssl@3/bin/openssl" ]]; then
  openssl_bin="/opt/homebrew/opt/openssl@3/bin/openssl"
elif [[ -x "/usr/local/opt/openssl@3/bin/openssl" ]]; then
  openssl_bin="/usr/local/opt/openssl@3/bin/openssl"
else
  openssl_bin="/usr/bin/openssl"
fi

# 1. 已存在 → 幂等退出（精确匹配证书全名，避免同名子串误判）
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"${identity_name}\""; then
  log "代码签名身份已存在：${identity_name}"
  security find-identity -v -p codesigning | grep -F "\"${identity_name}\""
  exit 0
fi

tmp_dir="$(mktemp -d)"
key="$tmp_dir/local-sign.key"
cert="$tmp_dir/local-sign.crt"
p12="$tmp_dir/local-sign.p12"
cfg="$tmp_dir/local-sign.cnf"
trap 'rm -rf "$tmp_dir"' EXIT

# 2. 生成自签名证书（代码签名 EKU，10 年有效期，固定 CN=身份名）
# LibreSSL（macOS 自带）的 req 不接受 -extfile，必须用完整 -config。
cat > "$cfg" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = x509v3
[dn]
CN = ${identity_name}
O = WorkBuddy Switch Local
[x509v3]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
EOF
"${openssl_bin}" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$key" -out "$cert" -config "$cfg" \
  || { log "错误：openssl 生成自签名证书失败。" >&2; exit 1; }

# 3. 打包为 PKCS#12 并导入登录钥匙串（-T /usr/bin/codesign 允许 codesign 直接使用）
# OpenSSL 3 默认用 PBES2 导出，macOS Security 会报 "MAC verification failed"；
# -legacy（3DES/SHA1）是 Security 稳定兼容的格式。LibreSSL 无该选项，仅 Homebrew OpenSSL 加。
pkcs12_legacy=()
if [[ "${openssl_bin}" != "/usr/bin/openssl" ]]; then
  pkcs12_legacy=(-legacy)
fi
"${openssl_bin}" pkcs12 -export "${pkcs12_legacy[@]}" -inkey "$key" -in "$cert" \
  -out "$p12" -passout "pass:change-me" -name "${identity_name}" \
  || { log "错误：PKCS#12 导出失败。" >&2; exit 1; }
security import "$p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "change-me" -T /usr/bin/codesign \
  || { log "错误：身份导入登录钥匙串失败。" >&2; exit 1; }

# 4. 用户域证书信任（不带 -d：-d 表示需要特权的 Admin Trust Settings；
#    per-user 信任即足以让本用户下的 codesign --verify 通过，无需 sudo）
security add-trusted-cert -r trustRoot -p codeSign "$cert" >/dev/null 2>&1 \
  || { log "错误：设置用户域证书信任失败。" >&2; exit 1; }

# 5. 校验（精确匹配证书全名）
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"${identity_name}\""; then
  log "已创建并导入稳定代码签名身份：${identity_name}"
  security find-identity -v -p codesigning | grep -F "\"${identity_name}\""
  log "打包时通过以下方式使用："
  log "  OPENUSAGE_SIGN_IDENTITY=\"${identity_name}\" zsh scripts/build-release.sh"
  log "注：首次用新身份访问既有钥匙串项时，macOS 会逐项弹一次『始终允许』（输入一次登录钥匙串密码），"
  log "    此后该身份长期有效，重编译/重签名不再反复弹窗。"
else
  log "错误：身份创建后无法在 codesigning 身份列表中查到，请检查上面的失败输出。" >&2
  exit 1
fi