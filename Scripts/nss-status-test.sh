#!/bin/sh
# RivWRT nss-status 后端解析的回归测试。
#
# 用法：  sh Scripts/nss-status-test.sh
#
# 覆盖两类"数据源格式假设"错误 —— 这类 bug 静态看代码都像对的，只有拿真实
# 格式喂进去才暴露：
#   ① ECM 连接数：实际有两个同源节点
#        connection_count        —— u32，纯数字
#        connection_count_simple —— 文本 "tcp X udp Y other Z total W"
#      曾只读后者并按"纯数字"校验 → case 必然拒绝 → 前端永远显示 "—"。
#   ② NSS 负载：cpu_load_ubi 的数据行是三列 "Min Avg Max"，取第 1 个百分比会
#      取到 Min（瞬时最低）而非 Avg，曲线长期显示为低谷。
#
# 做法：从 Settings.sh 的实际产物里【按锚点抽取】对应代码段，把 debugfs 路径
# 重定向到 mock 目录后执行 —— 测的就是要上机跑的代码，而非手抄副本。锚点
# 失效会直接报错，不会静默通过。

set -u

# 路径形态注意：本仓库在 Windows(MSYS) 下开发时，pwd 返回的是【反斜杠】形式
# 的盘符路径。这种路径若直接用于 shell 中点号加载，反斜杠会被当作转义符 ——
# 结果是静默失败：不报错、脚本根本没执行，测试却显示"跑过了"。
# 统一归一化成正斜杠，避免这个坑。
HERE=$(dirname "$0"); HERE=$(cd "$HERE" && pwd | tr '\\\\' '/')
SH="$HERE/Settings.sh"
# 注意：不能用 /tmp —— 本仓库的开发环境（Windows 上的 sh）没有可写的 /tmp。
# 用脚本同目录下的临时目录，跑完删除。
MOCK="$HERE/.nss-status-test.$$"
FRAG="$MOCK/frag.sh"
mkdir -p "$MOCK"
trap 'rm -rf "$MOCK"' EXIT INT TERM

[ -f "$SH" ] || { echo "找不到 $SH"; exit 1; }

# 从 Settings.sh 的 heredoc 里取出 nss-status 全文
extract_nss_status() {
	awk '
		/cat > \$PKGDIR\/root\/usr\/libexec\/rivwrt\/nss-status <<.EOF./ { f = 1; next }
		f && /^EOF$/ { exit }
		f { print }
	' "$SH"
}

NSS=$(extract_nss_status)
[ -n "$NSS" ] || { echo "✗ 未能从 Settings.sh 提取 nss-status（heredoc 标记变了？）"; exit 1; }
[ "$(printf '%s\n' "$NSS" | wc -l)" -gt 40 ] || { echo "✗ 提取到的 nss-status 过短"; exit 1; }

FAILED=0
ok()   { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1"; FAILED=$((FAILED + 1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1  [期望 '$3'，实际 '$2']"; fi }

# ---------------------------------------------------------------
# ① 连接数解析
# ---------------------------------------------------------------
echo "═══ ① ECM 连接数解析"
printf '%s\n' "$NSS" \
	| awk '/NSS 加速连接数/ { f = 1 } f { print } f && /^esac$/ { n++; if (n == 2) exit }' \
	| sed "s#/sys/kernel/debug/ecm/ecm_db/#$MOCK/#g" > "$FRAG"
grep -q 'connection_count' "$FRAG" || { echo "✗ 未能抽到连接数段（锚点变了？）"; exit 1; }

conns_of() { sh "$FRAG" 2>/dev/null | sed -n 's/^conns=//p'; }

mkdir -p "$MOCK"
rm -f "$MOCK"/connection_count "$MOCK"/connection_count_simple

# 主路径：u32 纯数字
printf '46\n' > "$MOCK/connection_count"
eq "connection_count 为纯数字 → 46" "$(conns_of)" "46"

# 回退路径：只有 simple（文本），须析出 total
rm -f "$MOCK/connection_count"
printf 'tcp 12 udp 34 other 0 total 46\n' > "$MOCK/connection_count_simple"
eq "仅 simple 文本 → 析出 total=46" "$(conns_of)" "46"

# total 为 0 要输出 0，不能当成"取不到"
printf 'tcp 0 udp 0 other 0 total 0\n' > "$MOCK/connection_count_simple"
eq "simple 的 total=0 → 输出 0（非空）" "$(conns_of)" "0"

# 大数
printf 'tcp 800 udp 1200 other 5 total 2005\n' > "$MOCK/connection_count_simple"
eq "simple 的 total=2005" "$(conns_of)" "2005"

# 两文件都在 → 主路径优先
printf '77\n' > "$MOCK/connection_count"
printf 'tcp 1 udp 2 other 0 total 999\n' > "$MOCK/connection_count_simple"
eq "两文件都在 → 取 connection_count=77" "$(conns_of)" "77"

# ECM 未加载（两文件都不存在）→ 不输出，页面显示 "—"
rm -f "$MOCK/connection_count" "$MOCK/connection_count_simple"
eq "两文件都不存在 → 不输出" "$(conns_of)" ""

# 垃圾内容 → 不输出（而不是把垃圾串显示出去）
printf 'garbage\n' > "$MOCK/connection_count"
eq "垃圾内容 → 不输出" "$(conns_of)" ""

rm -f "$MOCK"/connection_count "$MOCK"/connection_count_simple

# ---------------------------------------------------------------
# ② NSS 负载取 Avg 列（不是 Min）
# ---------------------------------------------------------------
echo "═══ ② cpu_load_ubi 取 Avg 列"
printf '%s\n' "$NSS" \
	| awk '/^D=\/sys\/kernel\/debug/ { f = 1 } f { print } f && /^fi$/ { exit }' \
	| sed "s#/sys/kernel/debug#${MOCK}#g" \
	| sed 's/^mountpoint .*$/:/' > "$FRAG"
grep -q 'cpu_load_ubi' "$FRAG" || { echo "✗ 未能抽到负载段（锚点变了？）"; exit 1; }

mkdir -p "$MOCK/qca-nss-drv/stats"
# 设备实测格式：标题行 + 表头 + 三列数据
cat > "$MOCK/qca-nss-drv/stats/cpu_load_ubi" <<'EOF'
CPU Utilization:
Note: Averaged over 1 second
Core 0:
Min     Avg     Max
 2%      7%      34%
EOF
load_of() { sh "$FRAG" 2>/dev/null | sed -n 's/^load_0=//p'; }
eq "三列 Min/Avg/Max → 取 Avg=7（非 Min=2）" "$(load_of)" "7"

# 多核
cat > "$MOCK/qca-nss-drv/stats/cpu_load_ubi" <<'EOF'
CPU Utilization:
Core 0:
Min     Avg     Max
 2%      7%      34%
Core 1:
Min     Avg     Max
 5%      19%     88%
EOF
eq "双核 → core0=7" "$(sh "$FRAG" 2>/dev/null | sed -n 's/^load_0=//p')" "7"
eq "双核 → core1=19" "$(sh "$FRAG" 2>/dev/null | sed -n 's/^load_1=//p')" "19"

rm -rf "$MOCK"

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "✅ 全部通过"
else
	echo "❌ 失败 $FAILED 项"
	exit 1
fi
