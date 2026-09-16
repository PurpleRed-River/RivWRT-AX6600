#!/bin/bash
# =========================================================
# RivWRT 构建期定制脚本
# 由 WRT-CORE.yml 在 make defconfig 之前调用（cwd = wrt 源码树根）
#
# 本脚本产出的内容：
#   /etc/uci-defaults  96-fullcone · 98-net-fix · 99-podman · 99-menus
#   /etc/init.d        rivwrt-wifi（三频固化，S99 自启）+ banner
#   /package/          自建包：luci-app-rivwrt-nss · podman-compose
#   树内补丁（白名单）：DTS 端口互换 · KERNEL_SIZE=12288k ·
#                      daede 暗色屏蔽 · 主题依赖/SSID/内存水位线
#
# 自建包清单与提取模式见本文件"组件注入"区块；
# 配置增量见 Config/GENERAL_AX6600_RIVWRT.txt。
# =========================================================

# -------------------------------------------------------
# 工具函数
# -------------------------------------------------------

apply_sed_to_matches() {
	local SEARCH_DIR=$1
	local FILE_NAME=$2
	local SED_EXPR=$3
	local MATCHES

	MATCHES=$(find "$SEARCH_DIR" -type f -name "$FILE_NAME" 2>/dev/null)
	if [ -n "$MATCHES" ]; then
		while IFS= read -r TARGET_FILE; do
			sed -i "$SED_EXPR" "$TARGET_FILE"
		done <<< "$MATCHES"
	fi
}

# -------------------------------------------------------
# 移除不需要的包
# -------------------------------------------------------

apply_sed_to_matches "./feeds/luci/collections/" "Makefile" "/attendedsysupgrade/d"

# -------------------------------------------------------
# 主题设置（aurora + 编译期默认替换）
# -------------------------------------------------------

if [ -n "$WRT_THEME" ] && [ "$WRT_THEME" != "bootstrap" ]; then
	sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
fi

# -------------------------------------------------------
# IP 与主机名
# -------------------------------------------------------

apply_sed_to_matches "./feeds/luci/modules/luci-mod-system/" "flash.js" "s/192\\.168\\.[0-9]*\\.[0-9]*/$WRT_IP/g"
apply_sed_to_matches "./feeds/luci/modules/luci-mod-status/" "10_system.js" "s/(\\(luciversion || ''\\))/(\\1) + (' \\/ $WRT_MARK-$WRT_DATE')/g"

# -------------------------------------------------------
# 无线 SSID：编译期按频段写入生成器模板（三频分开命名）
# -------------------------------------------------------
# 原版 mac80211.uc 第 112 行：
#     set ${si}.ssid='${defaults?.ssid || 'OWRT'}'
# board.wlan.defaults 在 jdcloud 设备上无定义 → 回退 'OWRT'（三频同名）。
#
# 曾两次走弯路：
#   ① 全局 sed 把三个频段替换成同一个 SSID → 三频合一
#   ② 交给 init.d 运行时设置 → /etc/config/wireless 由 netifd 首次启动才生成，
#      S99 跑在其之前导致空转；且旧版无条件 touch marker → 此后永久不再尝试
#      （实测：刷完仍全是 OWRT）
# 故改为编译期直接生成正确 SSID，与运行时无关、必定生效。
#
# 设备频段布局（轴线实测）：radio1=2.4G / radio0=5G(ahb,IPQ6010内建) /
# radio2=5G(QCN9074 PCIe)。模板中 band_name('2g'/'5g') 与 name('radioN') 均可用。

WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_UC" ]; then
	# SSID：按频段分名（band_name='2g'；两个 5G 用 radio 编号区分）
	sed -i "s#^set \${si}\.ssid=.*#set \${si}.ssid='\${defaults?.ssid || ((band_name == '2g') ? '$WRT_SSID-2.4G' : ((name == 'radio0') ? '$WRT_SSID-5.2G' : '$WRT_SSID-5.8G'))}'#" "$WIFI_UC"

	# 信道与带宽：生成器默认 channel=auto、且 5G 强制 width<=80
	# （源码：else if (width > 80) width = 80），无法表达 HE160。
	# 故编译期按频段写死；init.d 运行时再兜底一次（双保险，避免时序问题）。
	# 取值依据：11/HT20（2.4G 非重叠）、44/HE160（5G-1 游戏，160MHz 主信道）、
	#           149/HE80（5G-2 影音，非 DFS）。
	sed -i "s#^set \${s}\.channel=.*#set \${s}.channel='\${((band_name == '2g') ? '11' : ((name == 'radio0') ? '44' : '149'))}'#" "$WIFI_UC"
	sed -i "s#^set \${s}\.htmode=.*#set \${s}.htmode='\${((band_name == '2g') ? 'HT20' : ((name == 'radio0') ? 'HE160' : 'HE80'))}'#" "$WIFI_UC"

	# 国家码：生成器默认 'CN'（board.wlan.defaults 在本设备无定义 → 回落）。
	# ★ 必须编译期设定：ath11k 对【运行时】切换国家码脆弱 —— 实测 dmesg 报
	#   WARNING at net/wireless/reg.c:4035 reg_get_max_bandwidth [cfg80211]
	#   Call trace: ath11k_regd_update → regulatory_set_wiphy_regd
	#   → ath11k_pci: failed to perform regd update : -22
	#   （init.d 里 uci set country 再 wifi reload 即触发该热切换）
	# 功率：生成器完全不输出 txpower 行，此处插入（保持 US 上限 24dBm）
	sed -i "s#^set \${s}\.country=.*#set \${s}.country='US'\nset \${s}.txpower='24'#" "$WIFI_UC"

	# 加密：生成器默认 psk2+ccmp + 密码 12345678，改为开放。
	# ★ 必须编译期设定 —— 此前只靠 init.d 设 encryption=none，一旦 init.d
	#   失败（时序/marker 等），WiFi 会带默认密码 12345678 而非开放。
	sed -i "s#^set \${si}\.encryption=.*#set \${si}.encryption='none'#" "$WIFI_UC"
	sed -i "s#^set \${si}\.key=.*#set \${si}.key=''#" "$WIFI_UC"

	echo "RivWRT: per-band SSID + channel + htmode + country + txpower + encryption injected"
fi

# -------------------------------------------------------
# 默认 IP / 主机名
# -------------------------------------------------------

CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE"
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"

echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config

# -------------------------------------------------------
# RivWRT 增量配置兜底拼接（不依赖 workflow 层的 WRT_EXTRA_CONFIG）
# 实测 6dfacd3 固件：VERSION_DIST 与 rivwrt-nss 行均未生效，而同在
# 基座 GENERAL_AX6600.txt 的 qca-nss-ecm 生效 → 疑似增量文件未被拼接。
# 这里无条件再拼一次（kconfig 对重复行取最后值，幂等安全）。
# -------------------------------------------------------
RIVWRT_CFG="$GITHUB_WORKSPACE/Config/GENERAL_AX6600_RIVWRT.txt"
if [ -f "$RIVWRT_CFG" ]; then
	cat "$RIVWRT_CFG" >> ./.config
	echo "RivWRT: increment config appended (fallback, $(grep -c '^CONFIG' "$RIVWRT_CFG") lines)"
fi

# -------------------------------------------------------
# 高通平台 DTS 调整
# -------------------------------------------------------

if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	DTS_PATH="./target/linux/qualcommax/dts/"
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

# -------------------------------------------------------
# 内存水位线调优
# -------------------------------------------------------

MIN_FREE_VAL=16384
CONF_FILE="./package/base-files/files/etc/sysctl.conf"
CURRENT_VAL=$(sed -n 's/^vm\.min_free_kbytes=\([0-9]\+\).*/\1/p' "$CONF_FILE")

if [ -z "$CURRENT_VAL" ]; then
	echo "" >> "$CONF_FILE"
	echo "vm.min_free_kbytes=$MIN_FREE_VAL" >> "$CONF_FILE"
	echo "Memory patch: value not found, added $MIN_FREE_VAL."
else
	if [ "$CURRENT_VAL" -lt "$MIN_FREE_VAL" ]; then
		sed -i "s/^vm\.min_free_kbytes=.*/vm.min_free_kbytes=$MIN_FREE_VAL/" "$CONF_FILE"
		echo "Memory patch: upgraded $CURRENT_VAL -> $MIN_FREE_VAL."
	else
		echo "Memory patch: current value ($CURRENT_VAL) is sufficient, skipped."
	fi
fi

# -------------------------------------------------------
# RivWRT：登录 banner（figlet 字样 + 格言 + 组件行）
# -------------------------------------------------------

BANNER="./package/base-files/files/etc/banner"
[ -f "$BANNER" ] && cat > "$BANNER" <<'RIVWRT_BANNER'
'||''|.    ||           '|| '||'  '|' '||''|.   |''||''| 
 ||   ||  ...  .... ...  '|. '|.  .'   ||   ||     ||    
 ||''|'    ||   '|.  |    ||  ||  |    ||''|'      ||    
 ||   |.   ||    '|.|      ||| |||     ||   |.     ||    
.||.  '|' .||.    '|        |   |     .||.  '|'   .||.    

           " Flow downstream, not upstream. "

 =======================================================
   RivWRT - based on ones20250/Openwrt-AX6600
   aurora / athena-led / bandix-plus / daede / nss
   ImmortalWrt %V, %C
 =======================================================
RIVWRT_BANNER

# -------------------------------------------------------
# RivWRT：openwrt_release 品牌硬钉（不依赖 kconfig 的 VERSION_DIST）
# CONFIG_VERSION_DIST 的 prompt 挂在 "if DEVEL" 下，defconfig 可能丢弃
# 用户值回落 default "ImmortalWRT"（实测 6dfacd3 固件未生效）。
# 故直接改 base-files 的 openwrt_release 模板：DISTRIB_ID/DESCRIPTION
# 硬编码 RivWRT，%V/%C 仍由构建系统展开（版本号/revision 照常显示）。
# 该模板会被 VERSION_SED 处理，属官方机制内的注入点，升级安全。
# -------------------------------------------------------
RELEASE_FILE="./package/base-files/files/etc/openwrt_release"
if [ -f "$RELEASE_FILE" ]; then
	sed -i "s/^DISTRIB_ID=.*/DISTRIB_ID='RivWRT'/" "$RELEASE_FILE"
	# 把构建时间戳一并写进版本描述：设备上 `cat /etc/openwrt_release` 或
	# LuCI 概览页即可直接核对刷的是哪个 release（与 release tag / 固件文件名
	# 里的时间戳是同一个值，来自 CI 的 WRT_DATE）。
	# 起因：此前版本描述只有模糊的 %V/%C，实测出现过"以为刷了新版、其实刷了旧版"
	# 的困扰 —— 旧构建里 luci-app-mwan3 因 Makefile 路径问题未编入，却被当成
	# "新代码没生效"排查了很久。有了这个时间戳，一眼可辨。
	# WRT_DATE 缺失时（本地模拟）退回 dev，不留空括号。
	BUILD_TAG="${WRT_DATE:-dev}"
	sed -i "s/^DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION='RivWRT %V %C build-${BUILD_TAG}'/" "$RELEASE_FILE"
	echo "RivWRT: openwrt_release branded (DISTRIB_ID/DESCRIPTION, build=$BUILD_TAG)"
fi
# -------------------------------------------------------
# RivWRT：内核分区尺寸适配（A 槽 12MiB 内核）
# -------------------------------------------------------

IMG_MK="./target/linux/qualcommax/image/ipq60xx.mk"
if [ -f "$IMG_MK" ]; then
	sed -i "/Device\/jdcloud_re-cs-02/,/TARGET_DEVICES += jdcloud_re-cs-02/ s/KERNEL_SIZE := 6144k/KERNEL_SIZE := 12288k/" "$IMG_MK"
	# 断言"最终状态"而非"sed 命中"：若上游某天自己改成 12288k，这里同样通过。
	# 反过来，上游若调整了设备段结构导致 sed 落空，则立即失败 —— 否则会编出
	# 一个按 6MiB 分区布局的固件，刷进去与设备的 12MiB 内核分区不匹配。
	if awk '/Device\/jdcloud_re-cs-02/,/TARGET_DEVICES \+= jdcloud_re-cs-02/' "$IMG_MK" \
		| grep -q 'KERNEL_SIZE := 12288k'; then
		echo "RivWRT: KERNEL_SIZE -> 12288k (A槽 12MiB 内核分区)"
	else
		echo "RivWRT: ERROR - KERNEL_SIZE patch missed in $IMG_MK (设备段结构变了？)" >&2
		exit 1
	fi
fi

# -------------------------------------------------------
# RivWRT：DTS 端口 label 互换（根治网口互换）
# 实测映射：丝印 WAN(2.5G)=dp5(wan)，丝印 LAN1=dp1(lan1)
# 互换后：系统名 = 物理丝印 = 角色语义一致
# -------------------------------------------------------

DTS_FILE="./target/linux/qualcommax/dts/ipq6010-re-cs-02.dts"

