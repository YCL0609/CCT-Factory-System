#!/bin/sh
set -eu

usage() {
    cat <<EOF
用法: $0 -d <目标目录> [-c <CCT密钥>] [-f <前端密钥>] [-s <源文件路径>]
  -d  部署目标目录 (必需)
  -c  CCT端签名Key (可选，默认生成64位十六进制)
  -f  网页端签名Key (可选，默认生成64位十六进制)
  -s  源PHP文件路径 (可选，默认为 ./report.php)
  -h  显示帮助
EOF
    exit 1
}

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TARGET_DIR=""
CCT_KEY=""
FRONT_KEY=""

# 解析命令行参数
while getopts "d:c:f:s:h" opt; do
    case "$opt" in
        d) TARGET_DIR="$OPTARG" ;;
        c) CCT_KEY="$OPTARG" ;;
        f) FRONT_KEY="$OPTARG" ;;
        s) SOURCE_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# 检查必需参数
if [ -z "$TARGET_DIR" ]; then
    echo "错误: 必须指定目标目录 (-d)" >&2
    usage
fi

# 生成随机密钥的函数
generate_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    elif [ -r /dev/urandom ]; then
        tr -dc 'a-f0-9' < /dev/urandom | head -c 64
    else
        echo "错误: 无法生成随机密钥，请安装 openssl 或确保 /dev/urandom 可读" >&2
        return 1
    fi
}

# 确定CCT Key
if [ -z "$CCT_KEY" ]; then
    CCT_KEY=$(generate_key) || exit 1
fi

# 确定前端 Key
if [ -z "$FRONT_KEY" ]; then
    FRONT_KEY=$(generate_key) || exit 1
fi

# 验证密钥格式（必须为64个十六进制字符）
validate_key() {
    local key="$1"
    if [ ${#key} -ne 64 ] || ! echo "$key" | grep -qE '^[0-9a-fA-F]{64}$'; then
        echo "错误: 密钥 '$key' 不是有效的64位十六进制字符串" >&2
        return 1
    fi
}
validate_key "$CCT_KEY" || exit 1
validate_key "$FRONT_KEY" || exit 1

# 创建目标目录并检查可写性
mkdir -p "$TARGET_DIR" || { echo "错误: 无法创建目录 '$TARGET_DIR'" >&2; exit 1; }
if [ ! -w "$TARGET_DIR" ]; then
    echo "错误: 目标目录 '$TARGET_DIR' 不可写" >&2
    exit 1
fi

# 部署函数：复制文件并替换密钥占位符
deploy_file() {
    local src="$1"
    local dst="$2"
    local key="$3"
    sed "s#@@KEY@@#${key}#g" "$src" > "$dst" || {
        echo "错误: 无法生成 '$dst'" >&2
        return 1
    }
    echo "已部署: $dst"
}

# 部署目标文件
deploy_file "${SCRIPT_DIR}/report.php" "${TARGET_DIR}/report.php" "$CCT_KEY"
deploy_file "${SCRIPT_DIR}/control.php" "${TARGET_DIR}/control.php" "$FRONT_KEY"
deploy_file "${SCRIPT_DIR}/bootstrap.php" "${TARGET_DIR}/bootstrap.php" ""

# 创建软链接
LINK_TARGET="/dev/shm/CCT-Factory-Server/latest_report.json"
LINK_NAME="${TARGET_DIR}/data.json"
rm -f "$LINK_NAME"
ln -s "$LINK_TARGET" "$LINK_NAME" || {
    echo "错误: 无法创建软链接 '$LINK_NAME' -> '$LINK_TARGET'" >&2
    exit 1
}
echo "已创建软链接: $LINK_NAME -> $LINK_TARGET"

# 输出结果
echo "完成!"
echo "  CCT端密钥: $CCT_KEY"
echo "  前端密钥: $FRONT_KEY"