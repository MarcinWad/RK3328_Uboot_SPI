RK3328 NanoPi R2S U-Boot SPI Boot Guide
=======================================

This is a step by step guide on booting the RockChip RK3328 from SPI Flash, by example of NanoPi R2S board from FriendlyElec.

Briefly, the procedure consists of the following steps:

1. Configure and patch files of the mainline U-boot for SPI support
2. Compile U-boot
3. Prepare the SPI Flash image
4. Write the SPI image to the SPI Flash chip
5. Write kernel to the SPI image and boot it

All steps are explained in detail below. Alternatively, steps 1-4 could be executed with a Docker script. Use the following commands to build `idb_finish.img` and copy it back from the Docker container:

```
DOCKER_BUILDKIT=1 docker build -t rk3328-uboot-spi .
bash -c 'docker run --rm -v $(pwd):$(pwd) rk3328-uboot-spi cp /idb_finish.img $(pwd)/'
```

Prerequisites
=============

* AArch64 Toolchain
* SPI Flash chip

<details>
<summary>WARNING: the use of SPI Flash chip larger than 16Mbytes requires additional changes! (Click to show details)</summary>
<br>
An SPI chip which is bigger than 16Mbytes will not let board bootup after software reset (using `reset` in UBoot or `reboot` in Linux). Problem is that >16 Mbytes SPI Flash Chips uses 4-byte addressing instead of 3-byte addressing. 4-byte addressing is being enabled in SPL U-Boot Stage or later in Linux MTD driver. 

After switching to 4-byte addressing, and issuing a reboot, Rockchip BootROM tries to talk to SPI using 3-byte addressing bus which fails and then boot stops in MASKROM mode. It happens only in warm reboot. Cold reboot resets SPI registers and everything is ok.

Second disaster i was fighting with was a situation when connected UART USB was powering board (with USB-C power disconnected) enough to no let SPI registers reset. So i also had problems with cold-reboots when i was diagnosing this situation. Beaware of rockchip lack of documentation and wasted time.

In order to support >16MBytes SPI Flash chip, the following patches must be applied:

* In kernel, source file `drivers/mtd/spi-nor.c`: change from `} else if (mtd->size > 0x1000000) {` to `} else if (mtd->size > 0x2000000) {`
* In U-boot SPL part, source file `drivers/mtd/spi-nor-tiny.c`: change from `} else if (mtd->size > 0x1000000) {` to `} else if (mtd->size > 0x2000000) {`
* In U-boot Payload, source file `drivers/mtd/spi-nor-core.c`: change from `if (nor->addr_width == 3 && mtd->size > SZ_16M) {` to `if (nor->addr_width == 3 && mtd->size > SZ_32M) {`

Note: above will work, but limits access to only first 16Mb of 32Mb SPI Flash.

</details>

Configure and patch files of the mainline U-boot
================================================

1. Download latest U-Boot from https://github.com/u-boot/u-boot and switch into to a some well-working release branch:

```
git clone https://source.denx.de/u-boot/u-boot.git
cd u-boot
git checkout v2023.01
```

2. Compile ARM Trusted Platform for RK3328

```
git clone --depth 1 https://github.com/ARM-software/arm-trusted-firmware.git
cd arm-trusted-firmware
git checkout v2.3
#Patch to make EFUSE work - otherwise you will get all 00000000..... RockChip....
patch -p1 < misc.rk3328/atf-rk3328-efuse-init.patch
make realclean
make CROSS_COMPILE=aarch64-linux-gnu- PLAT=rk3328
cd ..
```

3. Use a defconfig for NanoPi R2S in U-Boot directory

```
make nanopi-r2s-rk3328_defconfig
```

4. The following configurations must be enabled, in order to support SPI Flash and SPI boot:

```
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
```

5. In order to support Rockchip EFUSE, add `{ .compatible = "rockchip,rk3328-efuse" },` to source file `drivers/misc/rockchip-efuse.c`. Otherwise, it will not Boot and hang. Note: EFUSE-provided MAC address will be always the same between boards.
	
6. Add DTS nodes for SPI Flash Controller:

* Edit file `arch/arm/dts/rk3328-nanopi-r2s-u-boot.dtsi`, add at the end:
 
```
&spi0 {
    spi_flash: spiflash@0 {
    	u-boot,dm-pre-reloc;
    };	
};
```

* Edit the same file and add &spi_flash node to boot-order (put it last, if you want to allow recovery from SD card):