# 端口命名最终形态（丝印 → 系统名）：
#   丝印 WAN（2.5G）   → lan1
#   丝印 LAN1（千兆）  → wan1
#   丝印 LAN2（千兆）  → wan2   ← 第二条宽带
#   丝印 LAN3 / LAN4   → lan3 / lan4
#
# 一条 sed 处理三处（多 -e 一次读写，避免中途状态被后续规则误伤）：
#   &dp1 段：lan1 → wan1
#   &dp5 段：wan  → lan1
#   &dp2 段：lan2 → wan2
# sed 的地址范围 /&dpN {/,/};/ 把每条规则限定在对应端口节点内，互不干扰。
#
# 注：DTS 里的 switch_lan_bmp / switch_wan_bmp 【不需要】跟着改 ——
#     全树检索确认这两个属性只出现在各设备 DTS 中，没有任何 .c/.h 驱动读取，
#     属 QSDK 遗留的装饰性属性；端口分组实际由 DTS 的 label + netifd 配置决定。
sed -i \
	-e "/&dp1 {/,/};/ s/label = \"lan1\"/label = \"wan1\"/" \
	-e "/&dp2 {/,/};/ s/label = \"lan2\"/label = \"wan2\"/" \
	-e "/&dp5 {/,/};/ s/label = \"wan\"/label = \"lan1\"/" \
	"$DTS_FILE"

# 断言最终 label（不看 sed 是否命中）：三个端口节点各自改对才算过。
# 这个改动若静默失效，编出来的固件网口角色会错位 —— 用户按 README 接线会接错口。
dts_label() {
	awk "/^&$1 \{/,/^};/" "$DTS_FILE" | sed -n 's/.*label = "\([^"]*\)".*/\1/p' | head -1
}
if [ "$(dts_label dp1)" = "wan1" ] && [ "$(dts_label dp2)" = "wan2" ] && [ "$(dts_label dp5)" = "lan1" ]; then
	echo "RivWRT: DTS port labels -> dp1=wan1 dp2=wan2 dp5=lan1"
else
	echo "RivWRT: ERROR - DTS label patch missed (dp1=$(dts_label dp1) dp2=$(dts_label dp2) dp5=$(dts_label dp5)，期望 wan1/wan2/lan1)" >&2
	exit 1
fi

# --- 同步默认网络配置（02_network）---
# 上游对本设备写死 LAN = "lan1 lan2 lan3 lan4"、WAN = "wan"。改名后该列表里的
# lan2 已不存在、wan 也不存在，会向 br-lan 塞入无效成员、并让 WAN 指向不存在的设备。
#
# 该行与 gl-ax1800 / nn6000-v2 / mr7350 / mr7500 / fap650 共用；本固件只编
# jdcloud_re-cs-02，且已确认该字符串全树唯一，改动不影响其它设备。
#
# ★ 双 WAN 必须拆成两个独立接口：ucidef_set_interfaces_lan_wan 的 wan 参数若含
#   空格会被当作 bridge 成员（读实现可知走的是 json_select_array "ports"），
#   结果是"两个口桥成一个 WAN"而非两条独立上行，故 wan2 单独声明。
#   proto 暂用 none：接线后在「网络 → 接口」里按实际线路选 DHCP/PPPoE。
NW_BD="./target/linux/qualcommax/ipq60xx/base-files/etc/board.d/02_network"
sed -i 's|ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4" "wan"|ucidef_set_interfaces_lan_wan "lan1 lan3 lan4" "wan1"\n\t\tucidef_set_interface "wan2" device "wan2" protocol "none"|' "$NW_BD"

# 断言最终状态：LAN 列表已剔除 lan2、上行名为 wan1、且 wan2 已单独声明。
# 静默失效的后果：默认 network 配置里 br-lan 挂着不存在的 lan2、WAN 指向不存在的
# wan1 —— 首次刷机后直接没网，且现象会被误判为"驱动问题"。
if grep -q 'ucidef_set_interfaces_lan_wan "lan1 lan3 lan4" "wan1"' "$NW_BD" && \
   grep -q 'ucidef_set_interface "wan2" device "wan2"' "$NW_BD"; then
	echo "RivWRT: 02_network -> lan(1,3,4) + wan1 + wan2"
else
	echo "RivWRT: ERROR - 02_network patch missed in $NW_BD（设备分支结构变了？）" >&2
	exit 1
fi

# --- 防火墙 zone 纳入两条上行 ---
# zone 的【名字】保持 wan 不动：firewall.config 里有 11 处 option src/dest 'wan'
# 引用它（入站拒绝、转发拒绝、NAT 伪装等规则），改 zone 名要连带改这些引用，
# 收益为零。只把它的 network 列表由 'wan' 换成 'wan1' 'wan2' —— 这样两条线路
# 共用同一套 WAN 策略（masq、入站 REJECT、转发 REJECT）。
FW_CFG="./package/network/config/firewall/files/firewall.config"
if [ -f "$FW_CFG" ]; then
	# 模式锚定整行：list   network<TAB><TAB>'wan' —— 不能只匹配 'wan'，
	# 因为 option src 'wan' 等 11 处也有同样的引号形态。
	sed -i "s|^\(\t*\)list   network\t\t'wan'$|\1list   network\t\t'wan1'\n\1list   network\t\t'wan2'|" "$FW_CFG"
	# 断言：sed 未命中会静默不改，届时两条上行都进不了 wan zone（无 NAT、入站策略失效），
	# 而这种错误在编译日志里看不出来，必须显式失败。
	if grep -q "'wan1'" "$FW_CFG"; then
		echo "RivWRT: firewall wan zone -> wan1 + wan2"
	else
		echo "RivWRT: ERROR - firewall zone patch missed (pattern drift?)" >&2
		exit 1
	fi
else
	echo "RivWRT: ERROR - $FW_CFG not found" >&2
	exit 1
fi


# -------------------------------------------------------
# RivWRT：daede 暗色屏蔽
# -------------------------------------------------------

CFG_JS=$(find ./package/luci-app-daede -name "config.js" 2>/dev/null | head -1)
[ -n "$CFG_JS" ] && sed -i "s#document\.documentElement\.setAttribute('data-darkmode', 'true');#/* RivWRT: keep global dark-mode flag untouched */#" "$CFG_JS"

# -------------------------------------------------------
# RivWRT：mwan3 双 WAN 初始配置
#
# 直接覆盖包自带的 files/etc/config/mwan3（Settings.sh 在 Packages.sh 之后执行，
# 包已克隆到位）——配置随包走，首启即生效，无需再挂一条 uci-defaults。
# -------------------------------------------------------

MWAN3_DIR="./package/mwan3"
if [ -d "$MWAN3_DIR/files/etc/config" ]; then
	cat > "$MWAN3_DIR/files/etc/config/mwan3" <<'RIVWRT_MWAN3'
# RivWRT 多 WAN 配置（由 Scripts/Settings.sh 生成；上游默认值已被本文件取代）
#
# 【默认不接管流量】下面所有 rule 的 enabled 都是 0。当前只有一条宽带时让
# mwan3 接管默认路由没有收益，只会多出与 dae / NSS 的 fwmark 交互面。
# 接好第二条线、并在「网络 → 接口」里把 wan2 的协议配好之后，把
# default_rule_v4 的 enabled 改成 1，负载均衡/故障切换才开始生效
# （也可以直接在「网络 → 多WAN管理器」里调）。
#
# track_ip 换成国内稳定可达的地址：上游默认是 1.0.0.1 / 208.67.x.x 等，
# 国内探测容易误判为"线路故障"从而错误切走流量。
# 三个 IP + reliability 2 = 至少两个可达才算该线路健康。
#
# mmx_mask 0x3F00（bits 8-13）是 mwan3 默认值，用它标记"该走哪条 WAN"。
# 若日后与 dae 的 fwmark 冲突，改这里即可（mwan3 会按新掩码重建规则）。

config globals 'globals'
	option mmx_mask '0x3F00'

# --- 第一条线路：wan1（物理丝印 LAN1，千兆 dp1）---
config interface 'wan1'
	option enabled '1'
	option family 'ipv4'
	option reliability '2'
	list track_ip '223.5.5.5'
	list track_ip '119.29.29.29'
	list track_ip '180.76.76.76'

# --- 第二条线路：wan2（物理丝印 LAN2，千兆 dp2）---
# enabled 0 = 尚未接线，不做探测（省一次持续 ping）。接线并配好协议后改 1。
config interface 'wan2'
	option enabled '0'
	option family 'ipv4'
	option reliability '2'
	list track_ip '223.5.5.5'
	list track_ip '119.29.29.29'
	list track_ip '180.76.76.76'

# --- 成员：等权，两条线路各占一半（weight 1:1）---
# 想按带宽比分配就改 weight，例如 1000M + 500M → 2:1。
config member 'wan1_m1_w1'
	option interface 'wan1'
	option metric '1'
	option weight '1'

config member 'wan2_m1_w1'
	option interface 'wan2'
	option metric '1'
	option weight '1'

# --- 策略 ---
config policy 'balanced'
	list use_member 'wan1_m1_w1'
	list use_member 'wan2_m1_w1'

config policy 'wan1_only'
	list use_member 'wan1_m1_w1'

config policy 'wan2_only'
	list use_member 'wan2_m1_w1'

# --- 规则：默认全部未启用（见文件头）---
config rule 'default_rule_v4'
	option enabled '0'
	option dest_ip '0.0.0.0/0'
	option family 'ipv4'
	option use_policy 'balanced'
RIVWRT_MWAN3
	echo "RivWRT: mwan3 dual-WAN config applied (rules disabled by default)"
else
	echo "RivWRT: WARNING - ./package/mwan3 not found, mwan3 config skipped"
fi


# -------------------------------------------------------
# RivWRT：uci-defaults 目标目录
# -------------------------------------------------------

UDIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UDIR"

