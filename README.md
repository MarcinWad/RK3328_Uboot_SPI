
RK3328 NanoPi R2S U-Boot SPI Tutorial
=========================================
This is a tutorial for compiling MainLine U-Boot for RockChip RK3328 with ability to boot from SPI Flash based on NanoPI R2S board from FriendlyElec.

I've lost a lot of hours trying to figure out how to do this using many articles. All of them wasn't successfull. Hope it helps for 

Warning!!!!!!
==============
Soldering a SPI chip which is bigger than 16Mbytes will not let board bootup after software reset (using reset in UBoot or reboot in Linux)

I lost about two weeks finding that BOOTROM limitation in RockCHIP. Problem is that >16 Mbytes SPI Flash Chips uses 4-byte addressing instead of 3-byte addressing.
4-byte addressing is being enabled in SPL U-Boot Stage or later in Linux MTD driver. 

After switching to 4-byte addressing, and issuing a reboot, RochChhip BootROM tries to talk to SPI using 3-byte addressing bus which fails and then boot stops in MASKROM mode. It happens only in warm reboot. Cold reboot resets SPI registers and everything is ok.

Second disaster i was fighting with was a situation when connected UART USB was powering board (with USB-C power disconnected) enough to no let SPI registers reset. So i also had problems with cold-reboots when i was diagnosing this situation. Beaware of rockchip lack of documentation and wasted time.

I will leave this information for everybody so nobody will spend almost 2 weeks in figuring this out by himself. 


SPI Boot procedure
===============

1. Get AArch64 Toolchain

2. Download latest U-Boot from https://github.com/u-boot/u-boot
  ```
  git clone --depth 1 https://source.denx.de/u-boot/u-boot.git
  cd u-boot
  ```

3. Compile ARM Trusted Platform for RK3328
  ```
  git clone --depth 1 https://github.com/ARM-software/arm-trusted-firmware.git
  cd arm-trusted-firmware
  make realclean
  make CROSS_COMPILE=aarch64-linux-gnu- PLAT=rk3399
  cd ..
  ```

4. Use a defconfig for NanoPi R2S in U-Boot directory

    ```make nanopi-r2s-rk3328_defconfig```

5. You can modify config for your needs or use below changes in configuration to enable all support for booting and supporting SPI FLASH.

   ```
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
    CONFIG_ROCKCHIP_SPI=y```

6. SPI Boot on RK3328 from MMC and SPI (!!!) starts from offset 0x8000 so we will create a padding zero byte file for further use:
  
	``dd if=/dev/zero of=zero32k.bin bs=32768 count=1``
     
7. Add DTS nodes for SPI Flash Controller:
      
	Edit file ``arch/arm/dts/rk3328-nanopi-r2s-u-boot.dtsi`` add at the end:
 
    ```
    &spi0 {
    	spi_flash: spiflash@0 {
    		u-boot,dm-pre-reloc;
    	};	
    };
    ```

	Edit the same file and add &spi0 node to boot-order:
	```
        chosen {
			u-boot,spl-boot-order = "same-as-spl", &spi0, &sdmmc;
		};
    ```
        
	Edit file ``arch/arm/dts/rk3328-nanopi-r2s.dts`` and add SPI Flash Node:
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
 8. Fix RockChip SPI Driver ``drivers/spi/rk_spi.c`` and add at the end:
	```DM_DRIVER_ALIAS(rockchip_rk3288_spi, rockchip_rk3328_spi);```
    
 9. Fix boot device in Uboot RK3328 code:
 
 	file: ``arch/arm/mach-rockchip/rk3328/rk3328.c``
    
    Function ``boot_devices`` add SPI Boot Device ``[BROM_BOOTSOURCE_SPINOR] "/spi@ff190000",``
    ```
    const char * const boot_devices[BROM_LAST_BOOTSOURCE + 1] = {
      [BROM_BOOTSOURCE_SPINOR] "/spi@ff190000",
      [BROM_BOOTSOURCE_EMMC] = "/mmc@ff520000",
      [BROM_BOOTSOURCE_SD] = "/mmc@ff500000",
	};
    ```
    
    file: ``arch/arm/mach-rockchip/spl-boot-order.c``
    
    Function ``spl_node_to_boot_device`` 
    
    Change last ``if`` statement:
    ```
    if (!uclass_get_device_by_of_offset(UCLASS_SPI_FLASH, node, &parent))
		return BOOT_DEVICE_SPI;
	```
    to:
     ```
    if (!uclass_get_device_by_of_offset(UCLASS_SPI, node, &parent))
		return BOOT_DEVICE_SPI;
	```  
10. Final image structure for RK3328 to flash to SPI

	| Offset | Info |
    | ------------ | ------------ |
    |0x0	| Leave empty as CPU goes to 0x8000 |
    |0x8000 | Initial SPL Stage (DDR Init) |
    |0x40000 | Uboot ITB Fit Image (Main Uboot) |

11. Now it's time to compile Uboot:

	Export BL31 variable with ATF binary:
    
	``export BL31=../arm-trusted-firmware/build/rk3328/release/bl31/bl31.elf``
    
    Compile Uboot:
    
	``make CROSS_COMPILE=aarch64-linux-gnu- all -j4``
    
    Prepare Initial 1st stage with TPL stage:
    
    ``./tools/mkimage -n rk3328 -T rksd -d tpl/u-boot-tpl.bin idbloader.img``
    
    Now create image for burning to MMC and later SPI Flash:
    
    ``cat idbloader.img > newidb.img``
    
    Append 2nd SPL Stage after firmware:
    
	``cat spl/u-boot-spl.bin >> newidb.img``
    
    As Main Uboot starts at offset 0x40000 (with added 0x8000 padding at start), truncate file to this size to not play with offsets (0x40000-0x8000 = 0x38000 = 229376).
    
	``truncate -s 229376 newidb.img``
    
    Compile last Uboot stage:
    
	``make CROSS_COMPILE=aarch64-linux-gnu- u-boot.itb``
    
    Append Main U-Boot to image:
    
	``cat u-boot.itb >> newidb.img``
    
    Use 32k zero-pad file to make final image starts at offset 0x8000
    
	``cat zero32k.bin > idb_finish.img``
    
    Append created RockChip image to MMC/SPI file to be written directly
    
	``cat newidb.img >> idb_finish.img``
12. Now write this image ``idb_finish.img`` to MMC card and boot NanoPi with this card.
	
    When it boots fine, issue following commands to transfer this image to SPI:
    
    Check SPI is available:
	``sf probe``
    
    should recive something like this:
    
    ``SF: Detected w25q256 with page size 256 Bytes, erase size 4 KiB, total 32 MiB``
    
    Erase SPI at the first 2Mbytes:
    
	``sf erase 0x0 0x200000``
    
    Setup MMC card:
    
	``mmc dev 1``
    
    Read first 2Mbytes from SD card into memory at offset 0x300000 
    
	``mmc read 0x300000 0x0 0x1000 ``
	
    Write contents of Uboot from memory to SPI Flash:
    
    ``sf write 0x300000 0x0 0x200000 ``

	Remove card, reset the board. You should see something like this:
    
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