```
chosen {
    u-boot,spl-boot-order = "same-as-spl", &sdmmc, &spi_flash;
};
```

* Edit file `arch/arm/dts/rk3328-nanopi-r2s.dts` and add SPI Flash Node:

```
&spi0 {
    status = "okay";

    spiflash@0 {
        compatible = "jedec,spi-nor";
        reg = <0>;

        /* maximum speed for Rockchip SPI */
        spi-max-frequency = <50000000>;
    };
};
```

8. Fix RockChip SPI Driver `drivers/spi/rk_spi.c` and add at the end:

```
DM_DRIVER_ALIAS(rockchip_rk3288_spi, rockchip_rk3328_spi)
```

9. Fix boot device in Uboot RK3328 code:
 
* File `arch/arm/mach-rockchip/rk3328/rk3328.c`, array `boot_devices`: add SPI Boot Device `[BROM_BOOTSOURCE_SPINOR] "/spi@ff190000",`:

```
const char * const boot_devices[BROM_LAST_BOOTSOURCE + 1] = {
    [BROM_BOOTSOURCE_SPINOR] "/spi@ff190000",
    [BROM_BOOTSOURCE_EMMC] = "/mmc@ff520000",
    [BROM_BOOTSOURCE_SD] = "/mmc@ff500000",
};
```

* File `arch/arm/mach-rockchip/spl-boot-order.c`, function `spl_node_to_boot_device`: change last `if` statement:

```
if (!uclass_get_device_by_of_offset(UCLASS_SPI_FLASH, node, &parent))
	return BOOT_DEVICE_SPI;
```

to:

```
if (!uclass_get_device_by_of_offset(UCLASS_SPI, node, &parent))
	return BOOT_DEVICE_SPI;
```  

Compile U-boot
==============

1. Export BL31 variable with ATF binary:

```
export BL31=../arm-trusted-firmware/build/rk3328/release/bl31/bl31.elf
```

2. Compile Uboot:

```
make CROSS_COMPILE=aarch64-linux-gnu- all -j4
```

3. Prepare Initial 1st stage with TPL stage:

```
./tools/mkimage -n rk3328 -T rksd -d tpl/u-boot-tpl.bin idbloader.img
```

4. Compile last Uboot stage:

```
make CROSS_COMPILE=aarch64-linux-gnu- u-boot.itb
```

Prepare the SPI Flash image
===========================

In this section, we will create an RK3328 SPI Flash image, which shall have the following structure:
 
| Offset | Info |
| ------------ | ------------ |
|0x0    | Leave empty as CPU goes to 0x8000 |
|0x8000 | Initial SPL Stage (DDR Init) |
|0x40000 | Uboot ITB Fit Image (Main Uboot) |

Note: SPI Boot on RK3328 starts from offset 0x8000 for both MMC and SPI.

1. Start writing parts of SPI Flash image to `newidb.img`:

```
cat idbloader.img > newidb.img
```

2. Append 2nd SPL Stage after firmware:

```
cat spl/u-boot-spl.bin >> newidb.img
```

3. As Main Uboot starts at offset 0x40000 (with added 0x8000 padding at start), truncate file to this size to not play with offsets (0x40000-0x8000 = 0x38000 = 229376):

```
truncate -s 229376 newidb.img
```

4. Append Main U-Boot to image:

```
cat u-boot.itb >> newidb.img
```

5. Use 32k zero-pad file to make the final image start at offset 0x8000:

```
dd if=/dev/zero of=zero32k.bin bs=32768 count=1
cat zero32k.bin > idb_finish.img
cat newidb.img >> idb_finish.img
```

6. Write `u-boot.itb` again, because on SD card it will be searched for at block 16384:

```
dd if=u-boot.itb of=idb_finish.img bs=512 seek=16384
```

The resulting image is prepared in file `idb_finish.img`.

Write the SPI image to the SPI Flash chip
=========================================

In this section we will write the SPI image to the SPI Flash chip by using the U-boot itself. First, RK3328 will boot from SD card to U-boot, and then we will issue U-boot commands to copy the SPI image to the SPI Flash chip.

1. Write the `idb_finish.img` SPI Flash image to SD card.

2. Boot NanoPi from this SD card. NanoPi should boot to U-boot and show the U-boot command prompt.

3. In the U-boot command prompt, issue the following commands to transfer the image to the SPI chip:

* Check SPI is available: `sf probe`. Should recive something like this:

