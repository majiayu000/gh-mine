#!/usr/bin/env bash
# gh-mine installer — stage, validate, and atomically replace the target.
set -euo pipefail

REPO="majiayu000/gh-mine"
VERSION="${GH_MINE_VERSION:-main}"
SOURCE_URL="https://raw.githubusercontent.com/${REPO}/${VERSION}/gh-mine"
INSTALL_DIR="${GH_MINE_INSTALL_DIR:-$HOME/.local/bin}"
TARGET="${INSTALL_DIR}/gh-mine"
EXPECTED_SHA256="${GH_MINE_SHA256:-}"
TEMP_FILE=""

cleanup() {
  if [[ -n "$TEMP_FILE" ]]; then
    rm -f "$TEMP_FILE"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

command -v curl >/dev/null 2>&1 ||
  { echo "install: 需要 'curl'" >&2; exit 1; }
mkdir -p "$INSTALL_DIR"
TEMP_FILE="$(mktemp "${INSTALL_DIR}/.gh-mine.tmp.XXXXXX")"

echo "下载 gh-mine (${VERSION}) -> ${TARGET}"
if ! curl -fsSL "$SOURCE_URL" -o "$TEMP_FILE"; then
  echo "install: 下载失败，保留已有安装" >&2
  exit 1
fi
if ! bash -n "$TEMP_FILE"; then
  echo "install: 下载内容未通过 Bash 语法验证，保留已有安装" >&2
  exit 1
fi

if [[ -n "$EXPECTED_SHA256" ]]; then
  if ! [[ "$EXPECTED_SHA256" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "install: GH_MINE_SHA256 必须是 64 位十六进制 SHA256" >&2
    exit 1
  fi
  expected_lower="$(printf '%s' "$EXPECTED_SHA256" | tr '[:upper:]' '[:lower:]')"
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256="$(sha256sum "$TEMP_FILE" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual_sha256="$(shasum -a 256 "$TEMP_FILE" | awk '{print $1}')"
  else
    echo "install: 已要求 checksum，但系统缺少 sha256sum/shasum" >&2
    exit 1
  fi
  if [[ "$actual_sha256" != "$expected_lower" ]]; then
    echo "install: SHA256 不匹配，保留已有安装" >&2
    exit 1
  fi
fi

if ! chmod +x "$TEMP_FILE"; then
  echo "install: 无法设置可执行权限，保留已有安装" >&2
  exit 1
fi
if ! mv -f "$TEMP_FILE" "$TARGET"; then
  echo "install: 原子替换失败，保留已有安装" >&2
  exit 1
fi
TEMP_FILE=""

for dependency in gh jq; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "提示: 缺少运行时依赖 '${dependency}'，请先安装" >&2
  fi
done

case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *)
    echo "提示: ${INSTALL_DIR} 不在 PATH，请在 shell 配置中加入：" >&2
    echo "  export PATH=\"\$PATH:${INSTALL_DIR}\"" >&2
    ;;
esac
echo "完成。运行: gh-mine --help"
