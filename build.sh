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

