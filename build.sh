#!/usr/bin/bash

yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
gre='\e[0;32m'

cd ${0%/*}

KDIR=$(pwd)
DEFCONFIG=marble_defconfig
IMAGE=${KDIR}/out/arch/arm64/boot/Image
OUTPUT_DIR=~/Bouquet_marble_out
SUSFS_REPO=~/susfs4ksu
DEVICETREE="arch/arm64/boot/dts/vendor/qcom"

mkdir -p $OUTPUT_DIR
mkdir -p ${OUTPUT_DIR}/vendor_boot_modules
mkdir -p ${OUTPUT_DIR}/vendor_dlkm_modules
mkdir -p ${OUTPUT_DIR}/alt_kernel_modules

# Ensure build-tools exist
if [ ! -d "${KDIR}/build-tools" ]; then
	echo -e "${yellow}build-tools directory missing! Downloading build-tools...${white}"
	git clone https://github.com/Pzqqt/android_kernel_xiaomi_marble.git -b bouquet_ci --depth=1 /tmp/pzqqt_tools
	cp -r /tmp/pzqqt_tools/build-tools ${KDIR}/
	rm -rf /tmp/pzqqt_tools
fi

########## Parsing parameters ##########

use_defconfig=$DEFCONFIG
no_mkclean=false
no_ccache=false
with_ksu=false
with_susfs=false
ksu_variant="KernelSU"
ksu_repo="https://github.com/tiann/KernelSU.git"
ksu_branch=""
make_target=

while [ $# != 0 ]; do
	case $1 in
		"--noclean") no_mkclean=true;;
		"--noccache") no_ccache=true;;
		"--ksu"|"--kernelsu") {
			with_ksu=true
			ksu_variant="KernelSU"
			ksu_repo="https://github.com/tiann/KernelSU.git"
		};;
		"--kowsu") {
			with_ksu=true
			ksu_variant="KowSU"
			ksu_repo="https://github.com/deepongi-labs/KernelSU-KoWSU.git"
		};;
		"--sukisu"|"--sukisu-ultra") {
			with_ksu=true
			ksu_variant="SukiSU_Ultra"
			ksu_repo="https://github.com/SukiSU-Ultra/SukiSU-Ultra.git"
		};;
		"--resukisu") {
			with_ksu=true
			ksu_variant="ReSukiSU"
			ksu_repo="https://github.com/ReSukiSU/ReSukiSU.git"
		};;
		"--kittisu") {
			with_ksu=true
			ksu_variant="KittiSU"
			ksu_repo="https://github.com/thinhzero/KittiSU.git"
		};;
		"--susfs") {
			with_ksu=true
			with_susfs=true
		};;
		"--ksu-repo") {
			shift
			ksu_repo=$1
		};;
		"--ksu-branch") {
			shift
			ksu_branch=$1
		};;
		"--defconfig") {
			shift
			use_defconfig=$1
		};;
		"--") {
			shift
			make_target=$*
			break
		};;
		*) {
			cat <<EOF
Usage: $0 <operate>
operate:
    --noclean               : build without running "make mrproper"
    --noccache              : build without ccache
    --ksu                   : build with official KernelSU
    --kowsu                 : build with KowSU
    --sukisu                : build with SukiSU Ultra
    --resukisu              : build with ReSukiSU
    --kittisu               : build with KittiSU
    --susfs                 : build with susfs support
    --ksu-repo <url>        : custom KernelSU repository URL
    --ksu-branch <branch>   : custom KernelSU branch
    --defconfig <defconfig> : use specified defconfig (default: $DEFCONFIG)
    -- <args>               : parameters passed directly to make
EOF
			exit 1
		};;
	esac
	shift
done

########## Preparation Phase ##########

export KBUILD_BUILD_HOST="ubuntu"
export KBUILD_BUILD_USER="github"

# Auto detect LLVM path
if [ -d ~/build_toolchain/llvm-23.1.0-rc3-x86_64/bin ]; then
	CLANG_PATH=~/build_toolchain/llvm-23.1.0-rc3-x86_64/bin
elif [ -d ~/build_toolchain/llvm-22.1.8-x86_64/bin ]; then
	CLANG_PATH=~/build_toolchain/llvm-22.1.8-x86_64/bin
else
	CLANG_PATH=$(find ~/build_toolchain -maxdepth 3 -type d -name "bin" 2>/dev/null | head -n 1)
fi

echo -e "${gre}Building kernel with Slim LLVM at ${CLANG_PATH} $white"

export PATH=$(realpath $CLANG_PATH):$(realpath ${KDIR}/build-tools):${PATH}

export LOCALVERSION=-$(git rev-parse --short HEAD 2>/dev/null || echo "ci")
$with_ksu && {
	while true; do
		kversion_ksu_suffix=$(cat /dev/urandom | tr -dc 'a-zA-Z' | head -c 3)
		if [ "$kversion_ksu_suffix" != "ksu" ]; then
			break
		fi
	done
	export LOCALVERSION=${LOCALVERSION}_${kversion_ksu_suffix}
}

$with_susfs && {
	while true; do
		kversion_susfs_suffix=$(cat /dev/urandom | tr -dc 'a-zA-Z' | head -c 5)
		if [ "$kversion_susfs_suffix" != "susfs" ]; then
			break
		fi
	done
	export LOCALVERSION=${LOCALVERSION}_${kversion_susfs_suffix}
}

echo -e "${gre}LOCALVERSION = ${LOCALVERSION} $white"

make_params="
ARCH=arm64 \
CC=clang \
LD=ld.lld \
AR=llvm-ar \
NM=llvm-nm \
OBJCOPY=llvm-objcopy \
OBJDUMP=llvm-objdump \
READELF=llvm-readelf \
OBJSIZE=llvm-size \
STRIP=llvm-strip \
LLVM=1 \
LLVM_IAS=1 \
CROSS_COMPILE=aarch64-linux-gnu- \
CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
CLANG_TRIPLE=aarch64-linux-gnu- \
O=out \
"

if ! $no_ccache; then
	make_params="$make_params CC='ccache clang'"
fi

########## KernelSU & susfs Setup ##########

if $with_ksu; then
	mkdir -p ~/KernelSU_source
	cd ~/KernelSU_source
	rm -rf KernelSU
	
	echo -e "${gre}Cloning ${ksu_variant} from ${ksu_repo}...${white}"
	if [ -n "$ksu_branch" ]; then
		git clone "$ksu_repo" -b "$ksu_branch" KernelSU --depth=1
	else
		git clone "$ksu_repo" KernelSU --depth=1
	fi
	
	KERNELSU_REPO=$(pwd)/KernelSU
	cd ${KDIR}
	
	rm -rf "${KDIR}/drivers/kernelsu"
	echo "- Linking ${ksu_variant}..."
	ln -sf "${KERNELSU_REPO}/kernel" "${KDIR}/drivers/kernelsu"

	echo "- Patching KernelSU setup into drivers Kconfig and Makefile..."
	driver_kconfig=${KDIR}/drivers/Kconfig
	driver_makefile=${KDIR}/drivers/Makefile

	grep -q "source \"drivers/kernelsu/Kconfig\"" "$driver_kconfig" || echo 'source "drivers/kernelsu/Kconfig"' >> "$driver_kconfig"
	grep -q "obj-y += kernelsu/" "$driver_makefile" || echo 'obj-y += kernelsu/' >> "$driver_makefile"
fi

if $with_susfs; then
	if [ ! -d "$SUSFS_REPO" ]; then
		echo -e "${red}Error: $SUSFS_REPO directory does not exist!${white}"
		exit 1
	fi

	if [ ! -f "${KDIR}/include/linux/susfs.h" ]; then
		echo "- Copying susfs headers and files..."
		cp -r ${SUSFS_REPO}/include/linux/* ${KDIR}/include/linux/
		cp -r ${SUSFS_REPO}/fs/* ${KDIR}/fs/
	fi
fi

########## Compilation Phase ##########

echo -e "${gre}Starting build for ${ksu_variant}... $white"

t_start=$(date +"%s")

if ! $no_mkclean; then
	echo -e "${yellow}Cleaning output directory...${white}"
	make $make_params mrproper
fi

if [ ! -f "${KDIR}/out/.config" ]; then
	echo -e "${yellow}Configuring defconfig (${use_defconfig})...${white}"
	make $make_params $use_defconfig
fi

if $with_ksu; then
	echo -e "${yellow}Enabling CONFIG_KSU...${white}"
	scripts/config --file ${KDIR}/out/.config -e CONFIG_KSU
fi

if $with_susfs; then
	echo -e "${yellow}Enabling CONFIG_KSU_SUSFS...${white}"
	scripts/config --file ${KDIR}/out/.config -e CONFIG_KSU_SUSFS \
		-e CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT \
		-e CONFIG_KSU_SUSFS_SUS_PATH \
		-e CONFIG_KSU_SUSFS_SUS_MOUNT \
		-e CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSUM \
		-e CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND \
		-e CONFIG_KSU_SUSFS_SUS_KSTAT \
		-e CONFIG_KSU_SUSFS_SUS_OVERLAYFS \
		-e CONFIG_KSU_SUSFS_TRY_UMOUNT \
		-e CONFIG_KSU_SUSFS_SPOOF_UNAME \
		-e CONFIG_KSU_SUSFS_ENABLE_LOG \
		-e CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
		-e CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
		-e CONFIG_KSU_SUSFS_OPEN_REDIRECT
fi

if [ -n "$make_target" ]; then
	make $make_params -j$(nproc --all) $make_target
else
	make $make_params -j$(nproc --all)
fi

if [ ! -f "$IMAGE" ]; then
	echo -e "${red}Build failed: Image file not generated!${white}"
	exit 1
fi

if $with_susfs; then
	cp "$IMAGE" "${OUTPUT_DIR}/Image"
	cp "$IMAGE" "${OUTPUT_DIR}/Image_ksu"
	cp "$IMAGE" "${OUTPUT_DIR}/Image_susfs"
	cp "$IMAGE" "${OUTPUT_DIR}/Image_susfs_${ksu_variant}_${LOCALVERSION}"
elif $with_ksu; then
	cp "$IMAGE" "${OUTPUT_DIR}/Image"
	cp "$IMAGE" "${OUTPUT_DIR}/Image_ksu"
	cp "$IMAGE" "${OUTPUT_DIR}/Image_${ksu_variant}_${LOCALVERSION}"
else
	cp "$IMAGE" "${OUTPUT_DIR}/Image"
	cp "$IMAGE" "${OUTPUT_DIR}/Image_${LOCALVERSION}"
fi

if [ -f "${KDIR}/out/Module.symvers" ]; then
	cp "${KDIR}/out/Module.symvers" "${OUTPUT_DIR}/Image_vmlinux.symvers"
elif [ -f "${KDIR}/out/vmlinux.symvers" ]; then
	cp "${KDIR}/out/vmlinux.symvers" "${OUTPUT_DIR}/Image_vmlinux.symvers"
fi

########## Module & DTB Handling ##########

both_need_modules='
drivers/char/hw_random/msm_rng.ko
drivers/clk/qcom/camcc-sm8450.ko
drivers/clk/qcom/dispcc-sm8450.ko
drivers/clk/qcom/gcc-sm8450.ko
drivers/clk/qcom/gpucc-sm8450.ko
drivers/clk/qcom/tcsscc-sm8450.ko
drivers/clk/qcom/videocc-sm8450.ko
drivers/cpufreq/qcom-cpufreq-hw.ko
drivers/dma-buf/heaps/qcom_sg_ops.ko
drivers/dma-buf/heaps/system_heap.ko
drivers/firmware/qcom/qcom_scm.ko
drivers/gpu/drm/msm/sde_dm.ko
drivers/gpu/msm/kgsl.ko
drivers/i2c/busses/i2c-msm-geni.ko
drivers/input/touchscreen/goodix_ts_berlin/goodix_ts_berlin.ko
drivers/input/touchscreen/xiaomi/xiaomi_touch.ko
drivers/interconnect/qcom/qnoc-cape.ko
drivers/interconnect/qcom/qnoc-diwali.ko
drivers/interconnect/qcom/qnoc-qos.ko
drivers/interconnect/qcom/qnoc-waipio.ko
drivers/iommu/arm/arm-smmu/arm_smmu.ko
drivers/iommu/iommu-logger.ko
drivers/iommu/msm_dma_iommu_mapping.ko
drivers/iommu/qcom_iommu_util.ko
drivers/irqchip/qcom-pdc.ko
drivers/mailbox/msm_qmp.ko
drivers/mfd/qcom-spmi-pmic.ko
drivers/misc/hwid/hwid.ko
drivers/mmc/host/cqhci.ko
drivers/nfc/qti/nfc_i2c.ko
drivers/nvmem/nvmem_qcom-spmi-sdam.ko
drivers/perf/qcom_llcc_pmu.ko
drivers/phy/qualcomm/phy-qcom-ufs-qmp-v4-cape.ko
drivers/phy/qualcomm/phy-qcom-ufs-qmp-v4-diwali.ko
drivers/phy/qualcomm/phy-qcom-ufs-qmp-v4-waipio.ko
drivers/phy/qualcomm/phy-qcom-ufs.ko
drivers/pinctrl/qcom/pinctrl-cape.ko
drivers/pinctrl/qcom/pinctrl-diwali.ko
drivers/pinctrl/qcom/pinctrl-msm.ko
drivers/pinctrl/qcom/pinctrl-waipio.ko
drivers/platform/msm/msm-geni-se.ko
drivers/power/reset/qcom-dload-mode.ko
drivers/power/reset/qcom-reboot-reason.ko
drivers/power/reset/reboot-mode.ko
drivers/regulator/debug-regulator.ko
drivers/regulator/proxy-consumer.ko
drivers/regulator/qti-fixed-regulator.ko
drivers/regulator/rpmh-regulator.ko
drivers/regulator/stub-regulator.ko
drivers/rtc/rtc-pm8xxx.ko
drivers/scsi/ufs/ufs_qcom.ko
drivers/scsi/ufs/ufshcd-crypto-qti.ko
drivers/soc/qcom/cmd-db.ko
drivers/soc/qcom/crypto-qti-common.ko
drivers/soc/qcom/crypto-qti-hwkm.ko
drivers/soc/qcom/dcvs/bwmon.ko
drivers/soc/qcom/dcvs/c1dcvs_scmi.ko
drivers/soc/qcom/dcvs/dcvs_fp.ko
drivers/soc/qcom/dcvs/pmu_scmi.ko
drivers/soc/qcom/dcvs/qcom-dcvs.ko
drivers/soc/qcom/dcvs/qcom-pmu-lib.ko
drivers/soc/qcom/hwkm.ko
drivers/soc/qcom/llcc-qcom.ko
drivers/soc/qcom/mem-hooks.ko
drivers/soc/qcom/mem_buf/mem_buf.ko
drivers/soc/qcom/mem_buf/mem_buf_dev.ko
drivers/soc/qcom/memory_dump_v2.ko
drivers/soc/qcom/minidump.ko
drivers/soc/qcom/qcom_aoss.ko
drivers/soc/qcom/qcom_cpu_vendor_hooks.ko
drivers/soc/qcom/qcom_gic_intr_routing.ko
drivers/soc/qcom/qcom_ipcc.ko
drivers/soc/qcom/qcom_rimps.ko
drivers/soc/qcom/qcom_rpmh.ko
drivers/soc/qcom/qcom_wdt_core.ko
drivers/soc/qcom/secure_buffer.ko
drivers/soc/qcom/smem.ko
drivers/soc/qcom/socinfo.ko
drivers/soc/qcom/tmecom/tmecom-intf.ko
drivers/spmi/spmi-pmic-arb.ko
drivers/staging/kshrink_slabd/kshrink_slabd.ko
drivers/staging/kshrink_lruvecd/kshrink_lruvecd.ko
drivers/thermal/qcom/bcl_pmic5.ko
drivers/thermal/qcom/cpu_hotplug.ko
drivers/thermal/qcom/qcom_tsens.ko
drivers/thermal/qcom/thermal_pause.ko
drivers/tty/serial/msm_geni_serial.ko
drivers/usb/phy/phy-generic.ko
drivers/virt/gunyah/gh_ctrl.ko
drivers/virt/gunyah/gh_dbl.ko
drivers/virt/gunyah/gh_msgq.ko
drivers/virt/gunyah/gh_rm_drv.ko
drivers/virt/gunyah/gh_virt_wdt.ko
kernel/sched/walt/sched-walt.ko
kernel/trace/qcom_ipc_logging.ko
net/qrtr/qrtr.ko
techpack/bootinfo/bootinfo.ko
'

vendor_dlkm_need_modules='
drivers/soc/qcom/vh_fs/vh_fs.ko
drivers/staging/qcacld-3.0/qca6490.ko
net/mac80211/mac80211.ko
net/wireless/cfg80211.ko
techpack/audio/asoc/codecs/aw882xx/aw882xx_dlkm.ko
techpack/audio/asoc/codecs/hdmi_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_rx_macro_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_tx_macro_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_va_macro_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_wsa2_macro_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_wsa_macro_dlkm.ko
techpack/audio/asoc/codecs/mbhc_dlkm.ko
techpack/audio/asoc/codecs/stub_dlkm.ko
techpack/audio/asoc/codecs/swr_dmic_dlkm.ko
techpack/audio/asoc/codecs/swr_haptics_dlkm.ko
techpack/audio/asoc/codecs/wcd937x/wcd937x_dlkm.ko
techpack/audio/asoc/codecs/wcd937x/wcd937x_slave_dlkm.ko
techpack/audio/asoc/codecs/wcd938x/wcd938x_dlkm.ko
techpack/audio/asoc/codecs/wcd938x/wcd938x_slave_dlkm.ko
techpack/audio/asoc/codecs/wcd9xxx_dlkm.ko
techpack/audio/asoc/codecs/wcd_core_dlkm.ko
techpack/audio/asoc/codecs/wsa881x_dlkm.ko
techpack/audio/asoc/codecs/wsa883x/wsa883x_dlkm.ko
techpack/audio/asoc/machine_dlkm.ko
techpack/audio/dsp/adsp_loader_dlkm.ko
techpack/audio/dsp/audio_prm_dlkm.ko
techpack/audio/dsp/audpkt_ion_dlkm.ko
techpack/audio/dsp/q6_dlkm.ko
techpack/audio/dsp/q6_notifier_dlkm.ko
techpack/audio/dsp/q6_pdr_dlkm.ko
techpack/audio/dsp/spf_core_dlkm.ko
techpack/audio/ipc/audio_pkt_dlkm.ko
techpack/audio/ipc/gpr_dlkm.ko
techpack/audio/soc/pinctrl_lpi_dlkm.ko
techpack/audio/soc/snd_event_dlkm.ko
techpack/audio/soc/swr_ctrl_dlkm.ko
techpack/audio/soc/swr_dlkm.ko
techpack/camera/camera.ko
techpack/cvp/msm/msm-cvp.ko
techpack/dataipa/drivers/platform/msm/gsi/gsim.ko
techpack/dataipa/drivers/platform/msm/ipa/ipa_clients/ipa_clientsm.ko
techpack/dataipa/drivers/platform/msm/ipa/ipa_clients/rndisipam.ko
techpack/dataipa/drivers/platform/msm/ipa/ipam.ko
techpack/dataipa/drivers/platform/msm/ipa/ipanetm.ko
techpack/datarmnet-ext/aps/rmnet_aps.ko
techpack/datarmnet-ext/offload/rmnet_offload.ko
techpack/datarmnet-ext/perf/rmnet_perf.ko
techpack/datarmnet-ext/perf_tether/rmnet_perf_tether.ko
techpack/datarmnet-ext/sch/rmnet_sch.ko
techpack/datarmnet-ext/shs/rmnet_shs.ko
techpack/datarmnet-ext/wlan/rmnet_wlan.ko
techpack/datarmnet/core/rmnet_core.ko
techpack/datarmnet/core/rmnet_ctl.ko
techpack/eva/msm/msm-eva.ko
techpack/video/msm_video.ko
'

alt_need_modules='
drivers/misc/ntsync.ko
'

rm ${OUTPUT_DIR}/*.ko 2>/dev/null
rm ${OUTPUT_DIR}/vendor_boot_modules/*.ko 2>/dev/null
rm ${OUTPUT_DIR}/vendor_dlkm_modules/*.ko 2>/dev/null
rm ${OUTPUT_DIR}/alt_kernel_modules/*.ko 2>/dev/null

strip_kmod() {
	local module=$1
	local output_dir=$2
	local module_file_name

	[ -n "$module" ] || return 1
	if [ ! -f "$module" ]; then
		echo -e "${yellow}! ${module} not found! ${white}"
		return 1
	fi

	module_file_name=$(basename $module)
	case "$module_file_name" in
		"qca6490.ko") module_file_name="qca_cld3_qca6490.ko";;
	esac

	echo "- Stripping $module_file_name ..."
	llvm-strip -S "$module" -o ${output_dir}/${module_file_name}
}

echo "- Finding and stripping all compiled modules..."
find ${KDIR}/out -name "*.ko" | while read -r module; do
	[ -f "$module" ] || continue
	module_file_name=$(basename "$module")
	case "$module_file_name" in
		"qca6490.ko")
			llvm-strip -S "$module" -o ${OUTPUT_DIR}/vendor_boot_modules/qca_cld3_qca6490.ko 2>/dev/null || true
			llvm-strip -S "$module" -o ${OUTPUT_DIR}/vendor_dlkm_modules/qca_cld3_qca6490.ko 2>/dev/null || true
			;;
		"ntsync.ko")
			llvm-strip -S "$module" -o ${OUTPUT_DIR}/alt_kernel_modules/${module_file_name} 2>/dev/null || true
			;;
		*)
			llvm-strip -S "$module" -o ${OUTPUT_DIR}/vendor_boot_modules/${module_file_name} 2>/dev/null || true
			llvm-strip -S "$module" -o ${OUTPUT_DIR}/vendor_dlkm_modules/${module_file_name} 2>/dev/null || true
			;;
	esac
done

t_end=$(date +"%s")
t_diff=$(($t_end - $t_start))

echo -e "$gre << Build completed for ${ksu_variant} in $(($t_diff / 60)) minutes and $(($t_diff % 60)) seconds >> \n $white"

if [ -d ${KDIR}/${DEVICETREE} ] && [ -d ${KDIR}/out/${DEVICETREE} ]; then
	mkdir -p /tmp/devicetree_base
	mkdir -p /tmp/devicetree_techpack
	mkdir -p ${OUTPUT_DIR}/devicetree
	rm ${OUTPUT_DIR}/devicetree/* 2>/dev/null

	# Only keep marble's
	cp ${KDIR}/out/${DEVICETREE}/ukee.dtb /tmp/devicetree_base/ 2>/dev/null || true
	cp ${KDIR}/out/${DEVICETREE}/marble-sm7475-pm8008-overlay.dtbo /tmp/devicetree_base/ 2>/dev/null || true

	for d in \
	    ${KDIR}/out/${DEVICETREE}/audio \
	    ${KDIR}/out/${DEVICETREE}/camera \
	    ${KDIR}/out/${DEVICETREE}/cvp \
	    ${KDIR}/out/${DEVICETREE}/display/display \
	    ${KDIR}/out/${DEVICETREE}/eva \
	    ${KDIR}/out/${DEVICETREE}/mmrm \
	    ${KDIR}/out/${DEVICETREE}/video; do
		if [ -d "$d" ]; then
			mkdir -p /tmp/devicetree_techpack/$(basename $d)
			cp ${d}/*.dtbo /tmp/devicetree_techpack/$(basename $d)/ 2>/dev/null || true
		fi
	done

	echo ""
	echo "Merging dtbs & dtbos..."
	merge_dtbs.py -b /tmp/devicetree_base -t /tmp/devicetree_techpack -o ${OUTPUT_DIR}/devicetree

	echo ""
	echo "- Making dtbo.img ..."
	mkdtboimg.py create ${OUTPUT_DIR}/devicetree/dtbo.img ${OUTPUT_DIR}/devicetree/marble-sm7475-pm8008-overlay.dtbo
	avbtool add_hash_footer --partition_name dtbo --partition_size $((24 * 1024 * 1024)) --image ${OUTPUT_DIR}/devicetree/dtbo.img

	rm -rf /tmp/devicetree_base
	rm -rf /tmp/devicetree_techpack
fi

echo ""
echo "- Done!"
