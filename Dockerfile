# syntax = docker/dockerfile:1.4.0

FROM ubuntu:22.04 as toolchain

ENV DEBIAN_FRONTEND noninteractive

RUN apt update && \
    apt install --no-install-recommends -y \
        build-essential \
        gcc-aarch64-linux-gnu \
        make \
        git \
        ca-certificates \
        patch \
        bison \
        flex \
        python3 \
        python3-setuptools \
        python3-pyelftools \
        libpython3-dev \
        swig \
        libssl-dev \
        bc \
        device-tree-compiler

###############################################################################

FROM toolchain as trust

COPY ./atf-rk3328-efuse-init.patch /

RUN git clone https://github.com/ARM-software/arm-trusted-firmware.git

WORKDIR /arm-trusted-firmware

RUN git checkout v2.3 && \
    patch -p1 < /atf-rk3328-efuse-init.patch && \
    make realclean && \
    make CROSS_COMPILE=aarch64-linux-gnu- PLAT=rk3328

###############################################################################

FROM toolchain as u-boot

RUN git clone https://source.denx.de/u-boot/u-boot.git

WORKDIR /u-boot

RUN git checkout v2023.01 && \
    make nanopi-r2s-rk3328_defconfig

RUN <<EOF cat >> .config_extra
CONFIG_ROCKCHIP_EFUSE=y
CONFIG_ENV_SIZE=0x2000
CONFIG_ENV_OFFSET=0x140000
CONFIG_ENV_SECT_SIZE=0x2000
CONFIG_SPL_SPI_FLASH_SUPPORT=y
CONFIG_SPL_SPI=y
CONFIG_ENV_ADDR=0x0
CONFIG_SPI_BOOT=y
CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=0x200
CONFIG_SPL_MTD_SUPPORT=y
CONFIG_SPL_SPI_FLASH_TINY=y
CONFIG_SPL_SPI_FLASH_MTD=y
CONFIG_SPL_SPI_LOAD=y
CONFIG_SYS_SPI_U_BOOT_OFFS=0x40000
CONFIG_CMD_FLASH=y
CONFIG_ENV_IS_IN_SPI_FLASH=y
CONFIG_ENV_SPI_BUS=0
CONFIG_ENV_SPI_CS=0
CONFIG_ENV_SPI_MAX_HZ=20000000
CONFIG_ENV_SPI_MODE=0x0
CONFIG_MTD=y
CONFIG_DM_MTD=y
CONFIG_SPI_FLASH_WINBOND=y
CONFIG_SPI_FLASH_MTD=y
CONFIG_ROCKCHIP_SPI=y
EOF

RUN cat .config_extra | sed 's|=.*|=|' | xargs -I{} sed -i 's|{}.*||' .config

RUN cat .config_extra >> .config

RUN <<EOF cat >> arch/arm/dts/rk3328-nanopi-r2s-u-boot.dtsi
&spi0 {
    spi_flash: spiflash@0 {
    	u-boot,dm-pre-reloc;
    };	
};
EOF

RUN sed -i.bak 's|u-boot,spl-boot-order = "same-as-spl", &sdmmc, &emmc;|u-boot,spl-boot-order = "same-as-spl", \&sdmmc, \&spi_flash;|' \
    arch/arm/dts/rk3328-nanopi-r2s-u-boot.dtsi && (! diff arch/arm/dts/rk3328-nanopi-r2s-u-boot.dtsi arch/arm/dts/rk3328-nanopi-r2s-u-boot.dtsi.bak &> /dev/null)

RUN <<EOF cat >> arch/arm/dts/rk3328-nanopi-r2s.dts
&spi0 {
    status = "okay";

    spiflash@0 {
        compatible = "jedec,spi-nor";
        reg = <0>;

        /* maximum speed for Rockchip SPI */
        spi-max-frequency = <50000000>;
    };
};
EOF

RUN <<EOF cat >> drivers/spi/rk_spi.c
DM_DRIVER_ALIAS(rockchip_rk3288_spi, rockchip_rk3328_spi)
EOF

RUN sed -i.bak 's|\[BROM_BOOTSOURCE_EMMC\] = "/mmc@ff520000",|[BROM_BOOTSOURCE_SPINOR] "/spi@ff190000", [BROM_BOOTSOURCE_EMMC] = "/mmc@ff520000",|' \
    arch/arm/mach-rockchip/rk3328/rk3328.c && (! diff arch/arm/mach-rockchip/rk3328/rk3328.c arch/arm/mach-rockchip/rk3328/rk3328.c.bak)

RUN sed -i.bak 's|uclass_get_device_by_of_offset(UCLASS_SPI_FLASH|uclass_get_device_by_of_offset(UCLASS_SPI|g' \
    arch/arm/mach-rockchip/spl-boot-order.c && (! diff arch/arm/mach-rockchip/spl-boot-order.c arch/arm/mach-rockchip/spl-boot-order.c.bak)

COPY --from=trust /arm-trusted-firmware/build/rk3328/release/bl31/bl31.elf /

#RUN sleep infinity

RUN BL31=/bl31.elf make CROSS_COMPILE=aarch64-linux-gnu- all -j4

RUN ./tools/mkimage -n rk3328 -T rksd -d tpl/u-boot-tpl.bin idbloader.img

# Uncomment this to enable debug logging in U-Boot final stage:
#RUN <<EOF cat >> .config
#CONFIG_LOG=y
#CONFIG_LOGLEVEL=10
#EOF
#COPY uboot_debug.patch /uboot_debug.patch
#RUN patch -p1 < /uboot_debug.patch

RUN BL31=/bl31.elf make CROSS_COMPILE=aarch64-linux-gnu- u-boot.itb

###############################################################################

FROM ubuntu:22.04

COPY --from=u-boot /u-boot/idbloader.img /
COPY --from=u-boot /u-boot/spl/u-boot-spl.bin /
COPY --from=u-boot /u-boot/u-boot.itb /

# Note: we write u-boot.itb twice, because on SD card
# it will be searched for at block 16384
RUN \
    cat idbloader.img > newidb.img && \
    cat u-boot-spl.bin >> newidb.img && \
    truncate -s 229376 newidb.img && \
    cat u-boot.itb >> newidb.img && \
    dd if=/dev/zero of=zero32k.bin bs=32768 count=1 && \
    cat zero32k.bin > idb_finish.img && \
    cat newidb.img >> idb_finish.img && \
    dd if=u-boot.itb of=idb_finish.img bs=512 seek=16384