```
SF: Detected w25q256 with page size 256 Bytes, erase size 4 KiB, total 32 MiB
```

* Erase the first 2Mbytes of SPI:

```
sf erase 0x0 0x200000
```

* Setup the SD card:

```
mmc dev 1
```

* Read first 2Mbytes from SD card into memory at offset 0x300000 

```
mmc read 0x300000 0x0 0x1000
```
	
* Write contents of U-boot from memory to SPI Flash:

```
sf write 0x300000 0x0 0x200000
```

4. Remove SD card, reset the board. You should see something like this:

```
U-Boot TPL 2023.01-rc4 (Dec 21 2022 - 08:37:19)
DDR4, 333MHz
BW=32 Col=10 Bk=4 BG=2 CS0 Row=15 CS=1 Die BW=16 Size=1024MB
Trying to boot from BOOTROM
Returning to boot ROM...

U-Boot SPL 2023.01-rc4 (Dec 21 2022 - 08:37:19 +0100)
Trying to boot from SPI
NOTICE:  BL31: v2.8(release):10f4d1a
NOTICE:  BL31: Built : 10:04:12, Dec  2 2022
NOTICE:  BL31:Rockchip release version: v1.2

U-Boot 2023.01-rc4 (Dec 21 2022 - 08:37:22 +0100)

Model: FriendlyElec NanoPi R2S
DRAM:  1 GiB (effective 1022 MiB)
PMIC:  RK8050 (on=0x40, off=0x00)
Core:  232 devices, 24 uclasses, devicetree: separate
MMC:   mmc@ff500000: 1
Loading Environment from MMC... Card did not respond to voltage select! : -110
*** Warning - No block device, using default environment

In:    serial@ff130000
Out:   serial@ff130000
Err:   serial@ff130000
Model: FriendlyElec NanoPi R2S
Net:   eth0: ethernet@ff540000
Hit any key to stop autoboot:  0
```

Write kernel to the SPI image and boot it
=========================================

Obtaining and compiling the kernel itself is not part of this tutorial. This step presumes an existing kernel is provided. For example, an RK3328 buildroot could be used to compile a minimal `Image.gz` kernel image fitted into FIT Image. The provided [kernel.config](kernel.config) builds a ~5Mbytes kernel with options to boot from SPI an use it as RootFS. After building the image, you will get `Image.gz` and SquashFS rootfs image.

The following layout presents the possible address ranges ("Bootloader" incorporates the SPI Flash image discussed in previous steps):

| Offset | Size | Info |
| ------------ | ------------ | ------------ |
|0x0	| 0x200000 | Bootloader |
|0x200000 | 0x500000 |  Kernel |
|0x700000 | 0x500000 | RootFS |
|0xc00000 | 0x100000 | JFFS2 Read Write partition |

This layout corresponds to the following in the U-boot compilation process:

```
defaults:
mtdids  : nor0=w25q256
mtdparts: mtdparts=w25q256:0x200000(U-Boot),0x500000(Kernel),0x500000(RootFS),0x100000(Data)-(Unused)
```

1. Make kernel image from the target `Image.sz` kernel image, and the provided [rk3328-nanopi-r2-rev03.dts](rk3328-nanopi-r2-rev03.dts) and [fit-image.its](fit-image.its). Place all 3 files in the same directory and run:

```
mkimage -f fit-image.its kernel.itb
```

The file `kernel.itb` is an image that we will be written to SPI memory.

2. Prepare rootfs image

3. Setup a TFTP server in same subnet and flash the components using the U-boot command prompt:

* Flash the kernel to SPI:

```
tftp 0x300000 kernel.itb
sf erase 0x200000 0x500000
sf write 0x300000 0x200000 $filesize
```

* Flash rootfs to SPI:

```
tftp 0x300000 rootfs.squashfs
sf erase 0x700000 0x500000
sf write 0x300000 0x700000 $filesize
```

4. Setup env settings to active the kernel boot by running the following in U-boot command prompt:

```
setenv bootargs earlycon=uart8250,mmio32,0xff130000 console=ttyFIQ0 mtdparts=spi0.0:0x200000(U-Boot),0x500000(Kernel),0x500000(Rootfs),0x100000(Data),-(Unused)  rootfstype=squashfs root=/dev/mtdblock2
setenv bootcmd "sf probe; sf read 0x400000 0x200000 0x500000; bootm 0x400000"
saveenv
```

5. Reboot. The board should boot the kernel.

