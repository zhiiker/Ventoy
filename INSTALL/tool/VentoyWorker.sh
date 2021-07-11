#!/bin/sh

. ./tool/ventoy_lib.sh

print_usage() {
    
    echo 'Usage:  Ventoy2Disk.sh CMD [ OPTION ] /dev/sdX'
    echo '  CMD:'
    echo '   -i  install Ventoy to sdX (fails if disk already installed with Ventoy)'
    echo '   -I  force install Ventoy to sdX (no matter installed or not)'
    echo '   -u  update Ventoy in sdX'
    echo '   -l  list Ventoy information in sdX'
    echo ''
    echo '  OPTION: (optional)'
    echo '   -r SIZE_MB  preserve some space at the bottom of the disk (only for install)'
    echo '   -s/-S       enable/disable secure boot support (default is disabled)'
    echo '   -g          use GPT partition style, default is MBR (only for install)'
    echo '   -L          Label of the 1st exfat partition (default is Ventoy)'
    echo ''
}


VTNEW_LABEL='Ventoy'
RESERVE_SIZE_MB=0
while [ -n "$1" ]; do
    if [ "$1" = "-i" ]; then
        MODE="install"
    elif [ "$1" = "-I" ]; then
        MODE="install"
        FORCE="Y"
    elif [ "$1" = "-u" ]; then
        MODE="update"
    elif [ "$1" = "-l" ]; then
        MODE="list"
    elif [ "$1" = "-s" ]; then
        SECUREBOOT="YES"
    elif [ "$1" = "-S" ]; then
        SECUREBOOT="NO"
    elif [ "$1" = "-g" ]; then
        VTGPT="YES"
    elif [ "$1" = "-L" ]; then
        shift
        VTNEW_LABEL=$1
    elif [ "$1" = "-r" ]; then
        RESERVE_SPACE="YES"
        shift
        RESERVE_SIZE_MB=$1
    elif [ "$1" = "-V" ] || [ "$1" = "--version" ]; then
        exit 0
    elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        print_usage
        exit 0
    else
        if ! [ -b "$1" ]; then
            vterr "$1 is NOT a valid device"
            print_usage
            exit 1
        fi
        DISK=$1
    fi
    
    shift
done

if [ -z "$MODE" ]; then
    print_usage
    exit 1
fi

if ! [ -b "$DISK" ]; then
    vterr "Disk $DISK does not exist"
    exit 1
fi

