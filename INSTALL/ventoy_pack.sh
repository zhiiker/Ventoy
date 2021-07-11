#!/bin/sh

if [ "$1" = "CI" ]; then
    OPT='-dR'
else
    OPT='-a'
fi

dos2unix -q ./tool/ventoy_lib.sh
dos2unix -q ./tool/VentoyWorker.sh
dos2unix -q ./tool/WebDeepin.sh
dos2unix -q ./tool/WebUos.sh

. ./tool/ventoy_lib.sh

GRUB_DIR=../GRUB2/INSTALL
LANG_DIR=../LANGUAGES

if ! [ -d $GRUB_DIR ]; then
    echo "$GRUB_DIR not exist"
    exit 1
fi


cd ../IMG
sh mkcpio.sh
sh mkloopex.sh
cd -

cd ../Unix
sh pack_unix.sh
cd -

cd ../LinuxGUI
sh language.sh || exit 1
sh build.sh
cd -


LOOP=$(losetup -f)

rm -f img.bin
dd if=/dev/zero of=img.bin bs=1M count=256 status=none

losetup -P $LOOP img.bin 

while ! grep -q 524288 /sys/block/${LOOP#/dev/}/size 2>/dev/null; do
    echo "wait $LOOP ..."
    sleep 1
done

format_ventoy_disk_mbr 0 $LOOP fdisk

$GRUB_DIR/sbin/grub-bios-setup  --skip-fs-probe  --directory="./grub/i386-pc"  $LOOP

curver=$(get_ventoy_version_from_cfg ./grub/grub.cfg)

tmpmnt=./ventoy-${curver}-mnt
tmpdir=./ventoy-${curver}

rm -rf $tmpmnt
mkdir -p $tmpmnt

mount ${LOOP}p2  $tmpmnt 

mkdir -p $tmpmnt/grub

# First copy grub.cfg file, to make it locate at front of the part2
cp $OPT ./grub/grub.cfg     $tmpmnt/grub/

ls -1 ./grub/ | grep -v 'grub\.cfg' | while read line; do
    cp $OPT ./grub/$line $tmpmnt/grub/
done

cp $OPT ./ventoy   $tmpmnt/
cp $OPT ./EFI   $tmpmnt/
cp $OPT ./tool/ENROLL_THIS_KEY_IN_MOKMANAGER.cer $tmpmnt/


mkdir -p $tmpmnt/tool
cp $OPT ./tool/i386/mount.exfat-fuse     $tmpmnt/tool/mount.exfat-fuse_i386
cp $OPT ./tool/x86_64/mount.exfat-fuse   $tmpmnt/tool/mount.exfat-fuse_x86_64
cp $OPT ./tool/aarch64/mount.exfat-fuse  $tmpmnt/tool/mount.exfat-fuse_aarch64


rm -f $tmpmnt/grub/i386-pc/*.img


umount $tmpmnt && rm -rf $tmpmnt


rm -rf $tmpdir
mkdir -p $tmpdir/boot
mkdir -p $tmpdir/ventoy
echo $curver > $tmpdir/ventoy/version
dd if=$LOOP of=$tmpdir/boot/boot.img bs=1 count=512  status=none
dd if=$LOOP of=$tmpdir/boot/core.img bs=512 count=2047 skip=1 status=none
xz --check=crc32 $tmpdir/boot/core.img

cp $OPT ./tool $tmpdir/
rm -f $tmpdir/ENROLL_THIS_KEY_IN_MOKMANAGER.cer
cp $OPT Ventoy2Disk.sh $tmpdir/
cp $OPT VentoyWeb.sh $tmpdir/
cp $OPT VentoyWebDeepin.sh $tmpdir/
#cp $OPT Ventoy.desktop $tmpdir/
cp $OPT README $tmpdir/
cp $OPT plugin $tmpdir/
cp $OPT CreatePersistentImg.sh $tmpdir/
cp $OPT ExtendPersistentImg.sh $tmpdir/
dos2unix -q $tmpdir/Ventoy2Disk.sh
dos2unix -q $tmpdir/VentoyWeb.sh
dos2unix -q $tmpdir/VentoyWebDeepin.sh
#dos2unix -q $tmpdir/Ventoy.desktop
dos2unix -q $tmpdir/CreatePersistentImg.sh
dos2unix -q $tmpdir/ExtendPersistentImg.sh

cp $OPT ../LinuxGUI/WebUI $tmpdir/
sed 's/.*SCRIPT_DEL_THIS \(.*\)/\1/g' -i $tmpdir/WebUI/index.html

#32MB disk img
dd status=none if=$LOOP of=$tmpdir/ventoy/ventoy.disk.img bs=512 count=$VENTOY_SECTOR_NUM skip=$part2_start_sector
xz --check=crc32 $tmpdir/ventoy/ventoy.disk.img

losetup -d $LOOP && rm -f img.bin

rm -f ventoy-${curver}-linux.tar.gz


CurDir=$PWD

for d in i386 x86_64 aarch64; do
    cd $tmpdir/tool/$d
    for file in $(ls); do
        if [ "$file" != "xzcat" ]; then
            xz --check=crc32 $file
        fi
    done
    cd $CurDir
done

#chmod 
find $tmpdir/ -type d -exec chmod 755 "{}" +
find $tmpdir/ -type f -exec chmod 644 "{}" +
chmod +x $tmpdir/Ventoy2Disk.sh
chmod +x $tmpdir/VentoyWeb.sh
chmod +x $tmpdir/VentoyWebDeepin.sh
#chmod +x $tmpdir/Ventoy.desktop
chmod +x $tmpdir/CreatePersistentImg.sh

tar -czvf ventoy-${curver}-linux.tar.gz $tmpdir



rm -f ventoy-${curver}-windows.zip
cp $OPT Ventoy2Disk*.exe $tmpdir/
cp $OPT $LANG_DIR/languages.json $tmpdir/ventoy/
rm -rf $tmpdir/tool
rm -f $tmpdir/*.sh
rm -rf $tmpdir/WebUI
rm -f $tmpdir/README


zip -r ventoy-${curver}-windows.zip $tmpdir/

rm -rf $tmpdir

echo "=============== run livecd.sh ==============="
cd ../LiveCD
sh livecd.sh $1
cd $CurDir

mv ../LiveCD/ventoy*.iso ./

if [ -e ventoy-${curver}-windows.zip ] && [ -e ventoy-${curver}-linux.tar.gz ]; then
    echo -e "\n ============= SUCCESS =================\n"
else
    echo -e "\n ============= FAILED =================\n"
    exit 1
fi

rm -f log.txt

