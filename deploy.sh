#!/bin/bash
set -euo pipefail

# ========== 配置区 ==========
APP_HOME="${APP_HOME:-/data/apps/ruoyi-vue}"   # 部署根目录（nginx root 指向 $APP_HOME/current）
RELEASES_DIR="$APP_HOME/releases"              # 每个版本一个不可变目录
CURRENT_LINK="$APP_HOME/current"               # 软链，原子切换
INCOMING_DIR="$APP_HOME/incoming"              # CI 上传区，web root 之外
KEEP_RELEASES="${KEEP_RELEASES:-5}"            # 保留版本数
KEEP_ARCHIVE="${KEEP_ARCHIVE:-false}"          # 部署成功后是否保留上传包
DEFAULT_ARCHIVE="dist.tar.gz"
# ============================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACTION="deploy"
ARCHIVE=""
RELEASE_ID=""

# 用法: bash deploy.sh [deploy|rollback|restart|status] [包路径|版本名]
for arg in "$@"; do
    case "$arg" in
        deploy|rollback|restart|status) ACTION="$arg" ;;
        *.tar.gz|*.tgz) ARCHIVE="$arg" ;;
        -*) echo "❌ 未知选项: $arg"; exit 1 ;;
        *) RELEASE_ID="$arg" ;;
    esac
done
ARCHIVE="${ARCHIVE:-$SCRIPT_DIR/$DEFAULT_ARCHIVE}"

nginx_reload() {
    # 仅 restart 子命令使用：软链切换/版本发布都不需要 reload
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t >/dev/null 2>&1; then
            nginx -s reload
            echo "✅ nginx 已重载"
        else
            echo "⚠️  nginx -t 校验失败，跳过重载"
        fi
    else
        echo "ℹ️  未检测到 nginx，跳过重启步骤"
    fi
}

switch_current() {
    local target="$1"
    # 先建临时软链再 rename，保证任意时刻 current 都指向有效目录
    ln -sfn "$target" "$APP_HOME/.current.tmp"
    mv -Tf "$APP_HOME/.current.tmp" "$CURRENT_LINK"
}

prune_releases() {
    local cur n p
    cur="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
    n=0
    while IFS= read -r p; do
        p="${p%/}"
        [ -n "$p" ] || continue
        n=$((n + 1))
        [ "$p" = "$cur" ] && continue
        if [ "$n" -gt "$KEEP_RELEASES" ]; then
            echo "🗑  清理旧版本: $(basename "$p")"
            rm -rf "$p"
        fi
    done < <(ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null || true)

    # 清理异常中断残留的临时目录
    find "$RELEASES_DIR" -maxdepth 1 -name '.tmp.*' -type d -exec rm -rf {} + 2>/dev/null || true
}

case "$ACTION" in
    restart)
        echo ">>> 仅重启服务，不重新部署..."
        nginx_reload
        exit 0
        ;;
    status)
        echo "部署根目录: $APP_HOME"
        echo "当前版本:   $(readlink -f "$CURRENT_LINK" 2>/dev/null || echo '未部署')"
        echo "版本列表（新→旧）:"
        ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null | sed 's:/$::' | sed 's:.*/:  :' || echo "  (空)"
        exit 0
        ;;
    rollback)
        mapfile -t ALL < <(ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null | sed 's:/$::')
        if [ "${#ALL[@]}" -eq 0 ]; then
            echo "❌ releases 下没有可用版本"
            exit 1
        fi
        CUR="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
        TARGET=""
        if [ -n "$RELEASE_ID" ]; then
            TARGET="$RELEASES_DIR/$(basename "$RELEASE_ID")"
            [ -d "$TARGET" ] || { echo "❌ 版本不存在: $TARGET"; exit 1; }
        else
            for d in "${ALL[@]}"; do
                if [ "$d" != "$CUR" ]; then TARGET="$d"; break; fi
            done
        fi
        if [ -z "$TARGET" ]; then
            echo "❌ 没有可回滚的历史版本"
            exit 1
        fi
        echo ">>> 回滚到: $(basename "$TARGET")"
        switch_current "$TARGET"
        echo "🎉 回滚完成，current -> $(readlink "$CURRENT_LINK")"
        exit 0
        ;;
esac

# ---------- deploy ----------
echo ">>> [1/6] 检查压缩包..."
if [ ! -f "$ARCHIVE" ]; then
    echo "❌ 找不到压缩包: $ARCHIVE"
    exit 1
fi
echo "✅ 压缩包存在: $(du -h "$ARCHIVE" | cut -f1)  ($ARCHIVE)"

echo ">>> [2/6] 初始化目录..."
mkdir -p "$RELEASES_DIR" "$INCOMING_DIR"

NAME="${RELEASE_ID:-$(date +%Y%m%d-%H%M%S)}"
[ -e "$RELEASES_DIR/$NAME" ] && NAME="$NAME-$$"
TMP_DIR="$RELEASES_DIR/.tmp.$$"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
echo "✅ 版本号: $NAME"

echo ">>> [3/6] 解压到临时目录..."
if ! tar -xzf "$ARCHIVE" -C "$TMP_DIR"; then
    echo "❌ 解压失败，压缩包可能损坏或不完整: $ARCHIVE"
    rm -rf "$TMP_DIR"
    exit 1
fi
echo "✅ 解压完成"

echo ">>> [4/6] 处理目录结构..."
# tar 包内通常是单层 dist/，自动提升内容到版本根目录
mapfile -t SUB_DIRS < <(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d)
FILE_COUNT=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)
if [ "${#SUB_DIRS[@]}" -eq 1 ] && [ "$FILE_COUNT" -eq 0 ]; then
    echo "⚠️  检测到单层子目录结构，自动提升..."
    shopt -s dotglob
    mv "${SUB_DIRS[0]}"/* "$TMP_DIR/"
    rmdir "${SUB_DIRS[0]}"
    shopt -u dotglob
    echo "✅ 目录结构已调整"
else
    echo "✅ 目录结构正常，无需调整"
fi

echo ">>> [5/6] 校验并落版本目录..."
if [ ! -f "$TMP_DIR/index.html" ]; then
    echo "❌ index.html 不存在，构建产物异常，放弃部署"
    rm -rf "$TMP_DIR"
    exit 1
fi
mv "$TMP_DIR" "$RELEASES_DIR/$NAME"    # 同一分区，rename 原子生效

echo ">>> [6/6] 切换软链..."
switch_current "$RELEASES_DIR/$NAME"
prune_releases

FILE_TOTAL=$(find "$RELEASES_DIR/$NAME" -type f | wc -l)
[ "$KEEP_ARCHIVE" = "true" ] || rm -f "$ARCHIVE"

echo ""
echo "🎉 部署完成！"
echo "   当前版本: $CURRENT_LINK -> releases/$NAME"
echo "   文件数量: $FILE_TOTAL"
echo "   历史版本: $(ls -1d "$RELEASES_DIR"/*/ 2>/dev/null | wc -l) 个（保留 $KEEP_RELEASES）"
echo "   回滚命令: bash deploy.sh rollback"
echo ""
echo "ℹ️  未触碰 nginx（软链切换即时生效）。改了 site 配置后再手动执行: bash deploy.sh restart"
