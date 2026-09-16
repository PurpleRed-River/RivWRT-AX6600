#!/bin/sh
# RivWRT 网口规范化的回归测试（针对 uci-defaults/98-rivwrt-net-fix）。
#
# 用法：  sh Scripts/rivwrt-netfix-test.sh
#
# 被测脚本负责两件事，任一件错了都会静默影响网络：
#   ① 新刷机：把 br-lan 里的 lan2 剔除
#      —— 该口已改作 wan2，不能同时是网桥成员和上行口
#   ② 保留配置升级：把旧接口名 network.wan 迁移为 network.wan1
#      —— 不迁移则 mwan3 找不到 wan1，表现为"双 WAN 配了但没生效"，且无任何报错
#
# 做法：从 Settings.sh 的 heredoc 里【按标记抽取】脚本原文，配合 mock uci 执行。
# 测的就是要上机跑的代码；标记改名会直接报错，不会静默通过。
#
# ★ 写 mock uci 的坑（本测试踩过，值得记住）：
#   函数末尾【不能】写 `return 0`。被测脚本靠 `uci -q get <key>` 的成功/失败
#   来判断 section 是否存在，无条件 return 0 会把"不存在"也判成存在，于是
#   迁移分支全被跳过 —— 测试看着"通过"，实际什么都没验。mock 必须复刻真实
#   的退出码语义。
# ★ 另一坑：mock 里删旧键若用 `grep -v "^$key="`，键中的 uci 匿名段语法
#   `[0]` 会被 grep 当字符类（只匹配 "0"），旧行删不掉、新行追加成第二份，
#   读回时取到旧值。故改用 awk 按字段精确比较。

set -u

# 路径形态注意：本仓库在 Windows(MSYS) 下开发时，pwd 返回的是【反斜杠】形式
# 的盘符路径。这种路径若直接用于 shell 中点号加载，反斜杠会被当作转义符 ——
# 结果是静默失败：不报错、脚本根本没执行，测试却显示"跑过了"。
# 统一归一化成正斜杠，避免这个坑。
HERE=$(dirname "$0"); HERE=$(cd "$HERE" && pwd | tr '\\\\' '/')
SH="$HERE/Settings.sh"
MOCK="$HERE/.netfix-test.$$"
CFG="$MOCK/uci.db"
mkdir -p "$MOCK"
# 清理临时目录。**不要 trap PIPE**：被测脚本内部有产生大量输出的命令，
# 一旦管子被截断就会收到 SIGPIPE，把 trap 当成退出信号，脚本会中途停止
# （表现为"测试没跑完、也没有断言输出"，极难察觉）。EXIT 已覆盖正常与中断退出。
trap 'rm -rf "$MOCK"' EXIT INT TERM HUP

[ -f "$SH" ] || { echo "找不到 $SH"; exit 1; }

# ── 从 Settings.sh 抽取 uci-defaults 脚本正文 ──
SCRIPT="$MOCK/netfix.sh"
awk '
	/cat > "\$UDIR\/98-rivwrt-net-fix" <<.RIVWRT_NETFIX./ { f = 1; next }
	f && /^RIVWRT_NETFIX$/ { exit }
	f { print }
' "$SH" > "$SCRIPT"

[ -s "$SCRIPT" ] || { echo "✗ 未能从 Settings.sh 提取 98-rivwrt-net-fix（heredoc 标记变了？）"; exit 1; }
grep -q 'network\.wan' "$SCRIPT" || { echo "✗ 提取内容与预期不符"; exit 1; }

# ── mock uci：配置存为 key=value 行 ──
uci() {
	# shift 掉 -q 后：$1 是动作名，$2 是键（get）或 key=value（set/rename）
	if [ "$1" = "-q" ]; then shift; fi
	case "$1" in
	get)
		awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$CFG"
		# 退出码决定"该键是否存在"，必须如实反映
		awk -F= -v k="$2" '$1==k{f=1}END{exit !f}' "$CFG"
		;;
	set)
		kv="$2"; key="${kv%%=*}"; val="${kv#*=}"
		awk -F= -v k="$key" '$1 != k' "$CFG" > "$CFG.t" 2>/dev/null
		mv "$CFG.t" "$CFG" 2>/dev/null
		printf '%s=%s\n' "$key" "$val" >> "$CFG"
		;;
	rename)
		# uci rename <cfg>.<section>=<newsection>：只换最后一段 section 名
		old="${2%%=*}"; new="${2#*=}"
		prefix="${old%.*}"; newfull="$prefix.$new"
		sed -i "s|^$old\.|$newfull.|; s|^$old=|$newfull=|" "$CFG"
		;;
	commit) : ;;
	esac
	# 不写 return 0：让 case 分支最后一条命令的退出码作为返回值
}

