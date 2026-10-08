#!/bin/bash
# 生成自签名代码签名证书「ShotMark Local Signing」并导入登录钥匙串。
# 目的：TCC（屏幕录制等）权限对「固定签名身份 + bundle id」记忆，
#       自签名证书后重编 App 授权不失效（ad-hoc 签名每次重编 cdhash 都变，授权会丢）。
# 只需跑一次。codesign 首次用该私钥时可能弹一次钥匙串授权框，点「始终允许」。
set -e
NAME="ShotMark Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "已存在: $NAME"
    exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/sm.key" -out "$TMP/sm.crt" \
    -days 3650 -nodes -subj "/CN=$NAME" \
    -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=critical,digitalSignature"
openssl pkcs12 -export -legacy -out "$TMP/sm.p12" -inkey "$TMP/sm.key" -in "$TMP/sm.crt" \
    -password pass:shotmark-local
security import "$TMP/sm.p12" -k ~/Library/Keychains/login.keychain-db \
    -P shotmark-local -T /usr/bin/codesign
echo "已导入: $NAME"
