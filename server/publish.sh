#!/bin/sh
set -eu

usage() {
    cat <<EOF
用法: $0 -d <目标目录> [选项]
  -d <目录>  部署目标目录 (必需, 通常是 Web 站点下的某个子目录)
  -S <目录>  运行期数据存储目录 (可选, 默认: /dev/shm/CCT-Factory-Hub)
  -c <密钥>  CCT 端签名密钥 (可选, 默认随机生成 64 位十六进制)
  -f <密钥>  网页端签名密钥 (可选, 默认随机生成 64 位十六进制)
  -h         显示帮助
EOF
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
TARGET_DIR=""
STORAGE_DIR=""
CCT_KEY=""
FRONT_KEY=""

while getopts "d:S:c:f:h" opt; do
    case "$opt" in
        d) TARGET_DIR="$OPTARG" ;;
        S) STORAGE_DIR="$OPTARG" ;;
        c) CCT_KEY="$OPTARG" ;;
        f) FRONT_KEY="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$TARGET_DIR" ]; then
    echo "错误: 必须指定目标目录 (-d)" >&2
    usage
fi

# 默认存储目录: 优先使用内存盘, 否则退回目标目录下的 .storage
if [ -z "$STORAGE_DIR" ]; then
    if [ -d /dev/shm ] && [ -w /dev/shm ]; then
        STORAGE_DIR="/dev/shm/CCT-Factory-Hub"
    else
        STORAGE_DIR="$TARGET_DIR/.storage"
    fi
fi

# 密钥处理
generate_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    elif [ -r /dev/urandom ]; then
        LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 64
    else
        echo "错误: 无法生成随机密钥, 请安装 openssl 或确保 /dev/urandom 可读" >&2
        return 1
    fi
}

validate_key() {
    key="$1"
    if [ ${#key} -ne 64 ]; then
        echo "错误: 密钥长度必须为 64 个十六进制字符 (当前 ${#key})" >&2
        return 1
    fi
    case "$key" in
        *[!0-9a-fA-F]*)
            echo "错误: 密钥包含非十六进制字符" >&2
            return 1
            ;;
    esac
    return 0
}

if [ -z "$CCT_KEY" ]; then
    CCT_KEY=$(generate_key) || exit 1
fi
if [ -z "$FRONT_KEY" ]; then
    FRONT_KEY=$(generate_key) || exit 1
fi
validate_key "$CCT_KEY" || exit 1
validate_key "$FRONT_KEY" || exit 1

# 目录准备
mkdir -p "$TARGET_DIR" || { echo "错误: 无法创建目录 '$TARGET_DIR'" >&2; exit 1; }
if [ ! -w "$TARGET_DIR" ]; then
    echo "错误: 目标目录 '$TARGET_DIR' 不可写" >&2
    exit 1
fi
mkdir -p "$STORAGE_DIR" || { echo "错误: 无法创建存储目录 '$STORAGE_DIR'" >&2; exit 1; }
if [ ! -w "$STORAGE_DIR" ]; then
    echo "错误: 存储目录 '$STORAGE_DIR' 不可写" >&2
    exit 1
fi

# 部署
deploy_file() {
    src="$1"
    dst="$2"
    if [ ! -f "$src" ]; then
        echo "错误: 源文件不存在 '$src'" >&2
        return 1
    fi
    cp "$src" "$dst" || { echo "错误: 无法生成 '$dst'" >&2; return 1; }
    echo "已部署: $dst"
}

deploy_file "$SCRIPT_DIR/report.php"    "$TARGET_DIR/report.php"
deploy_file "$SCRIPT_DIR/control.php"   "$TARGET_DIR/control.php"
deploy_file "$SCRIPT_DIR/bootstrap.php" "$TARGET_DIR/bootstrap.php"
deploy_file "$SCRIPT_DIR/data.php"      "$TARGET_DIR/data.php"

# 生成 config.php
CONFIG_FILE="$TARGET_DIR/config.php"
cat > "$CONFIG_FILE" <<EOF
<?php
/*
 * CCT-Factory-Hub 服务端配置 (由 publish.sh 生成)
 */

// 禁止通过 HTTP 直接访问本文件
if (isset(\$_SERVER['SCRIPT_FILENAME']) && @realpath(\$_SERVER['SCRIPT_FILENAME']) === @realpath(__FILE__)) {
    http_response_code(403);
    exit();
}

return [
    // 运行期数据目录
    'storage_dir'     => '$STORAGE_DIR',

    // CCT 端 (游戏内计算机) 签名密钥
    'cct_key'         => '$CCT_KEY',

    // 网页端签名密钥
    'front_key'       => '$FRONT_KEY',

    // 允许的请求时间偏差 (毫秒)
    'time_tolerance_ms' => 30000,
];
EOF
chmod 600 "$CONFIG_FILE" 2>/dev/null || true
echo "已生成: $CONFIG_FILE"

# data.json 软链接
LINK_TARGET="$STORAGE_DIR/latest_report.json"
LINK_NAME="$TARGET_DIR/data.json"
rm -f "$LINK_NAME" 2>/dev/null || true
if ln -s "$LINK_TARGET" "$LINK_NAME" 2>/dev/null; then
    echo "已创建软链接: $LINK_NAME -> $LINK_TARGET"
else
    echo "警告: 无法创建软链接 '$LINK_NAME' (当前平台可能不支持), 前端会自动回退到 data.php, 无需额外处理。"
fi

cat <<EOF
完成!
  部署目录    : $TARGET_DIR
  存储目录    : $STORAGE_DIR
  CCT端密钥   : $CCT_KEY
  前端密钥    : $FRONT_KEY
EOF