# -------------------------------------------------------
# RivWRT：修正第三方 LuCI 包的 luci.mk 引用路径
#
# 第三方 LuCI 包的 Makefile 常用 `include ../../luci.mk` —— 这是给
# feeds/luci/applications/<pkg>/ 那种层级写的相对路径。本固件按惯例把这类包
# 克隆到 package/ 下，../../luci.mk 会解析成 wrt/luci.mk（不存在）→ 构建失败。
# （本仓库其它第三方 LuCI 包如 aurora 用的是 $(TOPDIR)/feeds/luci/luci.mk 绝对路径，
#   所以没踩过；dl12345/luci-app-mwan3 用的是相对路径。）
#
# 这里统一扫描修正，而非只针对某个包 —— 将来加新包也不会再踩。
# 模式不锚定行首尾，容错缩进/多空格等写法差异。
LUCIMK_FIXED=""
for mk in $(grep -rl '\.\./\.\./luci\.mk' ./package/*/Makefile 2>/dev/null); do
	sed -i 's|\.\./\.\./luci\.mk|$(TOPDIR)/feeds/luci/luci.mk|g' "$mk"
	LUCIMK_FIXED="$LUCIMK_FIXED $(basename "$(dirname "$mk")")"
done
if [ -n "$LUCIMK_FIXED" ]; then
	echo "RivWRT: luci.mk path fixed for:$LUCIMK_FIXED"
fi
# 断言：package/ 下不应再有指向 ../../luci.mk 的引用。
# 漏改会导致该包构建直接失败（wrt/luci.mk 不存在），故此处显式拦下而不是留给 CI。
if grep -rq '\.\./\.\./luci\.mk' ./package/*/Makefile 2>/dev/null; then
	echo "RivWRT: ERROR - 仍有包以相对路径引用 luci.mk（会构建失败）:" >&2
	grep -rl '\.\./\.\./luci\.mk' ./package/*/Makefile 2>/dev/null | sed 's/^/  /' >&2
	exit 1
fi

# -------------------------------------------------------
# RivWRT：让 LuCI 的资源版本号随构建变化（否则浏览器永久复用旧 JS）
#
# 现象（实测两次被误导）：镜像里确认已包含新的页面代码，设备上打开的 LuCI 页面
# 却仍是旧行为 —— 显示早已删除的控件、按钮点了没反应、图表不出数据。
#
# 根因链（逐环读源码确认）：
#   ① LuCI 用 `luci.js?v=<resource_version>` 作为所有前端资源的缓存键
#      （luci-base/ucode/template/header.ut:10）
#   ② resource_version = env.pkgs_update_time
#      （luci-base/ucode/runtime.uc:182）
#   ③ pkgs_update_time = stat('/usr/lib/opkg/status').mtime
#   ④ 而 include/rootfs.mk:126 会把整个 rootfs 的文件 mtime 统一 touch 成
#      SOURCE_DATE_EPOCH：
#        $(if $(SOURCE_DATE_EPOCH),find $(1)/ -mindepth 1 -execdir touch -hcd "@$(SOURCE_DATE_EPOCH)" "{}" +)
#   ⑤ SOURCE_DATE_EPOCH 来自源码树的 git 提交时间
#      （scripts/get_source_date_epoch.sh 的 try_git）。
#      我们的改动都在【配置仓库】fork，而源码仓库（PurpleRed-River/immortalwrt）
#      不变 → 该值恒定 → 缓存键恒定 → 浏览器永远复用第一次缓存的 JS。
#
# 修法：把 pkgs_update_time 绑定到构建时刻，使每次编译都产生新的资源版本号，
# 浏览器随即重新拉取。该变量只被 header.ut 的资源 URL 使用（全仓仅此一处引用），
# 覆盖它不影响其它逻辑。
# 注：sed 用 [[:space:]] 而非 \s —— 构建机上可能是 busybox sed，不支持 \s。
# -------------------------------------------------------
LUCI_RUNTIME="./feeds/luci/modules/luci-base/ucode/runtime.uc"
if [ -f "$LUCI_RUNTIME" ]; then
	BUILD_EPOCH=$(date +%s)
	sed -i "s|^\([[:space:]]*\)self\.env\.pkgs_update_time = .*|\1self.env.pkgs_update_time = $BUILD_EPOCH;|" "$LUCI_RUNTIME"
	if grep -q "pkgs_update_time = $BUILD_EPOCH;" "$LUCI_RUNTIME"; then
		echo "RivWRT: LuCI 资源版本号已绑定构建时刻 ($BUILD_EPOCH)"
	else
		echo "RivWRT: ERROR - LuCI 资源版本号改写失败（runtime.uc 结构变了？）" >&2
		exit 1
	fi
else
	echo "RivWRT: ERROR - 未找到 $LUCI_RUNTIME（feeds 结构变了？）" >&2
	exit 1
fi

# -------------------------------------------------------
# uci-defaults：FullCone NAT（IPv4）
# -------------------------------------------------------

cat > "$UDIR/96-rivwrt-fullcone" <<'RIVWRT_FC'
#!/bin/sh
uci -q set firewall.@defaults[0].fullcone='1'
uci commit firewall
RIVWRT_FC
chmod +x "$UDIR/96-rivwrt-fullcone"

# -------------------------------------------------------
# uci-defaults：网络配置对新端口命名的纠正
# -------------------------------------------------------

cat > "$UDIR/98-rivwrt-net-fix" <<'RIVWRT_NETFIX'
#!/bin/sh
# RivWRT 网口规范化（幂等；由 uci-defaults 在每次首启/升级后执行一次）
#
# 目标形态（物理丝印 → 系统接口名）：
#   丝印 WAN (2.5G)  → lan1
#   丝印 LAN1 (千兆) → wan1
#   丝印 LAN2 (千兆) → wan2    ← 第二条宽带
#   丝印 LAN3 / LAN4 → lan3 / lan4
#
# 除了新刷机的默认配置，本脚本还负责【保留配置升级】的迁移：
# 旧固件的上行接口名是 wan，新固件叫 wan1。若不迁移，升级后 network.wan 仍在、
# network.wan1 不存在，mwan3 找不到它要管理的接口 —— 表现为"双 WAN 配了但没生效"。
# 这个失败是静默的，所以必须在这里处理掉，而不是留给用户排查。

# --- 1) br-lan 成员：lan2 已改作 wan2，必须从网桥里剔除 ---
# 不剔的话 br-lan 会带上一个不属于它的端口，且该口同时出现在两条上行里。
for DEV in 0 1 2 3 4; do
	NAME=$(uci -q get network.@device[$DEV].name)
	[ "$NAME" = "br-lan" ] && uci set network.@device[$DEV].ports='lan1 lan3 lan4'
done

# --- 2) 旧接口名迁移 wan → wan1（仅当 wan1 尚不存在时执行）---
if uci -q get network.wan >/dev/null 2>&1 && ! uci -q get network.wan1 >/dev/null 2>&1; then
	uci -q rename network.wan=wan1
	echo "RivWRT: migrated network.wan -> network.wan1"
fi

# --- 3) 确保两条上行齐备，且 device 指向正确的物理口 ---
# 缺哪个补哪个（proto 用 none：接线后由用户在界面里按实际线路选 DHCP/PPPoE）
if ! uci -q get network.wan1 >/dev/null 2>&1; then
	uci -q set network.wan1=interface
	uci -q set network.wan1.proto='none'
fi
uci -q set network.wan1.device='wan1'

if ! uci -q get network.wan2 >/dev/null 2>&1; then
	uci -q set network.wan2=interface
	uci -q set network.wan2.proto='none'
fi
uci -q set network.wan2.device='wan2'

# --- 4) IPv6 上行 wan6 ---
# qualcommax 平台的 991_set-network.sh 会执行 `uci set network.wan6.reqaddress`，
# 而 uci set 对不存在的 section 会【直接创建】—— 它自己造出一个 wan6 却没设
# device/proto，于是留下一个无设备的空接口（实测反馈"多出来一个 wan6"，
# 在 LuCI 里显示异常，IPv6 也不工作）。
# 这里先把它建完整。98 必定早于 991 执行（字典序 '8' < '9'），991 随后只是
# 在这基础上补 reqaddress/reqprefix，不会再产生空壳 —— 这样就不依赖对
# uci-defaults 排序细节的推断。
# 若不需要 IPv6：在「网络 → 接口」里禁用 wan6，或 uci delete network.wan6。
if ! uci -q get network.wan6 >/dev/null 2>&1; then
	uci -q set network.wan6=interface
	uci -q set network.wan6.device='wan1'
	uci -q set network.wan6.proto='dhcpv6'
else
	# 已存在（保留配置升级）：补缺失字段，并把【旧接口名】迁到新名。
	# 注意不能只判空：旧固件的 device 是 wan（已改名），若不迁则 wan6 指向
	# 不存在的设备 —— 与 wan1/wan2 的迁移同理，静态看也不会报错。
	_w6dev=$(uci -q get network.wan6.device)
	case "$_w6dev" in
		""|wan) uci -q set network.wan6.device='wan1' ;;
	esac
	_w6proto=$(uci -q get network.wan6.proto)
	if [ -z "$_w6proto" ] || [ "$_w6proto" = "none" ]; then
		uci -q set network.wan6.proto='dhcpv6'
	fi
fi

uci commit network

# --- 5) 修正 /etc/board.json 的端口信息（影响 LuCI 端口卡片与区域显示）---
# 背景：LuCI 首页「端口状态」（luci-mod-status 的 view/status/include/29_ports.js）
# 的端口列表来自 ubus `luci.getBuiltinEthernetPorts`，该接口对非 x86/ARM 平台
# （qualcommax 属于此类）只从 /etc/board.json 读 `network.lan` 与 `network.wan`
# 两个角色 —— 【wan2 不在其中，因此永远不显示】；而 board.json 在保留配置升级
# 时被保留（preinit 的 82_config_generate 只在文件不存在时才重新生成），于是
# 端口名还停留在旧值（含已不存在的 lan2、上行仍叫 wan）。
#
# 为什么这里改它是安全的：config_generate 第一件事就是
#     [ -s /etc/config/network -a -s /etc/config/system ] && exit 0
# 即 /etc/config/network 已存在时它直接退出，不再用 board.json 生成网络配置。
# 本脚本跑在 uci-defaults 阶段，此时 network 配置已就绪，故改 board.json
# 只影响 LuCI 显示，不会动到网络行为。
#
# 写法要点：lan 用 ports（对应 br-lan 成员），wan 也用 ports —— LuCI 的取值逻辑是
#     if (type(board.network[k].ports) == 'array') for (let ifname in ports) push(...)
# 用数组才能显示多个；且 ucode 的 for..in 对数组返回【元素】而非索引
# （见 ucode 文档 for (arr in arrays) { push(result, ...arr) }），所以显示的是
# 端口名本身而不是 0/1/2。
BOARD_JSON=/etc/board.json
if [ -f "$BOARD_JSON" ] && command -v ucode >/dev/null 2>&1; then
	_bj_tmp="${BOARD_JSON}.new"
	if ucode -e '
		let fd = open("/etc/board.json", "r");
		if (!fd) exit(1);
		let b = json(fd);
		fd.close();
		b.network = b.network || {};
		b.network.lan = { "protocol": "static", "ports": [ "lan1", "lan3", "lan4" ] };
		b.network.wan = { "protocol": "dhcp", "ports": [ "wan1", "wan2" ] };
		printf("%J", b);
	' > "$_bj_tmp" 2>/dev/null && [ -s "$_bj_tmp" ]; then
		# 落盘前校验：必须是合法 JSON，且含预期端口（防止半截写入把 board.json 弄坏）
		if ucode -e '
			let fd = open("/etc/board.json.new", "r");
			if (!fd) exit(1);
			let b = json(fd);
			fd.close();
			let w = b?.network?.wan?.ports, l = b?.network?.lan?.ports;
			exit((type(w) == "array" && index(w, "wan2") != -1
			      && type(l) == "array" && index(l, "lan1") != -1) ? 0 : 1);
		' 2>/dev/null; then
			mv -f "$_bj_tmp" "$BOARD_JSON"
			echo "RivWRT: board.json 端口信息已更新（lan1 lan3 lan4 / wan1 wan2）"
		else
			rm -f "$_bj_tmp"
			echo "RivWRT: WARNING - board.json 校验未通过，保持原样" >&2
		fi
	else
		rm -f "$_bj_tmp"
		echo "RivWRT: WARNING - board.json 重写失败，保持原样" >&2
	fi
fi
RIVWRT_NETFIX
chmod +x "$UDIR/98-rivwrt-net-fix"

# -------------------------------------------------------
# uci-defaults：podman API 服务默认关闭
# -------------------------------------------------------

cat > "$UDIR/99-rivwrt-podman" <<'RIVWRT_PODMAN'
#!/bin/sh
/etc/init.d/podman stop 2>/dev/null
/etc/init.d/podman disable 2>/dev/null
RIVWRT_PODMAN
chmod +x "$UDIR/99-rivwrt-podman"

# -------------------------------------------------------
# uci-defaults：菜单归拢
# -------------------------------------------------------

cat > "$UDIR/99-rivwrt-menus" <<'RIVWRT_MENUS'
#!/bin/sh
[ -f /usr/share/luci/menu.d/luci-app-wolultra.json ] && \
	sed -i "s#\"admin/control/wolultra\"#\"admin/services/wolultra\"#" /usr/share/luci/menu.d/luci-app-wolultra.json
[ -f /usr/share/luci/menu.d/luci-app-samba4.json ] && \
	sed -i "s#\"admin/nas/samba4\"#\"admin/services/samba4\"#" /usr/share/luci/menu.d/luci-app-samba4.json
[ -f /usr/share/luci/menu.d/luci-app-bandix-plus.json ] && \
	sed -i "s#admin/network/bandix_plus#admin/services/bandix_plus#g" /usr/share/luci/menu.d/luci-app-bandix-plus.json
RIVWRT_MENUS
chmod +x "$UDIR/99-rivwrt-menus"


# =========================================================
# RivWRT：podman-compose 包（上游 feeds 无此包，自建）
# PyPI sdist 打包，依赖 python3 + python3-yaml + python3-dotenv
# 版本与哈希已钉死，纯 Python 无需编译
# =========================================================
PCDIR=./package/podman-compose
mkdir -p $PCDIR
cat > $PCDIR/Makefile <<'EOF'
include $(TOPDIR)/rules.mk

PKG_NAME:=podman-compose
PKG_VERSION:=1.6.0
PKG_RELEASE:=1

PKG_SOURCE:=podman_compose-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://files.pythonhosted.org/packages/1f/80/a6ada19562b12ed466dac5c3e02aef5ed7c8d0881864d80e0d94d0dc71f5/
PKG_HASH:=c83fd9bcbaa635100d581ce52a7a4b712ee0d457481232aff392efe3ebc5a217
PKG_BUILD_DIR:=$(BUILD_DIR)/podman_compose-$(PKG_VERSION)

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=RivWRT

include $(INCLUDE_DIR)/package.mk

define Package/podman-compose
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=docker-compose implementation for podman (CLI)
  DEPENDS:=+python3 +python3-yaml +python3-dotenv +podman
endef

define Package/podman-compose/description
  podman-compose: run docker-compose.yml stacks with podman (CLI only).
endef

Build/Compile:=:

define Package/podman-compose/install
	$(INSTALL_DIR) $(1)/usr/lib/podman-compose
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/podman_compose.py $(1)/usr/lib/podman-compose/podman_compose.py
	$(INSTALL_DIR) $(1)/usr/bin
	$(LN) ../lib/podman-compose/podman_compose.py $(1)/usr/bin/podman-compose
endef

$(eval $(call BuildPackage,podman-compose))
EOF

# =========================================================
# RivWRT：luci-app-rivwrt-nss —— NSS 开关与状态页（独立包）
# =========================================================
PKGDIR=./package/luci-app-rivwrt-nss
mkdir -p $PKGDIR/root/usr/share/luci/menu.d \
	$PKGDIR/root/usr/share/rpcd/acl.d \
	$PKGDIR/root/www/luci-static/resources/view/rivwrt \
	$PKGDIR/root/usr/libexec/rivwrt

cat > $PKGDIR/Makefile <<'EOF'
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-rivwrt-nss
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=RivWRT NSS acceleration toggle and live status
# rrdtool1 提供 /usr/bin/rrdtool —— nss-status 用它读 RRD 历史。
# 此前仅靠 luci-app-statistics 间接带入（它依赖 +rrdtool1），属隐式依赖；
# 若该 app 被移除，历史图会静默失效。此处显式声明 +collectd-mod-exec
# （采集 NSS 负载所需；stat-genconfig 据此生成 Exec 行）。
# 注：开关走的 ubus rc 对象由 rpcd 主程序 rc.c 无条件注册
#     （main.c: rpc_rc_api_init），随 +luci-base → +rpcd 带入，
#     不需要 rpcd-mod-rpcsys —— 后者只提供 system 对象
#     （sysupgrade/password/reboot/factory）。
LUCI_DEPENDS:=+luci-base +rrdtool1 +collectd-mod-exec
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/description
  RivWRT 定制：NSS 硬件加速开关与实时状态（引擎负载/时钟/加速连接数）
endef

# call BuildPackage - OpenWrt buildroot signature
EOF

cat > $PKGDIR/root/usr/share/luci/menu.d/luci-app-rivwrt-nss.json <<'EOF'
{
	"admin/services/rivwrt_nss": {
		"title": "NSS 加速",
		"order": 30,
		"action": { "type": "firstchild" },
		"depends": { "acl": [ "luci-app-rivwrt-nss" ], "fs": { "/etc/init.d/qca-nss-ecm": "file" } }
	},
	"admin/services/rivwrt_nss/status": {
		"title": "状态与开关",
		"order": 10,
		"action": { "type": "view", "path": "rivwrt/nss" },
		"depends": { "acl": [ "luci-app-rivwrt-nss" ] }
	}
}
EOF

cat > $PKGDIR/root/usr/share/rpcd/acl.d/luci-app-rivwrt-nss.json <<'EOF'
{
	"luci-app-rivwrt-nss": {
		"description": "Grant access to RivWRT NSS control and status",
		"read": {
			"ubus": {
				"file": [ "exec" ]
			},
			"file": {
				"/usr/libexec/rivwrt/nss-status": [ "exec" ],
				"/usr/libexec/rivwrt/nss-status 2h": [ "exec" ],
				"/usr/libexec/rivwrt/nss-status 12h": [ "exec" ],
				"/usr/libexec/rivwrt/nss-status 1d": [ "exec" ],
				"/usr/libexec/rivwrt/nss-status 1w": [ "exec" ]
			}
		},
		"write": {
			"ubus": {
				"file": [ "exec" ],
				"rc": [ "init" ]
			},
			"file": {
				"/usr/libexec/rivwrt/nss-status": [ "exec" ],
				"/usr/libexec/rivwrt/nss-status 2h": [ "exec" ],
				"/usr/libexec/rivwrt/nss-status 12h": [ "exec" ],
				"/usr/libexec/rivwrt/nss-status 1d": [ "exec" ],
				"/usr/libexec/rivwrt/nss-status 1w": [ "exec" ],
				"/usr/bin/nss_freq mid": [ "exec" ],
				"/usr/bin/nss_freq high": [ "exec" ]
			}
		}
	}
}
EOF

cat > $PKGDIR/root/www/luci-static/resources/view/rivwrt/nss.js <<'EOF'
'use strict';
'require view';
'require poll';
'require rpc';
'require dom';
'require ui';

/* RivWRT NSS 加速：开关 + 负载历史图
   数据源：/usr/libexec/rivwrt/nss-status（debugfs 实时 + RRD 历史）
   控制：/etc/init.d/qca-nss-ecm start|stop|enable|disable
   样式沿用 aurora 主题 token（var(--brand) 等，附 sRGB 回退值） */

var NS = 'http://www.w3.org/2000/svg';
var RANGES = { '2h': '2 小时', '12h': '12 小时', '1d': '1 天', '1w': '1 周' };
var LABEL = { '2h': '30s 采样', '12h': '2.5min 聚合', '1d': '5min 聚合', '1w': '30min 聚合' };

/* 不设 expect: {code:0}：命令失败时 Promise 会被 reject，错误被 LuCI 吞掉，
   用户只看到"点击没反应"。改为手动检查返回并提示。 */
var callExec = rpc.declare({
	object: 'file', method: 'exec',
	params: [ 'command', 'params' ]
});

/* 开关走 ubus 的 rc 对象（rc.init），而非 file.exec 跑 /etc/init.d/*：
   这是 LuCI 官方做法（luci-mod-system/startup.js 同款），
   无需在 acl 里逐条列举"含参数的完整命令"（rpcd 对 file.exec 的
   鉴权要求 cmdline 精确匹配，脆弱且易错）。

   ★ 这里【只】用 rc.init，不用 rc.list 的 enabled 字段。
     rc.c 的 rc_list_readdir() 解析 init 脚本时只读前 11 行
     （count <= 10 上限），而 qca-nss-ecm.init 有 16 行版权头、
     START=26 落在第 18 行 → rc.list 恒报 enabled=false，哪怕服务
     确实会自启（LuCI 官方「系统→启动项」页对同一脚本同样误报）。
     自启状态改由 nss-status 直接 glob /etc/rc.d/S??qca-nss-ecm 判定，
     语义等同 rc.common 的 enabled()，详见该脚本内注释。 */
var callRcInit = rpc.declare({
	object: 'rc', method: 'init', params: [ 'name', 'action' ]
});

function sx(tag, attrs) {
	var e = document.createElementNS(NS, tag);
	for (var k in (attrs || {}))
		e.setAttribute(k, attrs[k]);
	return e;
}

/* 采集状态。只在【翻转】时提示一次 —— 本函数由页面每 5 秒轮询一次，
   每次都弹通知会刷爆界面。 */
var lastOk = null;
function readStatus(range) {
	function failed(why) {
		if (lastOk !== false) {
			lastOk = false;
			notifyError(_('读取 NSS 状态失败：%s').format(why));
		}
		return { load: {}, stats: 'error' };
	}

	return callExec('/usr/libexec/rivwrt/nss-status', [ range || '2h' ]).then(function (res) {
		/* 原实现在此无条件吞掉失败并返回空对象，于是 ACL 未生效、
		   nss-status 缺失等情况只会表现为"图表一直空着"，且提示语是
		   "首次采集需等待约 30 秒" —— 把故障说成正常等待。 */
		if (!res || res.code !== 0) {
			var detail = (res && res.stderr ? String(res.stderr).trim() : '') || _('无输出');
			return failed(_('退出码 %s：%s').format(
				(res && res.code !== undefined) ? res.code : '?', detail));
		}
		lastOk = true;

		var out = { load: {} };
		(res.stdout || '').split('\n').forEach(function (line) {
			var m = line.match(/^([a-z_0-9]+)=(.*)$/);
			if (!m) return;
			if (m[1].indexOf('load_') === 0)
				out.load[m[1].substring(5)] = m[2];
			else
				out[m[1]] = m[2];
		});
		return out;
	}).catch(function (err) {
		return failed(err && err.message ? err.message : String(err));
	});
}

function notifyError(msg) {
	ui.addNotification(null, E('p', {}, msg), 'error');
}

/* 经 ubus rc.init 执行 init 动作。
   ★ 注意 rc.init 的失败语义：rc.c 的 rc_init_cb() 忽略子进程退出码，
     恒以 UBUS_STATUS_OK 完成请求 —— 即 /etc/init.d/xxx 自身的失败
     （如 modprobe 报错）【不会】回传。此处 if (ret) 与官方 startup.js
     写法一致，但它只在参数/权限等 ubus 层错误时才有意义；
     脚本级失败靠随后的 refresh() 复核（状态没变即失败）。
     catch 分支处理的才是真错误（rc 对象不存在、脚本权限校验不过等）。 */
function control(action) {
	var labels = { start: _('启用'), stop: _('停用'), enable: _('开启自启'), disable: _('关闭自启') };
	var what = labels[action] || action;

	return callRcInit('qca-nss-ecm', action).then(function (ret) {
		if (ret)
			notifyError(_('%s失败（返回码 %s）').format(what, ret));
		return true;
	}).catch(function (err) {
		notifyError(_('%s时调用出错：%s').format(what, err && err.message ? err.message : err));
		return true;
	});
}

/* 单调三次插值（Fritsch–Carlson）：平滑且不过冲 0~100 */
function monotone(xs, ys) {
	var n = xs.length, i;
	if (n < 2) return '';
	var dx = [], dy = [], m = [];
	for (i = 0; i < n - 1; i++) {
		dx[i] = xs[i + 1] - xs[i];
		dy[i] = ys[i + 1] - ys[i];
		m[i] = dx[i] ? dy[i] / dx[i] : 0;
	}
	var t = new Array(n);
	t[0] = m[0]; t[n - 1] = m[n - 2];
	for (i = 1; i < n - 1; i++) {
		if (m[i - 1] * m[i] <= 0) t[i] = 0;
		else {
			var w1 = 2 * dx[i] + dx[i - 1], w2 = dx[i] + 2 * dx[i - 1];
			t[i] = (w1 + w2) / (w1 / m[i - 1] + w2 / m[i]);
		}
	}
	var d = 'M' + xs[0].toFixed(2) + ',' + ys[0].toFixed(2);
	for (i = 0; i < n - 1; i++) {
		var x1 = xs[i] + dx[i] / 3, y1 = ys[i] + t[i] * dx[i] / 3;
		var x2 = xs[i + 1] - dx[i] / 3, y2 = ys[i + 1] - t[i + 1] * dx[i] / 3;
		d += ' C' + x1.toFixed(2) + ',' + y1.toFixed(2) + ' ' + x2.toFixed(2) + ',' + y2.toFixed(2) +
			' ' + xs[i + 1].toFixed(2) + ',' + ys[i + 1].toFixed(2);
	}
	return d;
}

function fmtTime(ts, range) {
	var d = new Date(ts * 1000);
	function z(x) { return (x < 10 ? '0' : '') + x; }
	if (range === '1w' || range === '1d')
		return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + z(d.getHours()) + ':' + z(d.getMinutes());
	return z(d.getHours()) + ':' + z(d.getMinutes()) + ':' + z(d.getSeconds());
}

var CSS = [
'.rw-root{max-width:74rem}',
'.rw-hd{display:flex;align-items:flex-start;justify-content:space-between;gap:18px;flex-wrap:wrap;margin-bottom:22px}',
'.rw-hd h1{font-size:22px;font-weight:700;letter-spacing:-.02em;margin:0}',
'.rw-hd p{font-size:13.5px;color:var(--text-muted,#5f666d);margin:6px 0 0;line-height:1.6}',
'.rw-tag{display:inline-flex;align-items:center;gap:8px;padding:6px 13px;border-radius:999px;font-size:12.5px;font-weight:600;border:1px solid var(--hairline,rgba(18,26,34,.13));background:var(--surface,#fff);box-shadow:var(--app-shadow-sm,0 1px 3px rgba(0,0,0,.06))}',
'.rw-tag i{width:7px;height:7px;border-radius:50%;background:var(--text-subtle,#7f858b);flex-shrink:0;display:block}',
'.rw-tag[data-s=run]{color:var(--success,#004f3e);border-color:color-mix(in oklab,var(--success,#004f3e) 30%,var(--hairline,rgba(18,26,34,.13)));background:var(--success-surface,#eefaf5)}',
'.rw-tag[data-s=run] i{background:var(--success,#004f3e)}',
'.rw-tag[data-s=stop]{color:var(--danger,#8d1925);border-color:color-mix(in oklab,var(--danger,#8d1925) 30%,var(--hairline,rgba(18,26,34,.13)));background:var(--danger-surface,#fdeef0)}',
'.rw-tag[data-s=stop] i{background:var(--danger,#8d1925)}',
'.rw-hero{display:flex;align-items:center;justify-content:space-between;gap:28px;flex-wrap:wrap;background:var(--surface,#fff);border:1px solid var(--hairline,rgba(18,26,34,.13));border-radius:calc(var(--radius-base,.5rem)*2);box-shadow:var(--app-shadow-md,0 4px 16px rgba(0,0,0,.08));padding:24px 26px}',
'.rw-hero-info{flex:1 1 20rem;min-width:min(100%,24ch)}',
'.rw-hero h2{font-size:16.5px;font-weight:700;letter-spacing:-.015em;margin:0}',
'.rw-desc{font-size:13.5px;color:var(--text-muted,#5f666d);margin:8px 0 0;line-height:1.65;max-width:52ch}',
'.rw-ctl{display:flex;align-items:center;gap:14px;flex-shrink:0}',
'.rw-ctl-txt{text-align:right;min-width:8.5em}',
'.rw-ctl-txt b{display:block;font-size:13.5px;font-weight:700}',
'.rw-ctl-txt span{display:block;font-size:12px;color:var(--text-muted,#5f666d);margin-top:2px}',
/* 开关一律使用 LuCI 标准组件 ui.Checkbox（生成 .cbi-checkbox），
   外观由主题决定 —— 不自定义控件样式，避免与主题冲突。
   此处仅调整其在卡片内的对齐。 */
'.rw-sw{display:flex;align-items:center;gap:12px}',
'.rw-sw .cbi-checkbox{margin:0}',
/* 频率档位：LuCI 标准按钮（.btn / .cbi-button-action），不自定义外观，
   仅约束最小宽度让两个档位等宽、换行时可读。 */
'.rw-modes{display:flex;flex-wrap:wrap;gap:10px}',
'.rw-modes .btn{min-width:8em}',
'.rw-chart{background:var(--surface,#fff);border:1px solid var(--hairline,rgba(18,26,34,.13));border-radius:calc(var(--radius-base,.5rem)*2);box-shadow:var(--app-shadow-md,0 4px 16px rgba(0,0,0,.08));padding:20px 24px 14px;margin-top:20px}',
'.rw-ch-head{display:flex;align-items:flex-start;justify-content:space-between;gap:18px;flex-wrap:wrap}',
'.rw-ch-head h2{font-size:11.5px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:var(--text-subtle,#7f858b);margin:0}',
'.rw-ch-val{display:flex;align-items:baseline;gap:6px;margin-top:7px}',
'.rw-ch-val b{font-family:var(--font-mono,monospace);font-size:34px;font-weight:500;letter-spacing:-.045em;line-height:1}',
'.rw-ch-val u{text-decoration:none;font-size:15px;color:var(--text-muted,#5f666d);font-weight:600}',
'.rw-ch-val span{font-size:12px;color:var(--text-subtle,#7f858b);margin-left:5px}',
'.rw-seg{display:inline-flex;padding:3px;gap:2px;border:1px solid var(--hairline,rgba(18,26,34,.13));border-radius:calc(var(--radius-base,.5rem)*.875);background:var(--surface-sunken,#f4f7fa)}',
'.rw-seg button{font:inherit;font-size:12.5px;font-weight:600;padding:6px 13px;border:0;cursor:pointer;background:transparent;color:var(--text-muted,#5f666d);border-radius:calc(var(--radius-base,.5rem)*.625);transition:.14s}',
'.rw-seg button:hover{color:var(--text,#121a22)}',
'.rw-seg button[aria-selected=true]{background:var(--surface,#fff);color:var(--brand,#0085b5);box-shadow:var(--app-shadow-sm,0 1px 3px rgba(0,0,0,.06))}',
'.rw-wrap{position:relative;margin-top:14px}',
'.rw-svg{display:block;width:100%;height:238px;overflow:visible}',
'.rw-tip{position:absolute;top:0;left:0;pointer-events:none;opacity:0;transition:opacity .12s;background:var(--surface,#fff);border:1px solid var(--hairline,rgba(18,26,34,.13));border-radius:var(--radius-base,.5rem);box-shadow:var(--app-shadow-md,0 4px 16px rgba(0,0,0,.08));padding:8px 11px;white-space:nowrap;z-index:3}',
'.rw-tip.on{opacity:1}',
'.rw-tip-t{display:block;font-family:var(--font-mono,monospace);font-size:10.5px;color:var(--text-subtle,#7f858b)}',
'.rw-tip-v{display:block;font-family:var(--font-mono,monospace);font-size:15px;font-weight:600;margin-top:3px}',
'.rw-ch-foot{display:flex;justify-content:space-between;gap:14px;flex-wrap:wrap;margin-top:12px;padding-top:11px;border-top:1px solid var(--hairline,rgba(18,26,34,.13));font-family:var(--font-mono,monospace);font-size:11px;color:var(--text-subtle,#7f858b)}',
'.rw-kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:16px;margin-top:20px}',
'.rw-kpi{background:var(--surface,#fff);border:1px solid var(--hairline,rgba(18,26,34,.13));border-radius:calc(var(--radius-base,.5rem)*1.5);box-shadow:var(--app-shadow-sm,0 1px 3px rgba(0,0,0,.06));padding:18px 20px}',
'.rw-kpi em{display:block;font-style:normal;font-size:11.5px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:var(--text-subtle,#7f858b);margin-bottom:10px}',
'.rw-v{font-family:var(--font-mono,monospace);font-size:23px;font-weight:500;letter-spacing:-.03em;display:flex;align-items:baseline;gap:3px}',
'.rw-v u{text-decoration:none;font-size:12.5px;color:var(--text-muted,#5f666d);font-weight:400}',
'.rw-kpi.rw-row{display:flex;align-items:center;justify-content:space-between;gap:14px}',
'.rw-kpi.rw-row em{margin-bottom:0}',
'.rw-mini{display:flex;align-items:center;gap:11px}',
'.rw-lb{font-size:12.5px;font-weight:600;color:var(--text-muted,#5f666d)}',
'.rw-note{margin-top:20px;font-size:12.5px;color:var(--text-subtle,#7f858b);line-height:1.75;max-width:80ch}',
'.rw-empty{font-size:12.5px;color:var(--text-subtle,#7f858b);padding:28px 0;text-align:center}',
'@media(max-width:720px){.rw-hero{flex-direction:column;align-items:stretch}.rw-ctl{justify-content:space-between}.rw-ctl-txt{text-align:left}}'
].join('\n');

return view.extend({
	load: function () {
		return readStatus('2h');
	},

	render: function (st) {
		var self = this;
		this.st = st || { load: {} };
		this.range = '2h';
		this.parseHist(this.st);

		/* ── 页头 ── */
		this.tagDot = E('i');
		this.tagTxt = E('span');
		this.tagEl = E('span', { 'class': 'rw-tag' }, [ this.tagDot, this.tagTxt ]);
		var header = E('div', { 'class': 'rw-hd' }, [
			E('div', {}, [
				E('h1', {}, _('NSS 硬件加速')),
				E('p', {}, _('直连流量由 NSS 引擎硬件转发；代理流量交由 dae 内核态接管'))
			]),
			this.tagEl
		]);

		/* ── 主控卡：硬件加速开关 ──
		   开关一律用 LuCI 标准组件 ui.Checkbox（渲染 .cbi-checkbox），
		   外观交给主题，不自造控件。 */
		this.cbRun = new ui.Checkbox('1', { 'id': 'rw-cb-run' });
		var runNode = this.cbRun.render();
		runNode.addEventListener('widget-change', L.bind(function () { this.toggleRun(); }, this));
		this.lbRun = E('span');
		this.descEl = E('p', { 'class': 'rw-desc' });
		var hero = E('section', { 'class': 'rw-hero' }, [
			E('div', { 'class': 'rw-hero-info' }, [ E('h2', {}, _('引擎控制')), this.descEl ]),
			E('div', { 'class': 'rw-ctl' }, [
				E('span', { 'class': 'rw-ctl-txt' }, [ E('b', {}, _('硬件加速')), this.lbRun ]),
				E('div', { 'class': 'rw-sw' }, [ runNode ])
			])
		]);

		/* ── 图表卡 ── */
		this.segEl = E('div', { 'class': 'rw-seg' });
		/* ★ 不用 ui.createHandlerFn(fn) 包匿名函数：该工厂内部依赖
		   `arguments[args.length].currentTarget`（见 luci-base 的 ui.js），
		   传匿名函数时不接收事件参数 → currentTarget 为 undefined →
		   读 .classList 抛 TypeError，点击完全无反应（实测反馈"页面功能要修"）。
		   官方全部用法都是 createHandlerFn(self, '方法名', ...参数)，靠方法签名
		   接住事件；这里改用普通函数，结构最简单也最稳。
		   顺带自带"正在处理"状态（禁用 + 转圈），等价于原工厂的附加行为。 */
		Object.keys(RANGES).forEach(function (r) {
			self.segEl.appendChild(E('button', {
				'data-range': r,
				'aria-selected': (r === '2h') ? 'true' : 'false',
				'click': function (ev) {
					var btn = ev.currentTarget;
					if (btn.disabled) return;
					btn.disabled = true;
					btn.classList.add('spinning');
					Promise.resolve(self.setRange(r)).finally(function () {
						btn.classList.remove('spinning');
						btn.disabled = false;
					});
				}
			}, _(RANGES[r])));
		});

		this.svg = sx('svg', { 'viewBox': '0 0 940 238', 'preserveAspectRatio': 'none', 'class': 'rw-svg' });
		this.tipT = E('span', { 'class': 'rw-tip-t' });
		this.tipV = E('span', { 'class': 'rw-tip-v' });
		this.tip = E('div', { 'class': 'rw-tip' }, [ this.tipT, this.tipV ]);
		this.wrap = E('div', { 'class': 'rw-wrap' }, [ this.svg, this.tip ]);

		this.nowEl = E('b', {}, '—');
		this.nowLbl = E('span', {}, _('当前'));
		this.footEl = E('span');
		var chart = E('section', { 'class': 'rw-chart' }, [
			E('div', { 'class': 'rw-ch-head' }, [
				E('div', {}, [
					E('h2', {}, _('NSS 核心负载')),
					E('div', { 'class': 'rw-ch-val' }, [ this.nowEl, E('u', {}, '%'), this.nowLbl ])
				]),
				this.segEl
			]),
			this.wrap,
			E('div', { 'class': 'rw-ch-foot' }, [ this.footEl, E('span', {}, _('RRD 历史 · tmpfs')) ])
		]);

		/* ── KPI：频率档位 / 频率 / 开机自启 ──
		   不用「调频模式(Auto/Fixed)」：上游 qca-nss-pbuf 的
		   apply_nss_config() 开机把 dev.nss.clock.auto_scale 固定写 0
		   （锁频），这是其 pbuf/N2H offload profile 的前提，本页不该
		   反着改它。故只提供上游 nss_freq 支持的两个锁频档。 */
		this.freqEl = E('span', {}, '—');

		/* 频率档位按钮：走上游 /usr/bin/nss_freq（写 proc + 存 UCI，重启仍生效）。
		   mid = 748.8MHz（上游默认）／ high = 1497.6MHz。
		   用 LuCI 标准按钮（官方 startup.js 同款写法）：普通档 'btn'，
		   当前档追加 'cbi-button-action' 高亮。
		   不用 [disabled] 标当前档 —— 主题给 [disabled] 加了 opacity，
		   看起来像失效而不是选中。 */
		this.modeBtn = {};
		this.modeEl = E('div', { 'class': 'rw-modes' });
		[ [ 'mid', '748.8 MHz' ], [ 'high', '1497.6 MHz' ] ].forEach(function (m) {
			var btn = E('button', {
				'type': 'button',
				'class': 'btn',
				/* 同时间范围按钮：用普通函数而非 ui.createHandlerFn（理由见上方注释） */
				'click': function (ev) {
					var b = ev.currentTarget;
					if (b.disabled) return;
					b.disabled = true;
					b.classList.add('spinning');
					Promise.resolve(self.setLevel(m[0])).finally(function () {
						b.classList.remove('spinning');
						b.disabled = false;
					});
				}
			}, _(m[1]));
			self.modeBtn[m[0]] = btn;
			self.modeEl.appendChild(btn);
		});

		this.cbAuto = new ui.Checkbox('1', { 'id': 'rw-cb-auto' });
		var autoNode = this.cbAuto.render();
		autoNode.addEventListener('widget-change', L.bind(function () { this.toggleAuto(); }, this));
		this.lbAuto = E('span', { 'class': 'rw-lb' });

		/* 加速连接数：ECM 经 NSS 加速的连接条数（debugfs 计数器）。
		   这是判断"NSS 到底有没有在干活"最直接的指标 —— 负载百分比在
		   低流量时可能长时间贴 0，而连接数一旦有流量就会上去。
		   ECM 未加载时取不到值，显示 "—"（不是 0）。 */
		this.connEl = E('b', {}, '—');

		var kpis = E('section', { 'class': 'rw-kpis' }, [
			E('div', { 'class': 'rw-kpi' }, [ E('em', {}, _('频率档位')), this.modeEl ]),
			E('div', { 'class': 'rw-kpi' }, [ E('em', {}, _('NSS 频率')),
				E('div', { 'class': 'rw-v' }, [ this.freqEl, E('u', {}, 'MHz') ]) ]),
			E('div', { 'class': 'rw-kpi' }, [ E('em', {}, _('加速连接数')),
				E('div', { 'class': 'rw-v' }, [ this.connEl, E('u', {}, _('条')) ]) ]),
			E('div', { 'class': 'rw-kpi rw-row' }, [ E('em', {}, _('开机自启')),
				E('div', { 'class': 'rw-sw' }, [ this.lbAuto, autoNode ]) ])
		]);

		var note = E('p', { 'class': 'rw-note' }, _('上图为 NSS 引擎的核心负载（%），不是流量速率：空闲时贴近 0 属正常，有大流量经过加速路径时才会抬升。要确认加速是否在工作，看「加速连接数」更直接。停用 NSS 后直连流量回退内核软转发，bandix 的统计会变准确（NSS 加速的流量不计入其统计），但吞吐下降。防火墙页的「路由 / NAT 卸载」请保持「无」——NSS 独立工作，软件卸载会与之冲突。'));

		this.apply();
		this.draw();
		this.bindHover();

		poll.add(L.bind(function () { return this.refresh(); }, this), 5);

		return E('div', { 'class': 'rw-root' }, [ E('style', {}, CSS), header, hero, chart, kpis, note ]);
	},

	parseHist: function (st) {
		this.hist = [];
		if (!st || !st.hist) return;
		/* 按最后一个冒号切分：rrdtool 的 "<ts>: <val>" 与任何多余分隔符都能容错 */
		st.hist.split(',').forEach(L.bind(function (seg) {
			var i = seg.lastIndexOf(':');
			if (i < 1) return;
			var t = parseInt(seg.substring(0, i), 10);
			var v = parseFloat(seg.substring(i + 1));
			if (isFinite(t) && isFinite(v))
				this.hist.push({ t: t, v: Math.max(0, Math.min(100, v)) });
		}, this));
	},

	live: function () {
		var k = Object.keys(this.st.load || {});
		return k.length ? parseFloat(this.st.load[k[0]]) : null;
	},

	/* 状态 → UI */
	apply: function () {
		var st = this.st, on = (st.ecm === 'running'), auto = (st.autostart === '1');

		this.tagEl.setAttribute('data-s', on ? 'run' : 'stop');
		this.tagTxt.textContent = on ? _('运行中') : _('已停用');

		this.cbRun.setValue(on ? '1' : '0');
		this.lbRun.textContent = on ? _('已启用') : _('已停用');
		this.descEl.textContent = on
			? _('当前由硬件加速转发。停用后流量回退内核软转发，bandix 流量统计会变得更准确，但吞吐下降。')
			: _('当前为内核软转发。bandix 统计准确，但吞吐低于硬件加速路径。启用后直连流量将由 NSS 接管。');

		/* 频率档位高亮：当前档加 cbi-button-action（另见 render 注释：
		   不用 [disabled]，主题会给它加 opacity，看着像失效）。
		   用 classList.toggle 而非整体重写 className —— 后者会把主题
		   或 LuCI 后续可能附加的类一并抹掉。 */
		var cur = (st.freqlevel === 'high') ? 'high' : 'mid';
		var self = this;
		Object.keys(this.modeBtn).forEach(function (k) {
			self.modeBtn[k].classList.toggle('cbi-button-action', k === cur);
		});

		this.cbAuto.setValue(auto ? '1' : '0');
		this.lbAuto.textContent = auto ? _('已启用') : _('已关闭');

		this.freqEl.textContent = st.freq || '—';

		/* 连接数取不到（ECM 未加载）时显示 "—"：显示 0 会被误读为
		   "加速正常但没有连接"，而实情可能是加速根本没在跑。 */
		this.connEl.textContent = (st.conns === undefined || st.conns === '') ? '—' : st.conns;

		var lv = this.live();
		this.nowEl.textContent = (lv === null) ? '—' : lv.toFixed(1);
	},

	/* 画主图。
	   ★ 分两层：draw() 负责清空 svg 并【重建后补挂悬停层】，drawPlot() 只
	     负责画图。原因：bindHover() 创建的准星(cross)与圆点(dot)也是 svg
	     的子节点，若 draw() 清空后不补挂，首次轮询（5 秒）一过它们就从
	     DOM 里消失 —— 悬停十字线永远不会再出现，且不报任何错（实测
	     svg 子节点 27 → 25）。 */
	draw: function () {
		var svg = this.svg;
		while (svg.firstChild) svg.removeChild(svg.firstChild);
		this.drawPlot(svg);
		if (this.cross) svg.appendChild(this.cross);
		if (this.dot) svg.appendChild(this.dot);
	},

	drawPlot: function (svg) {
		var W = 940, H = 238, L = 44, R = 14, T = 14, B = 30;

		var h = this.hist, n = h.length;
		this.geom = { W: W, H: H, L: L, R: R, T: T, B: B, n: n, t0: n ? h[0].t : 0, t1: n ? h[n - 1].t : 0 };
		if (!n) {
			var t0 = sx('text', { x: W / 2, y: H / 2, 'text-anchor': 'middle',
				'font-size': '13', fill: 'var(--text-subtle,#7f858b)' });
			/* 区分三种"没数据"：读取失败 / 根本采不到 / 还没采到。
			   否则 debugfs 未就绪时页面会一直说"等待约 30 秒"，
			   把故障说成正常等待。 */
			t0.textContent = (this.st.stats === 'error')
				? _('读取 NSS 状态失败（详见页面通知）')
				: (this.st.stats === 'unavailable')
					? _('NSS 统计不可用：debugfs 无 cpu_load_ubi（驱动未就绪或未加载）')
					: _('暂无历史数据（首次采集需等待约 30 秒）');
			svg.appendChild(t0);
			this.footEl.textContent = '';
			return;
		}
		var denom = Math.max(n - 1, 1);
		var xOf = this.geom.xOf = function (i) { return L + (W - L - R) * i / denom; };
		var yOf = this.geom.yOf = function (v) { return T + (H - T - B) * (1 - v / 100); };

		/* Y 轴网格 + 刻度 */
		[0, 25, 50, 75, 100].forEach(function (v) {
			var y = yOf(v);
			svg.appendChild(sx('line', { x1: L, x2: W - R, y1: y, y2: y,
				stroke: 'var(--hairline,rgba(18,26,34,.13))', 'stroke-width': 1,
				'stroke-dasharray': v === 0 ? '0' : '1 3' }));
			var t = sx('text', { x: L - 10, y: y + 3.5, 'text-anchor': 'end',
				'font-family': 'var(--font-mono,monospace)', 'font-size': '10.5',
				fill: 'var(--text-subtle,#7f858b)' });
			t.textContent = v;
			svg.appendChild(t);
		});

		/* 时间轴（5 刻度）。n<2 时不画：idx 恒为 0，5 个标签会叠在同一 x。 */
		for (var i = 0; n >= 2 && i < 5; i++) {
			var frac = i / 4, idx = Math.round(frac * (n - 1));
			var x = xOf(idx);
			svg.appendChild(sx('line', { x1: x, x2: x, y1: T, y2: H - B,
				stroke: 'var(--hairline,rgba(18,26,34,.13))', 'stroke-width': 1,
				'stroke-dasharray': '1 3', 'stroke-opacity': .7 }));
			var lt = sx('text', { x: x, y: H - B + 16,
				'text-anchor': frac < .05 ? 'start' : frac > .95 ? 'end' : 'middle',
				'font-family': 'var(--font-mono,monospace)', 'font-size': '10.5',
				fill: 'var(--text-subtle,#7f858b)' });
			lt.textContent = fmtTime(h[idx].t, this.range);
			svg.appendChild(lt);
		}

		/* 单点：monotone() 在 n<2 时返回空串，会让面积路径退化成
		   " LNaN,… LNaN,… Z" 这类非法坐标（实测），整条曲线画不出来。
		   此时改画一个点 + 数值，位置取绘图区水平居中。 */
		if (n < 2) {
			var cx0 = (L + W - R) / 2, cy0 = yOf(h[0].v);
			svg.appendChild(sx('circle', { cx: cx0, cy: cy0, r: 4.5, fill: 'var(--brand,#0085b5)' }));
			var lbl0 = sx('text', { x: cx0, y: cy0 - 12, 'text-anchor': 'middle',
				'font-family': 'var(--font-mono,monospace)', 'font-size': '12',
				fill: 'var(--brand,#0085b5)' });
			lbl0.textContent = h[0].v.toFixed(1) + ' %';
			svg.appendChild(lbl0);
			this.footEl.textContent = _('仅 1 个采样点 · %s').format(_(LABEL[this.range] || ''));
			return;
		}

		/* 渐变面积 */
		var defs = sx('defs');
		var gid = 'rwg';
		var lg = sx('linearGradient', { id: gid, x1: 0, y1: 0, x2: 0, y2: 1 });
		var off = (this.st.ecm !== 'running');
		lg.appendChild(sx('stop', { offset: '0%', 'stop-color': 'var(--brand,#0085b5)', 'stop-opacity': off ? '.10' : '.32' }));
		lg.appendChild(sx('stop', { offset: '65%', 'stop-color': 'var(--brand,#0085b5)', 'stop-opacity': off ? '.04' : '.10' }));
		lg.appendChild(sx('stop', { offset: '100%', 'stop-color': 'var(--brand,#0085b5)', 'stop-opacity': '0' }));
		defs.appendChild(lg);
		svg.appendChild(defs);

		var xs = h.map(function (_, k) { return xOf(k); });
		var ys = h.map(function (d) { return yOf(d.v); });
		var dline = monotone(xs, ys);
		svg.appendChild(sx('path', { d: dline + ' L' + xOf(n - 1) + ',' + (H - B) + ' L' + xOf(0) + ',' + (H - B) + ' Z', fill: 'url(#' + gid + ')' }));
		svg.appendChild(sx('path', { d: dline, fill: 'none', stroke: 'var(--brand,#0085b5)',
			'stroke-width': 2.3, 'stroke-linejoin': 'round', 'stroke-linecap': 'round',
			'stroke-opacity': off ? '.42' : '1' }));

		/* 端点 */
		svg.appendChild(sx('circle', { cx: xOf(n - 1), cy: ys[n - 1], r: 8,
			fill: 'var(--brand,#0085b5)', 'fill-opacity': .18 }));
		svg.appendChild(sx('circle', { cx: xOf(n - 1), cy: ys[n - 1], r: 3.6,
			fill: 'var(--brand,#0085b5)' }));

		/* 页脚统计 */
		var sum = 0, mx = -Infinity, mn = Infinity;
		h.forEach(function (d) { sum += d.v; if (d.v > mx) mx = d.v; if (d.v < mn) mn = d.v; });
		this.footEl.textContent = _('均 %s%% · 峰 %s%% · 谷 %s%%').format((sum / n).toFixed(1), mx.toFixed(0), mn.toFixed(0))
			+ ' · ' + _(LABEL[this.range] || '');
	},

	/* 悬浮读数。
	   cross/dot 挂在 this 上：draw() 每次重建 svg 后会按引用补挂回去，
	   否则首次轮询(5s)一过悬停准星就消失。 */
	bindHover: function () {
		var self = this, wrap = this.wrap, svg = this.svg;
		var cross = this.cross = sx('line', { y1: 0, y2: 0, stroke: 'var(--brand,#0085b5)', 'stroke-width': 1,
			'stroke-dasharray': '3 3', 'stroke-opacity': .55, visibility: 'hidden' });
		var dot = this.dot = sx('circle', { r: 4, fill: 'var(--brand,#0085b5)', stroke: 'var(--surface,#fff)',
			'stroke-width': 2, visibility: 'hidden' });
		svg.appendChild(cross);
		svg.appendChild(dot);

		function clear() {
			self.tip.classList.remove('on');
			cross.setAttribute('visibility', 'hidden');
			dot.setAttribute('visibility', 'hidden');
		}

		wrap.addEventListener('mousemove', function (ev) {
			var g = self.geom;
			if (!g || !g.n) return;
			var r = svg.getBoundingClientRect();
			var px = (ev.clientX - r.left) / r.width * g.W;
			var frac = (px - g.L) / (g.W - g.L - g.R);
			var i = Math.max(0, Math.min(g.n - 1, Math.round(frac * (g.n - 1))));
			var d = self.hist[i];
			var x = g.xOf(i), y = g.yOf(d.v);
			cross.setAttribute('x1', x); cross.setAttribute('x2', x);
			cross.setAttribute('y1', g.T); cross.setAttribute('y2', g.H - g.B);
			cross.setAttribute('visibility', 'visible');
			dot.setAttribute('cx', x); dot.setAttribute('cy', y);
			dot.setAttribute('visibility', 'visible');
			self.tipT.textContent = fmtTime(d.t, self.range);
			self.tipV.textContent = d.v.toFixed(1) + ' %';
			var left = Math.min(Math.max(px / g.W * r.width - 52, 4), r.width - 116);
			self.tip.style.left = left + 'px';
			self.tip.style.top = Math.max(y / g.H * r.height - 62, 2) + 'px';
			self.tip.classList.add('on');
		});
		wrap.addEventListener('mouseleave', clear);
	},

	/* 切时间范围 */
	setRange: function (r) {
		var self = this;
		if (r === this.range) return;
		this.range = r;
		Array.prototype.forEach.call(this.segEl.children, function (b) {
			b.setAttribute('aria-selected', b.getAttribute('data-range') === r ? 'true' : 'false');
		});
		return readStatus(r).then(function (st) {
			self.st = st;
			self.parseHist(st);
			self.apply();
			self.draw();
		}).catch(function (err) {
			notifyError(_('读取历史数据失败：%s').format(err && err.message ? err.message : err));
		});
	},

	/* 开关动作 */
	/* 硬件加速 / 开机自启由 ui.Checkbox 的 widget-change 触发 —— 此时控件
	   已切换，故依据【控件新值】决定要执行的动作（而非旧状态），避免状态
	   不同步。频率档位用的是按钮，直接把目标档位传进来。 */
	toggleRun: function () {
		var self = this;
		return control(this.cbRun.isChecked() ? 'start' : 'stop')
			.then(function () { return self.refresh(); });
	},
	toggleAuto: function () {
		var self = this;
		return control(this.cbAuto.isChecked() ? 'enable' : 'disable')
			.then(function () { return self.refresh(); });
	},
	/* 频率档位：走上游 /usr/bin/nss_freq（写 proc 并保存 UCI，重启保持）。
	   mid = 748.8MHz（上游默认）／ high = 1497.6MHz。 */
	setLevel: function (lv) {
		var self = this;
		if (lv !== 'mid' && lv !== 'high')
			return Promise.resolve();
		/* 已是该档则不动：避免重复写 proc，也省一次无意义的 nss_freq 调用 */
		if (((this.st.freqlevel === 'high') ? 'high' : 'mid') === lv)
			return Promise.resolve();

		return callExec('/usr/bin/nss_freq', [ lv ]).then(function (res) {
			if (!res || res.code !== 0) {
				var detail = (res && res.stderr ? String(res.stderr).trim() : '') || _('无输出');
				notifyError(_('切换频率档位失败（退出码 %s）：%s').format(
					(res && res.code !== undefined) ? res.code : '?', detail));
			}
			return self.refresh();
		}).catch(function (err) {
			notifyError(_('切换频率档位出错：%s').format(err && err.message ? err.message : err));
		});
	},

	refresh: function () {
		var self = this;
		return readStatus(this.range).then(function (st) {
			self.st = st;
			self.parseHist(st);
			self.apply();
			self.draw();
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
EOF

cat > $PKGDIR/root/usr/libexec/rivwrt/nss-status <<'EOF'
#!/bin/sh
# RivWRT NSS 状态采集：输出 key=value 供 LuCI 页面解析
# 用法：nss-status [range]   range ∈ 2h|12h|1d|1w（默认 2h，仅影响 history 段）
# 输出字段与页面消费点一一对应：ecm / autostart / freq / freqlevel / stats /
# load_<n> / hist。不输出页面不读的字段（此前多输出 ts、freqmode、histrange，
# 属死代码：freqmode 恒为 Fixed——上游 qca-nss-pbuf 开机就把 auto_scale 锁 0，
# 页面也已不再展示 Auto/Fixed）。

# ── 引擎运行状态 ──
# ECM 是内核模块：其 init.d 的 start_service() 只做 modprobe、未 procd_open_service，
# 故不出现在 ubus service list。曾用 ubus 检测 → 恒判 stopped、按钮看似无效。
# 用 /proc/modules 而非 lsmod：lsmod 是 busybox applet，若未编译则该命令不存在，
# 会导致恒判为 stopped（页面永远显示"已停用"，看似"按钮无效"）。
# /proc/modules 由内核提供，始终可用。
if grep -q '^ecm ' /proc/modules 2>/dev/null; then
	echo "ecm=running"
else
	echo "ecm=stopped"
fi

# ── 开机自启 ──
# ★ 不能取 ubus rc.list 的 enabled 字段：rc.c 的 rc_list_readdir() 解析
#   init 脚本时只读前 11 行（count <= 10 上限），而 qca-nss-ecm.init 有
#   16 行版权头，START=26 落在第 18 行 → rc.list 恒报 enabled=false
#   （LuCI 官方「系统→启动项」页对同一脚本同样误报）。实测模拟该脚本
#   在 rc.list 下的解析结果：start=-1，即永远走不到 enabled 判定。
# ★ 也不 fork 执行 "/etc/init.d/qca-nss-ecm enabled"：rc.common 会加载
#   functions.sh + service.sh 并 source 整个 175 行脚本，而本脚本由页面
#   每 5 秒轮询一次，长期看不划算。
# ★ rc.common 的 enabled() 判定本质就是"START 对应的 /etc/rc.d/S<START><name>
#   符号链接是否存在"。此处直接 glob 该链接（?? 匹配任意两位编号，
#   不写死 26），语义与官方一致，且零 fork。
AUTOSTART=0
for f in /etc/rc.d/S??qca-nss-ecm; do
	[ -L "$f" ] && { AUTOSTART=1; break; }
done
echo "autostart=$AUTOSTART"

# ── NSS 时钟（路径同上游 nss_diag）──
FREQ=$(cat /proc/sys/dev/nss/clock/current_freq 2>/dev/null)
case "$FREQ" in
	''|*[!0-9]*) : ;;
	*) echo "freq=$(awk -v h="$FREQ" 'BEGIN{printf "%.1f", h/1000000}')" ;;
esac

# ── 频率档位（上游 nss_freq 能力：mid=748.8MHz / high=1497.6MHz）──
# 上游把档位存在 UCI nss_freq.settings.level，由 /etc/init.d/nss_freq 开机应用。
echo "freqlevel=$(uci -q get nss_freq.settings.level || echo mid)"

# ── 实时负载（debugfs cpu_load_ubi）──
# 按 "Core N:" 定位，在紧随的百分比行取 $2 = Avg 列
# （非行内首个百分比那列 = Min；也不像上游 sbin/cpuusage 那样
#   硬编码 "NR==6"，避免行数变化时取空）。
D=/sys/kernel/debug/qca-nss-drv/stats
# 用「统计文件是否可读」判断，而不是 `mountpoint -q /sys/kernel/debug` ——
# busybox 的 MOUNTPOINT 默认不编译（BUSYBOX_DEFAULT_MOUNTPOINT=n），设备上
# 没有这个命令，会往 stderr 吐 "mountpoint: not found"（实测）。
# 而且这里真正关心的是"能不能读那个文件"，不是"debugfs 挂没挂"。
# 已挂载时再 mount 会返回 EBUSY，被 2>/dev/null 吞掉，无副作用。
[ -r "$D/cpu_load_ubi" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
if [ -r "$D/cpu_load_ubi" ]; then
	echo "stats=ok"
	awk '
		/^Core [0-9]+:/ { core = $2; sub(":", "", core); has = 1; next }
		has && /%/ { gsub("%", "", $2); print "load_" core "=" $2; has = 0 }
	' "$D/cpu_load_ubi"
else
	echo "stats=unavailable"
fi

# ── NSS 加速连接数 ──
# ECM 在 /sys/kernel/debug/ecm/ecm_db/ 下提供两个同源计数器，均由
# ecm_db_connection_init() 创建，读的都是【当前】连接数快照
# （ecm_db_connection_count，在 ecm_db_lock 下取），不是累计值：
#     connection_count        —— u32，按 debugfs u32 语义读出为纯数字
#     connection_count_simple —— 文本 "tcp X udp Y other Z total W"
#   （源码 ecm_db/ecm_db_connection.c：后者由
#    snprintf("tcp %d udp %d other %d total %d\n", ...) 生成）
# 该 init 中任一 create 失败即返回 false → ecm_db 初始化失败 → ECM 整体
# 不可用；故 ECM 一旦在跑（/proc/modules 有 ecm），这两文件必然存在。
# 优先取前者免解析；若其内容不是纯数字，再从后者析出 total。两步都过数字
# 校验，避免因格式差异让页面永远显示 "—"。
#   ★ 这里踩过一次：先前只读 connection_count_simple 且按"纯数字"校验，
#     而它实际是带标签的文本，case 校验必然拒绝 → conns 永不输出、页面恒 "—"。
# ECM 未加载时两节点都不存在 → 不输出，页面显示 "—" 而非 0，以免把
# "加速没在工作"误显示成"当前没有连接"。
# 本脚本由 rpcd 以 root 执行，且这两文件本身即 S_IRUGO，权限无忧。
C=$(cat /sys/kernel/debug/ecm/ecm_db/connection_count 2>/dev/null)
case "$C" in
	''|*[!0-9]*)
		C=$(awk '{ for (i = 1; i < NF; i++) if ($i == "total") { print $(i + 1); exit } }' \
			/sys/kernel/debug/ecm/ecm_db/connection_count_simple 2>/dev/null) ;;
esac
case "$C" in
	''|*[!0-9]*) : ;;
	*) echo "conns=$C" ;;
esac

# ── 历史序列（RRD；需 rrdtool1 包）──
RANGE="${1:-2h}"
case "$RANGE" in
	12h) SPAN=43200 ;;
	1d)  SPAN=86400 ;;
	1w)  SPAN=604800 ;;
	*)   SPAN=7200 ;;
