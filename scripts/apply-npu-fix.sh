#!/bin/bash
# ============================================================================
# apply-npu-fix.sh
# 将 Airoha EN7581 的 ETH/NPU 驱动从 built-in 改为 kmod，解决固件加载
# 时机过早导致的 probe 失败问题。
#
# 对应 fork 仓库 xiangtailiang/openwrt 分支 xg040gmd-fixes 的修改：
#   - ebcb80714c airoha: an7581: bell xg-040g-md: add NPU firmware, disable AFE
#   - 7c9ed7ad41 airoha: an7581: ship airoha-eth/npu as kmods
#
# 在 openwrt/ 源码根目录下运行。
# ============================================================================

set -euo pipefail

OPENWRT_ROOT="${1:-.}"
cd "$OPENWRT_ROOT"

echo "[apply-npu-fix] Starting NPU driver fixup..."
echo "[apply-npu-fix] Working directory: $(pwd)"

# ────────────────────────────────────────────────────────────────────────────
# Step 1: 将内核配置中的 NPU/ETH 从 built-in 改为 module
# ────────────────────────────────────────────────────────────────────────────
AN7581_CONFIG_DIR="target/linux/airoha/an7581"
CONFIG_FILES=$(find "$AN7581_CONFIG_DIR" -maxdepth 1 -name 'config-6.*' -type f 2>/dev/null || true)

if [ -z "$CONFIG_FILES" ]; then
    echo "[apply-npu-fix] WARNING: No config-6.* found in $AN7581_CONFIG_DIR"
else
    for cf in $CONFIG_FILES; do
        echo "[apply-npu-fix] Patching kernel config: $cf"

        # CONFIG_NET_AIROHA: built-in → module
        if grep -q '^CONFIG_NET_AIROHA=y' "$cf"; then
            sed -i 's/^CONFIG_NET_AIROHA=y/CONFIG_NET_AIROHA=m/' "$cf"
            echo "  -> CONFIG_NET_AIROHA: y → m"
        elif grep -q '^CONFIG_NET_AIROHA=m' "$cf"; then
            echo "  -> CONFIG_NET_AIROHA: already =m (skip)"
        else
            echo "  -> CONFIG_NET_AIROHA: adding =m"
            echo "CONFIG_NET_AIROHA=m" >> "$cf"
        fi

        # CONFIG_NET_AIROHA_NPU: built-in → module
        if grep -q '^CONFIG_NET_AIROHA_NPU=y' "$cf"; then
            sed -i 's/^CONFIG_NET_AIROHA_NPU=y/CONFIG_NET_AIROHA_NPU=m/' "$cf"
            echo "  -> CONFIG_NET_AIROHA_NPU: y → m"
        elif grep -q '^# CONFIG_NET_AIROHA_NPU is not set' "$cf"; then
            sed -i 's/^# CONFIG_NET_AIROHA_NPU is not set/CONFIG_NET_AIROHA_NPU=m/' "$cf"
            echo "  -> CONFIG_NET_AIROHA_NPU: not set → m"
        elif grep -q '^CONFIG_NET_AIROHA_NPU=m' "$cf"; then
            echo "  -> CONFIG_NET_AIROHA_NPU: already =m (skip)"
        else
            echo "  -> CONFIG_NET_AIROHA_NPU: adding =m"
            echo "CONFIG_NET_AIROHA_NPU=m" >> "$cf"
        fi
    done
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 2: 在 netdevices.mk 中新增 kmod-airoha-npu 和 kmod-airoha-eth
# ────────────────────────────────────────────────────────────────────────────
NETDEVICES_MK="package/kernel/linux/modules/netdevices.mk"

if [ ! -f "$NETDEVICES_MK" ]; then
    echo "[apply-npu-fix] ERROR: $NETDEVICES_MK not found!"
    exit 1
fi

if grep -q 'KernelPackage/airoha-npu' "$NETDEVICES_MK" 2>/dev/null; then
    echo "[apply-npu-fix] kmod-airoha-npu already defined in netdevices.mk (skip)"
else
    echo "[apply-npu-fix] Adding kmod-airoha-npu and kmod-airoha-eth to $NETDEVICES_MK"

    cat >> "$NETDEVICES_MK" << 'KMODEOF'


# ── Airoha EN7581 NPU / Ethernet kmods ──────────────────────────────────

define KernelPackage/airoha-npu
  SUBMENU:=$(NETWORK_DEVICES_MENU)
  TITLE:=Airoha EN7581 NPU driver
  DEPENDS:=@TARGET_airoha
  KCONFIG:=CONFIG_NET_AIROHA_NPU
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/airoha/airoha_npu.ko
  AUTOLOAD:=$(call AutoLoad,18,airoha_npu,1)
  $(call AddDepends/ethernet)
endef
$(eval $(call KernelPackage,airoha-npu))

define KernelPackage/airoha-eth
  SUBMENU:=$(NETWORK_DEVICES_MENU)
  TITLE:=Airoha EN7581 Ethernet driver
  DEPENDS:=@TARGET_airoha +kmod-airoha-npu
  KCONFIG:=CONFIG_NET_AIROHA
  FILES:=$(LINUX_DIR)/drivers/net/ethernet/airoha/airoha_eth.ko
  AUTOLOAD:=$(call AutoLoad,19,airoha_eth,1)
  $(call AddDepends/ethernet)
endef
$(eval $(call KernelPackage,airoha-eth))