if [ -e /sys/class/block/${DISK#/dev/}/start ]; then
    vterr  "$DISK is a partition, please use the whole disk."
    echo   "For example:"
    vterr  "    sudo sh Ventoy2Disk.sh -i /dev/sdb1 <=== This is wrong"
    vtinfo "    sudo sh Ventoy2Disk.sh -i /dev/sdb  <=== This is right"
    echo ""
    exit 1
fi

if [ -n "$RESERVE_SPACE" -a "$MODE" = "install" ]; then
    if echo $RESERVE_SIZE_MB | grep -q '^[0-9][0-9]*$'; then
        vtdebug "User will reserve $RESERVE_SIZE_MB MB disk space"
    else
        vterr "$RESERVE_SIZE_MB is invalid for reserved space"
        exit 1
    fi
fi

vtdebug "MODE=$MODE FORCE=$FORCE RESERVE_SPACE=$RESERVE_SPACE RESERVE_SIZE_MB=$RESERVE_SIZE_MB"

#check tools
if check_tool_work_ok; then
    vtdebug "check tool work ok"
else
    vterr "Some tools can not run on current system. Please check log.txt for details."
    exit 1
fi

if [ "$MODE" = "list" ]; then
    version=$(get_disk_ventoy_version $DISK)
    if [ $? -eq 0 ]; then
        echo "Ventoy Version in Disk: $version"
        
        vtPart1Type=$(dd if=$DISK bs=1 count=1 skip=450 status=none | hexdump -n1 -e  '1/1 "%02X"')
        if [ "$vtPart1Type" = "EE" ]; then            
            echo "Disk Partition Style  : GPT"
        else
            echo "Disk Partition Style  : MBR"
        fi
        
        if check_disk_secure_boot $DISK; then
            echo "Secure Boot Support   : YES"
        else
            echo "Secure Boot Support   : NO"
        fi        
    else
        echo "Ventoy Version: NA"
    fi
    echo ""
    exit 0
fi

#check mountpoint
check_umount_disk "$DISK"

if grep "$DISK" /proc/mounts; then
    vterr "$DISK is already mounted, please umount it first!"
    exit 1
fi

#check swap partition
if swapon --help 2>&1 | grep -q '^ \-s,'; then
    if swapon -s | grep -q "^${DISK}[0-9]"; then
        vterr "$DISK is used as swap, please swapoff it first!"
        exit 1
    fi
fi

#check access 
if dd if="$DISK" of=/dev/null bs=1 count=1 >/dev/null 2>&1; then
    vtdebug "root permission check ok ..."
else
    vterr "Failed to access $DISK, maybe root privilege is needed!"
    echo ''
    exit 1
fi


#check tmp_mnt directory
if [ -d ./tmp_mnt ]; then
    vtdebug "There is a tmp_mnt directory, now delete it."
    umount ./tmp_mnt >/dev/null 2>&1
    rm -rf ./tmp_mnt
    if [ -d ./tmp_mnt ]; then
        vterr "tmp_mnt directory exits, please delete it first."
        exit 1
    fi
fi


if [ "$MODE" = "install" ]; then
    vtdebug "install Ventoy ..."

    if [ -n "$VTGPT" ]; then
        if parted -v > /dev/null 2>&1; then
            PARTTOOL='parted'
        else
            vterr "parted is not found in the system, Ventoy can't create new partitions without it."
            vterr "You should install \"GNU parted\" first."
            exit 1
        fi
    else
        if parted -v > /dev/null 2>&1; then
            PARTTOOL='parted'
        elif fdisk -v >/dev/null 2>&1; then
            PARTTOOL='fdisk'
        else
            vterr "Both parted and fdisk are not found in the system, Ventoy can't create new partitions."
            exit 1
        fi
    fi
    
    version=$(get_disk_ventoy_version $DISK)
    if [ $? -eq 0 ]; then
        if [ -z "$FORCE" ]; then
            vtwarn "$DISK already contains a Ventoy with version $version"
            vtwarn "Use -u option to do a safe upgrade operation."
            vtwarn "OR if you really want to reinstall Ventoy to $DISK, please use -I option."
            vtwarn ""
            exit 1
        fi
    fi
    
    disk_sector_num=$(cat /sys/block/${DISK#/dev/}/size)
    disk_size_gb=$(expr $disk_sector_num / 2097152)

    if [ $disk_sector_num -gt 4294967296 ] && [ -z "$VTGPT" ]; then
        vterr "$DISK is over 2TB size, MBR will not work on it."
        exit 1
    fi

    if [ -n "$RESERVE_SPACE" ]; then
        sum_size_mb=$(expr $RESERVE_SIZE_MB + $VENTOY_PART_SIZE_MB)
        reserve_sector_num=$(expr $sum_size_mb \* 2048)
        
        if [ $disk_sector_num -le $reserve_sector_num ]; then
            vterr "Can't reserve $RESERVE_SIZE_MB MB space from $DISK"
            exit 1
        fi
    fi

    #Print disk info
    echo "Disk : $DISK"
    parted -s $DISK p 2>&1 | grep Model
    echo "Size : $disk_size_gb GB"    
    if [ -n "$VTGPT" ]; then
        echo "Style: GPT"
    else
        echo "Style: MBR"
    fi    
    echo ''

    if [ -n "$RESERVE_SPACE" ]; then
        echo "You will reserve $RESERVE_SIZE_MB MB disk space "
    fi
    echo ''

    vtwarn "Attention:"
    vtwarn "You will install Ventoy to $DISK."
    vtwarn "All the data on the disk $DISK will be lost!!!"
    echo ""

    read -p 'Continue? (y/n) '  Answer
    if [ "$Answer" != "y" ]; then
        if [ "$Answer" != "Y" ]; then
            exit 0
        fi
    fi

    echo ""
    vtwarn "All the data on the disk $DISK will be lost!!!"
    read -p 'Double-check. Continue? (y/n) '  Answer
    if [ "$Answer" != "y" ]; then
        if [ "$Answer" != "Y" ]; then
            exit 0
        fi
    fi

    if [ $disk_sector_num -le $VENTOY_SECTOR_NUM ]; then  
        vterr "No enough space in disk $DISK"
        exit 1
    fi

    if ! dd if=/dev/zero of=$DISK bs=1 count=512 status=none conv=fsync; then
        vterr "Write data to $DISK failed, please check whether it's in use."
        exit 1
    fi

    if [ -n "$VTGPT" ]; then
        vtdebug "format_ventoy_disk_gpt $RESERVE_SIZE_MB $DISK $PARTTOOL ..."
        format_ventoy_disk_gpt $RESERVE_SIZE_MB $DISK $PARTTOOL
    else
        vtdebug "format_ventoy_disk_mbr $RESERVE_SIZE_MB $DISK $PARTTOOL ..."
        format_ventoy_disk_mbr $RESERVE_SIZE_MB $DISK $PARTTOOL
    fi

    # format part1

    # DiskSize > 32GB  Cluster Size use 128KB
    # DiskSize < 32GB  Cluster Size use 32KB
    if [ $disk_size_gb -gt 32 ]; then
        cluster_sectors=256
    else
        cluster_sectors=64
    fi

    PART1=$(get_disk_part_name $DISK 1)  
    PART2=$(get_disk_part_name $DISK 2)  

    mkexfatfs -n "$VTNEW_LABEL" -s $cluster_sectors ${PART1}

    vtinfo "writing data to disk ..."
    
    dd status=none conv=fsync if=./boot/boot.img of=$DISK bs=1 count=446
    
    if [ -n "$VTGPT" ]; then
        echo -en '\x22' | dd status=none of=$DISK conv=fsync bs=1 count=1 seek=92        
        xzcat ./boot/core.img.xz | dd status=none conv=fsync of=$DISK bs=512 count=2014 seek=34
        echo -en '\x23' | dd of=$DISK conv=fsync bs=1 count=1 seek=17908 status=none
    else
        xzcat ./boot/core.img.xz | dd status=none conv=fsync of=$DISK bs=512 count=2047 seek=1
    fi
    
    # check and umount
    check_umount_disk "$DISK"
    
    xzcat ./ventoy/ventoy.disk.img.xz | dd status=none conv=fsync of=$DISK bs=512 count=$VENTOY_SECTOR_NUM seek=$part2_start_sector
    
    #test UUID
    testUUIDStr=$(vtoy_gen_uuid | hexdump -C)
    vtdebug "test uuid: $testUUIDStr"
    
    #disk uuid
    vtoy_gen_uuid | dd status=none conv=fsync of=${DISK} seek=384 bs=1 count=16
    
    #disk signature
    vtoy_gen_uuid | dd status=none conv=fsync of=${DISK} skip=12 seek=440 bs=1 count=4

    vtinfo "sync data ..."
    sync
    
    vtinfo "esp partition processing ..."
    
    sleep 1
    check_umount_disk "$DISK"    
    
    if [ "$SECUREBOOT" != "YES" ]; then        
        mkdir ./tmp_mnt
        
        vtdebug "mounting part2 ...."
        for tt in 1 2 3 4 5; do            
            if mount ${PART2} ./tmp_mnt > /dev/null 2>&1; then
                vtdebug "mounting part2 success"
                break
            fi
            
            check_umount_disk "$DISK"            
            sleep 2
        done
        
        rm -f ./tmp_mnt/EFI/BOOT/BOOTX64.EFI
        rm -f ./tmp_mnt/EFI/BOOT/grubx64.efi
        rm -f ./tmp_mnt/EFI/BOOT/BOOTIA32.EFI
        rm -f ./tmp_mnt/EFI/BOOT/grubia32.efi
        rm -f ./tmp_mnt/EFI/BOOT/MokManager.efi
        rm -f ./tmp_mnt/EFI/BOOT/mmia32.efi
        rm -f ./tmp_mnt/ENROLL_THIS_KEY_IN_MOKMANAGER.cer
        mv ./tmp_mnt/EFI/BOOT/grubx64_real.efi  ./tmp_mnt/EFI/BOOT/BOOTX64.EFI
        mv ./tmp_mnt/EFI/BOOT/grubia32_real.efi  ./tmp_mnt/EFI/BOOT/BOOTIA32.EFI
        
        sync
        
        for tt in 1 2 3; do
            if umount ./tmp_mnt; then
                vtdebug "umount part2 success"
                rm -rf ./tmp_mnt
                break
            else
                vtdebug "umount part2 failed, now retry..."
                sleep 1
            fi
        done
    fi

    echo ""
    vtinfo "Install Ventoy to $DISK successfully finished."
    echo ""
    
else
    vtdebug "update Ventoy ..."
    
    oldver=$(get_disk_ventoy_version $DISK)
    if [ $? -ne 0 ]; then
        if is_disk_contains_ventoy $DISK; then
            oldver="Unknown"
        else
            vtwarn "$DISK does not contain Ventoy or data corrupted"
            echo ""
            vtwarn "Please use -i option if you want to install ventoy to $DISK"
            echo ""
            exit 1
        fi
    fi

    #reserve secure boot option
    if [ -z "$SECUREBOOT" ]; then
        if check_disk_secure_boot $DISK; then
            SECUREBOOT="YES"
        else
            SECUREBOOT="NO"
        fi
    fi

    curver=$(cat ./ventoy/version)

    vtinfo "Upgrade operation is safe, all the data in the 1st partition (iso files and other) will be unchanged!"
    echo ""

    read -p "Update Ventoy  $oldver ===> $curver   Continue? (y/n)"  Answer
    if [ "$Answer" != "y" ]; then
        if [ "$Answer" != "Y" ]; then
            exit 0
        fi
    fi

    PART2=$(get_disk_part_name $DISK 2)
    SHORT_PART2=${PART2#/dev/}
    part2_start=$(cat /sys/class/block/$SHORT_PART2/start)
    
    PART1_TYPE=$(dd if=$DISK bs=1 count=1 skip=450 status=none | hexdump -n1 -e  '1/1 "%02X"')
    
    #reserve disk uuid
    rm -f ./diskuuid.bin
    dd status=none conv=fsync if=${DISK} skip=384 bs=1 count=16 of=./diskuuid.bin
    
    dd status=none conv=fsync if=./boot/boot.img of=$DISK bs=1 count=440
    dd status=none conv=fsync if=./diskuuid.bin of=$DISK bs=1 count=16 seek=384
    rm -f ./diskuuid.bin

    #reserve data
    rm -f ./rsvdata.bin
    dd status=none conv=fsync if=${DISK} skip=2040 bs=512 count=8 of=./rsvdata.bin

    if [ "$PART1_TYPE" = "EE" ]; then
        vtdebug "This is GPT partition style ..."    
        echo -en '\x22' | dd status=none of=$DISK conv=fsync bs=1 count=1 seek=92
        xzcat ./boot/core.img.xz | dd status=none conv=fsync of=$DISK bs=512 count=2014 seek=34
        echo -en '\x23' | dd of=$DISK conv=fsync bs=1 count=1 seek=17908 status=none
    else
        vtdebug "This is MBR partition style ..."
    
        PART1_ACTIVE=$(dd if=$DISK bs=1 count=1 skip=446 status=none | hexdump -n1 -e  '1/1 "%02X"')
        PART2_ACTIVE=$(dd if=$DISK bs=1 count=1 skip=462 status=none | hexdump -n1 -e  '1/1 "%02X"')
        
        vtdebug "PART1_ACTIVE=$PART1_ACTIVE  PART2_ACTIVE=$PART2_ACTIVE"
        if [ "$PART1_ACTIVE" = "00" ] && [ "$PART2_ACTIVE" = "80" ]; then
            vtdebug "change 1st partition active, 2nd partition inactive ..."
            echo -en '\x80' | dd of=$DISK conv=fsync bs=1 count=1 seek=446 status=none
            echo -en '\x00' | dd of=$DISK conv=fsync bs=1 count=1 seek=462 status=none
        fi
        xzcat ./boot/core.img.xz | dd status=none conv=fsync of=$DISK bs=512 count=2047 seek=1
    fi

    dd status=none conv=fsync if=./rsvdata.bin seek=2040 bs=512 count=8 of=${DISK}
    rm -f ./rsvdata.bin

    check_umount_disk "$DISK"
    
    xzcat ./ventoy/ventoy.disk.img.xz | dd status=none conv=fsync of=$DISK bs=512 count=$VENTOY_SECTOR_NUM seek=$part2_start

    sync

    if [ "$SECUREBOOT" != "YES" ]; then
        mkdir ./tmp_mnt
        
        vtdebug "mounting part2 ...."        
        for tt in 1 2 3 4 5; do
            check_umount_disk "$DISK"

            if mount ${PART2} ./tmp_mnt > /dev/null 2>&1; then
                vtdebug "mounting part2 success"
                break
            else
                vtdebug "mounting part2 failed, now wait and retry..."
            fi
            sleep 2            
        done
        
        rm -f ./tmp_mnt/EFI/BOOT/BOOTX64.EFI
        rm -f ./tmp_mnt/EFI/BOOT/grubx64.efi
        rm -f ./tmp_mnt/EFI/BOOT/BOOTIA32.EFI
        rm -f ./tmp_mnt/EFI/BOOT/grubia32.efi
        rm -f ./tmp_mnt/EFI/BOOT/MokManager.efi
        rm -f ./tmp_mnt/EFI/BOOT/mmia32.efi
        rm -f ./tmp_mnt/ENROLL_THIS_KEY_IN_MOKMANAGER.cer
        mv ./tmp_mnt/EFI/BOOT/grubx64_real.efi  ./tmp_mnt/EFI/BOOT/BOOTX64.EFI
        mv ./tmp_mnt/EFI/BOOT/grubia32_real.efi  ./tmp_mnt/EFI/BOOT/BOOTIA32.EFI
        
        sync
        
        for tt in 1 2 3; do
            if umount ./tmp_mnt > /dev/null 2>&1; then
                vtdebug "umount part2 success"
                rm -rf ./tmp_mnt
                break
            else
                vtdebug "umount part2 failed, now retry..."
                sleep 1
            fi
        done        
    fi

    echo ""
    vtinfo "Update Ventoy on $DISK successfully finished."
    echo ""
    
fi