esac
RRD=$(ls /tmp/rrd/*/nss-load/gauge-core0.rrd 2>/dev/null | head -1)
if [ -n "$RRD" ] && [ -x /usr/bin/rrdtool ]; then
	# rrdtool fetch 输出为 "<时间戳>: <值>"（$1 自带尾冒号）；必须去掉，
	# 否则拼出 "ts::v" 双冒号，前端 split(':') 得 3 段而整体丢弃（实测
	# 历史点解析数恒为 0 → 图表永空）。-nan（无数据）被正则排除。
	H=$(/usr/bin/rrdtool fetch "$RRD" AVERAGE -s "NOW-$SPAN" -e NOW 2>/dev/null | \
		awk '/^[0-9]+:/ { t = $1; sub(/:$/, "", t); v = $2; if (v ~ /^[0-9.eE+-]+$/) printf "%s:%.1f,", t, v }')
	[ -n "$H" ] && echo "hist=${H%,}"
fi
exit 0
EOF
chmod +x $PKGDIR/root/usr/libexec/rivwrt/nss-status

# -------------------------------------------------------
# RivWRT：无线三频固化 init.d 脚本
# 生成到 base-files 的 init.d + rc.d 链接（固件层启用，首启自动执行一次）
# 硬件拓扑：radio0(5G ahb) / radio1(2.4G ahb) / radio2(QCN9074 PCIe 5G)
# 频段分配：radio0=5G-1 游戏(44/HE160)、radio1=2.4G(11/HT20)、radio2=5G-2 影音(149/HE80)
# 法规：US / 24dBm（ones20250 推荐）
# -------------------------------------------------------

mkdir -p "./package/base-files/files/etc/init.d" "./package/base-files/files/etc/rc.d"
WIFI_INIT="./package/base-files/files/etc/init.d/rivwrt-wifi"
cat > "$WIFI_INIT" <<'RIVWRT_WIFI'
#!/bin/sh /etc/rc.common
# RivWRT 无线兜底：参数比对 + 失效 radio 的【串行】重启 + 兜底重启一次
#
# ── 参数比对 ──
# 编译期已在 mac80211.uc 注入 ssid/channel/htmode/country/txpower/encryption，
# 全新刷机（sysupgrade -n）时比对后无改动、不触发任何重启。
# 价值在【保留旧配置升级】：旧固件可能残留 SSID=OWRT、加密 psk2、
# 或非法 htmode（曾误写 HT160 —— 不在合法枚举内，致 5G radio 起不来）。
#
# ★ 刻意不设置 country：ath11k 对运行时国家码热切换脆弱，实测触发
#   cfg80211 WARNING (net/wireless/reg.c:4035 reg_get_max_bandwidth)
#   与 ath11k_pci: failed to perform regd update : -22。
#
# ── 失效 radio 的串行重启 ──
# 实测现象：全新刷机后 2.4G 正常、两个 5G 起不来；重启一次即恢复。
# 根因：ath11k 的 phy 级 regd 更新走 workqueue，且【三个 radio 并发启动】时
# 相互竞争，部分 phy 更新失败（日志实证 hostapd: Frequency 5180/5745 is not
# allowed —— 即该 phy 的 regd 未生效、落到最严格域），对应 radio 起不来。
#
# ★ 关键：不可用 `wifi reload` 去"重试"—— 读 /sbin/wifi 源码可知
#   wifi_reload() 忽略设备参数，执行的是 `ubus call network reload`（全量），
#   会把三个 radio 一起重启，再次制造三路并发竞争（反而加剧问题）。
#   必须用 `ubus call network.wireless {down,up} {"device":"radioN"}` 逐个来。
START=99
# ★ marker 名带版本号，本身就是"迁移版本"：每次改动无线固化逻辑就 bump 一次，
#   让已刷机的设备在下次启动时重跑一遍（否则旧的 marker 会让新逻辑永不执行）。
#   v1 → v2：补上 disabled 清理（见 start() 第 0 步）。
#   v2 → v3：就绪判定从 radio 状态改为 AP 接口实际状态（wifi isup 会误判成功，
#            导致 5G 起不来时脚本毫无动作 —— 真机实测确认）。
MARKER=/etc/.rivwrt-wifi-v3
REBOOT_GUARD=/etc/.rivwrt-wifi-rebooted

# 逐 radio 的 upsert（不触发 netifd 全量 reload）
rw_updown() {
	ubus call network.wireless "$1" "{\"device\":\"$2\"}" >/dev/null 2>&1
}

# 列出参与 AP 的 radio（跳过 disabled）
list_radios() {
	for r in $(uci -q show wireless | sed -n 's/^wireless\.\(radio[0-9]*\)=wifi-device$/\1/p'); do
		[ "$(uci -q get wireless.$r.disabled)" = "1" ] || echo "$r"
	done
}

# ── 无线就绪判定 ──
# ★ 不能用 `wifi isup <radio>`。读 /sbin/wifi 源码可知 wifi_isup() 只检查
#   radio 的 up 字段：
#       json_get_var up up ; [ $up -eq 0 ] && return 1
#   而真机实测（2026-09-15）三个 radio 全是 up:true，其 AP 接口却是
#   phy0-ap0 DOWN / phy1-ap0 UP / phy2-ap0 DOWN —— radio 起来了但 hostapd 没把
#   AP 拉起来（ath11k regd 未生效）。此时 wifi isup 返回【成功】→ 本脚本误判
#   "一切就绪"→ 不重试、直接落 marker，两个 5G 永远不再尝试。
#   这就是"5G 一直起不来而脚本毫无动作"的直接原因。
#
# 改为判定【AP 接口本身是否真的在广播】：
#   在该 radio 的 SSID 下找一个已配置该 SSID 的 phy*-ap* 接口。
#   hostapd 成功配置后 /sys/class/net 才有该接口、且 `iw dev` 才显示 ssid；
#   起不来时要么接口不存在，要么存在但没有 ssid。
#
# 为什么用 SSID 匹配而不是 ubus/jsonfilter 取接口名：后者要依赖 jsonfilter 的
#   表达式语法（@.radioN.interfaces[*].ifname），而该语法我无法离线验证；
#   一旦写错会拿到空列表 → 所有 radio 被判"未就绪"→ 反复重启无线。
#   三个频段 SSID 互不相同（WANT_SSID 已保证），用 SSID 匹配同样精确且零依赖。
#   接口来源用 /sys/class/net 而非 `ls`，避免依赖 busybox 的 ls applet。

# 该 radio 对应的 iface section
radio_iface_section() {
	uci -q show wireless 2>/dev/null | \
		sed -n "s/^wireless\.\([a-z_0-9]*\)\.device=$1$/\1/p" | head -1
}

# 是否存在一个正在广播 $1(SSID) 的 AP 接口
ssid_on_air() {
	[ -n "$1" ] || return 1
	for _ifn in $(ls /sys/class/net 2>/dev/null | grep -E '^phy[0-9]+-ap[0-9]+$'); do
		# 用 awk 精确比较而非 grep 正则：SSID 里含 "."（如 RivWRT-5.2G），
		# 在正则中 "." 匹配任意字符，会把 RivWRT-512G 之类误判为同一个。
		# awk 里把 "ssid " 前缀剥掉后整行比较，SSID 含空格也能正确比对。
		iw dev "$_ifn" info 2>/dev/null | awk -v s="$1" '
			$1 == "ssid" {
				sub(/^[[:space:]]*ssid[[:space:]]+/, "")
				if ($0 == s) found = 1
			}
			END { exit !found }
		' && return 0
	done
	return 1
}

radio_ready() {		# $1=radio：其 AP 是否真的在广播
	local _sec _ssid
	_sec=$(radio_iface_section "$1")
	[ -n "$_sec" ] || return 0	# 没有对应 iface（非 AP 用途）→ 不干预
	_ssid=$(uci -q get wireless."$_sec".ssid)
	[ -n "$_ssid" ] || return 1
	ssid_on_air "$_ssid"
}

start() {
	[ -f "$MARKER" ] && return 0

	# 等配置就绪（/etc/config/wireless 由 netifd 首启生成）
	i=0
	while [ $i -lt 90 ]; do
		[ -n "$(uci -q get wireless.radio0.band)" ] && break
		[ $i -eq 20 ] && wifi config >/dev/null 2>&1
		i=$((i+1)); sleep 2
	done
	[ -n "$(uci -q get wireless.radio0.band)" ] || return 1

	# 等 ubus 无线服务可查询
	i=0
	while [ $i -lt 30 ]; do
		ubus call network.wireless status >/dev/null 2>&1 && break
		i=$((i+1)); sleep 2
	done

	# ── 0) 清掉 disabled（radio 与 iface 两层）──
	# ★ 必要性：本脚本的 list_radios() 会跳过 disabled 的 radio，于是被禁用的
	#   radio 对【整个流程】不可见 —— 参数不设、不重启、最终"全部就绪"复核也
	#   跳过它，脚本会认为一切正常并落下 marker。实测反馈"无线两个 5G 默认
	#   已禁用"正是此情形：radio 层 disabled=1（多来自早期固件 5G 起不来时
	#   的遗留配置），而 mac80211.uc 只在 iface 层注入 disabled=0，radio 层不管。
	#   必须在参数比对之前做，后续步骤才能看见这些 radio。
	#   仅首启执行一次（受 marker 保护），用户之后的手动调整不会被覆盖。
	CHANGED=0
	DISABLED_FIXED=""
	for SEC in $(uci -q show wireless | sed -n 's/^wireless\.\([a-z_0-9]*\)=wifi-[a-z]*$/\1/p'); do
		[ "$(uci -q get wireless.$SEC.disabled)" = "1" ] || continue
		uci -q set wireless.$SEC.disabled='0'
		DISABLED_FIXED="$DISABLED_FIXED $SEC"
		CHANGED=1
	done
	[ -n "$DISABLED_FIXED" ] && logger -t rivwrt-wifi "已重新启用被禁用的无线段:$DISABLED_FIXED"

	# ── 参数比对（仅不符才改）──
	for RADIO in $(list_radios); do
		BAND=$(uci -q get wireless.$RADIO.band)
		IFACE=$(uci -q show wireless | sed -n "s/^wireless\.\([a-z_0-9]*\)\.device=$RADIO$/\1/p" | head -1)
		[ -n "$IFACE" ] || continue

		case "$BAND" in
			2g)
				WANT_SSID='__SSID__-2.4G'; WANT_CH='11'; WANT_HT='HT20'
				;;
			5g)
				case "$RADIO" in
					radio0) WANT_SSID='__SSID__-5.2G'; WANT_CH='44';  WANT_HT='HE160' ;;
					*)      WANT_SSID='__SSID__-5.8G'; WANT_CH='149'; WANT_HT='HE80'  ;;
				esac
				;;
			*)
				continue
				;;
		esac

		[ "$(uci -q get wireless.$RADIO.channel)" = "$WANT_CH" ] || {
			uci -q set wireless.$RADIO.channel="$WANT_CH"; CHANGED=1; }
		[ "$(uci -q get wireless.$RADIO.htmode)" = "$WANT_HT" ] || {
			uci -q set wireless.$RADIO.htmode="$WANT_HT"; CHANGED=1; }
		[ "$(uci -q get wireless.$RADIO.txpower)" = '24' ] || {
			uci -q set wireless.$RADIO.txpower='24'; CHANGED=1; }
		[ "$(uci -q get wireless.$IFACE.ssid)" = "$WANT_SSID" ] || {
			uci -q set wireless.$IFACE.ssid="$WANT_SSID"; CHANGED=1; }
		[ "$(uci -q get wireless.$IFACE.encryption)" = 'none' ] || {
			uci -q set wireless.$IFACE.encryption='none'
			uci -q delete wireless.$IFACE.key 2>/dev/null
			CHANGED=1; }
	done
	[ "$CHANGED" = "1" ] && uci commit wireless

	# ── 找出未起来的 radio（按 AP 接口实际状态判定，见 radio_ready 注释）──
	NEED=""
	for RADIO in $(list_radios); do
		radio_ready "$RADIO" || NEED="$NEED $RADIO"
	done

	# ── 串行重启（一次一个），避免并发 regd 更新竞争 ──
	if [ -n "$NEED" ]; then
		logger -t rivwrt-wifi "以下 radio 未就绪，开始串行重启:$NEED"
		for RADIO in $NEED; do
			rw_updown down "$RADIO"
			sleep 3
			rw_updown up "$RADIO"
			i=0
			while [ $i -lt 10 ]; do
				radio_ready "$RADIO" && break
				i=$((i+1)); sleep 2
			done
			radio_ready "$RADIO" || logger -t rivwrt-wifi "重启后 $RADIO 仍未就绪" 
		done
	fi

	# ── 复核：全好则落标记；仍有失败则兜底重启一次 ──
	STILL=""
	for RADIO in $(list_radios); do
		radio_ready "$RADIO" || STILL="$STILL $RADIO"
	done
	[ -n "$NEED" ] && logger -t rivwrt-wifi "无线就绪复核：未就绪=[${STILL# }]" 

	if [ -z "$STILL" ]; then
		rm -f "$REBOOT_GUARD"
		touch "$MARKER"
	else
		if [ ! -f "$REBOOT_GUARD" ]; then
			# 兜底：实测重启一次即可恢复。guard 文件防止无限重启循环。
			touch "$REBOOT_GUARD"
			logger -t rivwrt-wifi "串行重启后仍未就绪:$STILL，按兜底策略重启一次"
			sleep 5
			sync
			reboot
		else
			logger -t rivwrt-wifi "仍未就绪:$STILL（兜底重启已用过，不再重启以免循环）"
		fi
	fi
}
RIVWRT_WIFI
sed -i "s/__SSID__/$WRT_SSID/g" "$WIFI_INIT"   # heredoc 引号形式，此处展开 SSID
chmod +x "$WIFI_INIT"

# rc.d 启动链接（固件层启用，否则首启不会执行）
mkdir -p "./package/base-files/files/etc/rc.d"
ln -sf ../init.d/rivwrt-wifi "./package/base-files/files/etc/rc.d/S99rivwrt-wifi"

# -------------------------------------------------------
# RivWRT：swap 分区默认启用（eMMC mmcblk0p26）
# 上游树对 jdcloud_re-cs-02 未做 swap 自动挂载；1G RAM 设备启用 swap
# 承载跑分/插件缓存。传统 rc.common start() 风格（非 procd），
# 避免 USE_PROCD 差异带来的 start_service 不调用问题。
# -------------------------------------------------------
SWAP_INIT="./package/base-files/files/etc/init.d/rivwrt-swap"
cat > "$SWAP_INIT" <<'RIVWRT_SWAP'
#!/bin/sh /etc/rc.common
START=20
start() {
	[ -b /dev/mmcblk0p26 ] || return 0
	# 幂等：未格式化才 mkswap（原厂/旧固件已格式化为 swap 则跳过）
	blkid -t TYPE=swap /dev/mmcblk0p26 >/dev/null 2>&1 || mkswap /dev/mmcblk0p26 >/dev/null 2>&1
	swapon /dev/mmcblk0p26 2>/dev/null
}
RIVWRT_SWAP
chmod +x "$SWAP_INIT"
ln -sf ../init.d/rivwrt-swap "./package/base-files/files/etc/rc.d/S20rivwrt-swap"

# -------------------------------------------------------
# RivWRT：NSS 负载历史采集（collectd exec → RRD）
#
# 接线链（每环独立验证过）：
#   ① init.d rivwrt-nss-stat (root, START=25)
#        等 debugfs 就绪 → chmod 644 cpu_load_ubi
#        （collectd 硬性拒绝以 root 跑 exec，见 collectd-exec.pod CAVEATS）
#   ② uci-defaults 99-rivwrt-nss-stat
#        开 collectd_exec 插件 + 注册采集脚本（cmduser=nobody，见下）
#        rrdtool.backup=1 → 关机时打包，重启恢复（平时 RRD 在 /tmp 不写 eMMC）
#   ③ collectd exec 插件每 30s fork nss-collectd.sh（以 nobody 身份）
#        解析 "Core 0: / Min Avg Max / 7% 7% 34%" 取 Avg → PUTVAL（plugin=nss-load）
#   ④ RRD /tmp/rrd/<host>/nss-load/gauge-core0.rrd
#        页面经 rrdtool1 fetch 读取
# -------------------------------------------------------

# ① 放开 debugfs 统计文件读权限（collectd 以非 root 身份运行）
NSSSTAT_INIT="./package/base-files/files/etc/init.d/rivwrt-nss-stat"
cat > "$NSSSTAT_INIT" <<'RIVWRT_NSSSTAT'
#!/bin/sh /etc/rc.common
START=25
start() {
	# 等 NSS 驱动建好 debugfs 节点（最多 60s）
	# 同 nss-status：不用 mountpoint（busybox 默认不编译该 applet），
	# 改为「文件可读就跳过，否则尝试挂载」——已挂载时 mount 返回 EBUSY，无害。
	i=0
	while [ $i -lt 30 ]; do
		[ -r /sys/kernel/debug/qca-nss-drv/stats/cpu_load_ubi ] && break
		mount -t debugfs none /sys/kernel/debug 2>/dev/null
		i=$((i+1)); sleep 2
	done
	F=/sys/kernel/debug/qca-nss-drv/stats/cpu_load_ubi
	[ -f "$F" ] || return 0
	# 只放开这一个只读统计文件；debugfs 其余保持原权限
	chmod 644 "$F" 2>/dev/null
}
RIVWRT_NSSSTAT
chmod +x "$NSSSTAT_INIT"
ln -sf ../init.d/rivwrt-nss-stat "./package/base-files/files/etc/rc.d/S25rivwrt-nss-stat"

# ③ 采集脚本：debugfs → collectd PUTVAL
NSSCOLLECT="./package/base-files/files/usr/libexec/rivwrt/nss-collectd.sh"
mkdir -p "$(dirname "$NSSCOLLECT")"
cat > "$NSSCOLLECT" <<'RIVWRT_NSSCOLLECT'
#!/bin/sh
# 采集 NSS 核心负载，输出 collectd exec 协议（PUTVAL）。
#
# ★ 常驻循环，不退出：collectd exec 插件把 STDERR 接到管道，程序一旦退出
#   （或重定向 fd2）该管道即 EOF，被判为异常并记日志：
#       exec plugin: Program `...' has closed STDERR.
#   （源码 exec.c 的 NOTICE 分支；且文档明说 exec 本就设计给长期运行的
#    可执行文件："perfectly legal ... run for a long time and continuously
#     write values to STDOUT"）
#   故此处循环采集、持续持有 STDERR，退出由 collectd 发 SIGTERM 触发。
#   采集周期取自 collectd 注入的环境变量 COLLECTD_INTERVAL（默认 30s）。
#
# 输入格式（设备实测）：
#   CPU Utilization:
#   Note: Averaged over 1 second
#   Core 0:
#   Min     Avg     Max
#    2%      7%      34%
# 取 Avg 列（= 行的第 2 个字段）。两个刻意的选择：
#   ① 取 $2 而非行内首个百分比 —— 首个是 Min（瞬时最低），Avg 才代表负载；
#   ② 按 "Core N:" 定位而非上游 sbin/cpuusage 的 "NR==6" 硬编码行号 ——
#      行数一变（如多核、表头增减）硬编码即取空。
# 单核设备仅有 Core 0（AX6600=IPQ6010）。
F=/sys/kernel/debug/qca-nss-drv/stats/cpu_load_ubi
INTERVAL="${COLLECTD_INTERVAL:-30}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=30 ;; esac

while :; do
	if [ -r "$F" ]; then
		awk '
			/^Core [0-9]+:/ { core = $2; sub(":", "", core); has_core = 1; next }
			has_core && /%/ { gsub("%", "", $2); print "RivWRT/nss-load/gauge-core" core " N:" $2; has_core = 0 }
		' "$F"
	fi
	sleep "$INTERVAL"
done
RIVWRT_NSSCOLLECT
chmod +x "$NSSCOLLECT"


# ② uci-defaults：开 exec 插件 + 注册采集脚本（cmduser root）
#    注：collectd 硬性拒绝以 root 运行 exec（collectd-exec.pod CAVEATS：
#    "The user ... may not have root privileges"），故 cmduser 必须非 root。
#    debugfs 默认仅 root 可读，由 ① 的 init.d 预先 chmod 644，nobody 即可读取。
NSSSTAT_UDIR="./package/base-files/files/etc/uci-defaults/99-rivwrt-nss-stat"
mkdir -p "$(dirname "$NSSSTAT_UDIR")"
cat > "$NSSSTAT_UDIR" <<'RIVWRT_NSSUDIR'
#!/bin/sh
# 开启 collectd exec 插件
uci -q set luci_statistics.collectd_exec=statistics
uci -q set luci_statistics.collectd_exec.enable='1'
# 注册 NSS 负载采集（每 30s 一次，跟随全局 Interval）
uci -q delete luci_statistics.rivwrt_nss
uci -q set luci_statistics.rivwrt_nss=collectd_exec_input
uci -q set luci_statistics.rivwrt_nss.cmdline='/usr/libexec/rivwrt/nss-collectd.sh'
uci -q set luci_statistics.rivwrt_nss.cmduser='nobody'
# 注：不修改 collectd_rrdtool 的 backup / RRATimespans ——
#   两者是【全局】设置，会影响统计页的 cpu/memory 等所有图。用户要求
#   "统计恢复原样"，故保持上游默认（backup=0、RRATimespans 五档含 1year）。
#   NSS 历史读的是 2h/12h/1d/1w，默认 RRATimespans 已完整覆盖，无需改动。
uci -q commit luci_statistics
# 重启采集使配置生效（首启时 collectd 可能尚未安装完成，失败可忽略）
[ -x /etc/init.d/luci_statistics ] && /etc/init.d/luci_statistics restart >/dev/null 2>&1
[ -x /etc/init.d/collectd ] && /etc/init.d/collectd restart >/dev/null 2>&1
exit 0
RIVWRT_NSSUDIR
chmod +x "$NSSSTAT_UDIR"