KMODEOF

    echo "  -> Done."
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 3: 将 kmod 包加入 target 默认包列表 (target.mk)
# ────────────────────────────────────────────────────────────────────────────
TARGET_MK="$AN7581_CONFIG_DIR/target.mk"

if [ -f "$TARGET_MK" ]; then
    if grep -q 'kmod-airoha-eth' "$TARGET_MK" 2>/dev/null; then
        echo "[apply-npu-fix] kmod-airoha already in target.mk DEFAULT_PACKAGES (skip)"
    else
        echo "[apply-npu-fix] Adding kmod-airoha-eth kmod-airoha-npu to DEFAULT_PACKAGES in $TARGET_MK"
        sed -i '/^DEFAULT_PACKAGES/s/\(.*\)/\1 kmod-airoha-eth kmod-airoha-npu/' "$TARGET_MK"
        echo "  -> Done."
    fi
else
    echo "[apply-npu-fix] WARNING: $TARGET_MK not found, cannot add default packages"
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 4: 在设备定义中加入 NPU 固件 + kmod 包 (an7581.mk)
# ────────────────────────────────────────────────────────────────────────────
DEVICE_MK="target/linux/airoha/image/an7581.mk"

if [ -f "$DEVICE_MK" ]; then
    if grep -q 'bell_xg-040g-md' "$DEVICE_MK" 2>/dev/null; then
        if grep -q 'airoha-en7581-npu-firmware' "$DEVICE_MK" 2>/dev/null; then
            echo "[apply-npu-fix] NPU firmware already in $DEVICE_MK DEVICE_PACKAGES (skip)"
        else
            echo "[apply-npu-fix] Adding NPU firmware + kmods to bell_xg-040g-md DEVICE_PACKAGES"
            # 在 bell_xg-040g-md 的 DEVICE_PACKAGES 行末尾追加包名
            sed -i '/bell_xg-040g-md/,/endef/{
                s/\(DEVICE_PACKAGES.*\)/\1 airoha-en7581-npu-firmware kmod-airoha-eth kmod-airoha-npu/
            }' "$DEVICE_MK"
            echo "  -> Done."
        fi
    else
        echo "[apply-npu-fix] WARNING: bell_xg-040g-md not found in $DEVICE_MK"
    fi
else
    echo "[apply-npu-fix] WARNING: $DEVICE_MK not found"
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 5: 设备树中禁用 AFE (Audio Front End), 消除无意义的 -2 报错
# ────────────────────────────────────────────────────────────────────────────
DTS_FILE="target/linux/airoha/dts/an7581-bell_xg-040g-md.dts"

if [ -f "$DTS_FILE" ]; then
    if grep -q '&afe' "$DTS_FILE" 2>/dev/null; then
        echo "[apply-npu-fix] AFE already referenced in $DTS_FILE (skip)"
    else
        echo "[apply-npu-fix] Adding &afe disable to $DTS_FILE"
        # 追加到文件末尾
        printf '\n&afe {\n\tstatus = "disabled";\n};\n' >> "$DTS_FILE"
        echo "  -> Done."
    fi
else
    echo "[apply-npu-fix] WARNING: $DTS_FILE not found, cannot disable AFE"
fi

# ────────────────────────────────────────────────────────────────────────────
# Step 6: 修复 cpufreq —— 添加 chip-scu syscon 节点并引用到 cpufreq
#         修复 "ATF SMC not available and no chip-scu reg in DT" 导致的
#         CPU 频率锁死问题
# ────────────────────────────────────────────────────────────────────────────
# chip-scu 位于 SoC 总线 0x1fa20000, 大小 0x388
if [ -f "$DTS_FILE" ]; then
    if grep -q 'syscon@1fa20000' "$DTS_FILE" 2>/dev/null; then
        echo "[apply-npu-fix] chip-scu syscon already in DTS (skip)"
    else
        echo "[apply-npu-fix] Adding chip-scu syscon@1fa20000 to $DTS_FILE"
        # 在文件开头最后一个 #include 之后插入 SoC 级节点
        cat >> "$DTS_FILE" << 'CHIPSCUEOF'

&{/soc} {
	chip_scu: syscon@1fa20000 {
		compatible = "airoha,en7581-chip-scu", "syscon";
		reg = <0x0 0x1fa20000 0x0 0x388>;
	};
};
CHIPSCUEOF
        echo "  -> Done."
    fi

    if grep -q 'airoha,chip-scu' "$DTS_FILE" 2>/dev/null; then
        echo "[apply-npu-fix] cpufreq chip-scu reference already in DTS (skip)"
    else
        echo "[apply-npu-fix] Adding cpufreq chip-scu reference to $DTS_FILE"
        cat >> "$DTS_FILE" << 'CPUFREQEOF'

&cpufreq {
	airoha,chip-scu = <&chip_scu>;
};
CPUFREQEOF
        echo "  -> Done."
    fi
else
    echo "[apply-npu-fix] WARNING: $DTS_FILE not found, cannot fix cpufreq"
fi

echo "[apply-npu-fix] NPU driver fixup completed."

# 输出修改摘要
echo ""
echo "=== Summary of changes ==="
echo "Kernel configs patched: ${CONFIG_FILES:-none}"
echo "netdevices.mk: $NETDEVICES_MK"
echo "target.mk: $TARGET_MK"
echo "device mk: $DEVICE_MK"
echo "DTS (AFE + cpufreq): $DTS_FILE"
