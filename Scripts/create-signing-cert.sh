#!/bin/bash
# 创建并安装本地代码签名证书 "AidoPaste Dev"（自签名）。
#
# 为什么需要它：ad-hoc 签名（codesign -s -）没有稳定身份，macOS 按 cdhash
# 识别应用——每次重新构建 cdhash 都变，TCC 就当成新应用，辅助功能等授权
# 需要重新授予。用固定证书签名后，TCC 按证书匹配授权，重建/升级不再掉权限。
#
# 用法：Scripts/create-signing-cert.sh   （已安装同名有效身份时幂等退出）
set -euo pipefail

NAME="AidoPaste Dev"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "signing identity already installed: $NAME"
  exit 0
fi

# 代码签名身份要求的扩展：digitalSignature + codeSigning EKU
cat > "$WORKDIR/cert.conf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no
[dn]
CN = AidoPaste Dev
O = AidoPaste
[v3_codesign]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:3072 -nodes \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -days 7300 -config "$WORKDIR/cert.conf"

# 打包导入登录钥匙串；-T 预授权 /usr/bin/codesign 使用该私钥（免 GUI 弹窗）
openssl pkcs12 -export -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
  -out "$WORKDIR/cert.p12" -passout pass:paste-temp-import
security import "$WORKDIR/cert.p12" -P paste-temp-import -T /usr/bin/codesign

# 信任该证书用于代码签名（用户信任域）
security add-trusted-cert -r trustRoot -p codeSign "$WORKDIR/cert.pem"

security find-identity -v -p codesigning | grep "$NAME" \
  || { echo "error: identity not valid after install" >&2; exit 1; }
echo "signing identity ready: $NAME"