FAILED=0
ck() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; else echo "  ✗ $1  [期望 '$3' 实际 '$2']"; FAILED=$((FAILED + 1)); fi }
run() { . "$SCRIPT" >/dev/null 2>&1; }

echo "───────── 场景 A：全新刷机（02_network 已生成 wan1/wan2）─────────"
cat > "$CFG" <<'EOF'
network.lan=interface
network.lan.device=br-lan
network.wan1=interface
network.wan1.proto=none
network.wan1.device=wan1
network.wan2=interface
network.wan2.proto=none
network.wan2.device=wan2
network.@device[0]=device
network.@device[0].name=br-lan
network.@device[0].ports=lan1 lan2 lan3 lan4
EOF
run
ck "wan1 保留" "$(uci -q get network.wan1.device)" "wan1"
ck "wan2 保留" "$(uci -q get network.wan2.device)" "wan2"
ck "未凭空产生 wan" "$(uci -q get network.wan)" ""
ck "br-lan 剔除 lan2" "$(uci -q get 'network.@device[0].ports')" "lan1 lan3 lan4"

echo ""
echo "───────── 场景 B：保留配置升级（旧接口名 wan）─────────"
cat > "$CFG" <<'EOF'
network.lan=interface
network.lan.device=br-lan
network.wan=interface
network.wan.proto=dhcp
network.wan.device=wan
network.@device[0]=device
network.@device[0].name=br-lan
network.@device[0].ports=lan1 lan2 lan3 lan4
EOF
run
ck "wan 迁移为 wan1（proto 保留）" "$(uci -q get network.wan1.proto)" "dhcp"
ck "wan1.device 修正为 wan1" "$(uci -q get network.wan1.device)" "wan1"
ck "旧 wan 已不存在" "$(uci -q get network.wan)" ""
ck "补建了 wan2" "$(uci -q get network.wan2.device)" "wan2"
ck "br-lan 剔除 lan2" "$(uci -q get 'network.@device[0].ports')" "lan1 lan3 lan4"

echo ""
echo "───────── 场景 C：幂等（再执行一次，结果不变）─────────"
run
ck "wan1.proto 保持" "$(uci -q get network.wan1.proto)" "dhcp"
ck "wan2 section 未被重复创建" "$(grep -c '^network\.wan2=' "$CFG")" "1"
ck "未产生 network.wan= 残留" "$(grep -c '^network\.wan=' "$CFG")" "0"

echo ""
echo "───────── 场景 D：wan6（IPv6 上行，修平台 991 造空壳的问题）──"
# 背景：qualcommax 的 991_set-network.sh 执行 `uci set network.wan6.reqaddress`，
# uci set 对不存在的 section 会直接创建 —— 于是留下一个既无 device 也无 proto
# 的空接口（实测反馈"多出来一个 wan6"）。本脚本在 98-（早于 991）先建完整。

# D1：wan6 不存在 → 建完整
cat > "$CFG" <<'EOF'
network.wan1=interface
network.wan1.device=wan1
EOF
run
ck "D1 无 wan6 时创建 device=wan1" "$(uci -q get network.wan6.device)" "wan1"
ck "D1 无 wan6 时创建 proto=dhcpv6" "$(uci -q get network.wan6.proto)" "dhcpv6"

# D2：wan6 存在但 device 是旧接口名 → 随迁
cat > "$CFG" <<'EOF'
network.wan1=interface
network.wan1.device=wan1
network.wan6=interface
network.wan6.device=wan
network.wan6.proto=dhcpv6
EOF
run
ck "D2 旧 device 随迁到 wan1" "$(uci -q get network.wan6.device)" "wan1"
ck "D2 proto 保留不动" "$(uci -q get network.wan6.proto)" "dhcpv6"

# D3：wan6 已配置完整（例如用户改走 wan2）→ 不覆盖
cat > "$CFG" <<'EOF'
network.wan1=interface
network.wan1.device=wan1
network.wan6=interface
network.wan6.device=wan2
network.wan6.proto=dhcpv6
EOF
run
ck "D3 已配置的 device 不被覆盖" "$(uci -q get network.wan6.device)" "wan2"

# D4：proto=none（991 造出的空壳特征）→ 补成 dhcpv6
cat > "$CFG" <<'EOF'
network.wan1=interface
network.wan1.device=wan1
network.wan6=interface
network.wan6.device=wan1
network.wan6.proto=none
EOF
run
ck "D4 proto=none 补为 dhcpv6" "$(uci -q get network.wan6.proto)" "dhcpv6"

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "✅ 全部通过"
else
	echo "❌ 失败 $FAILED 项"
	exit 1
fi
