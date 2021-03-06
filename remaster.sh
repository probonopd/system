#!/bin/bash

echo "Download the ISO to be customized..."
URL=http://cdimage.ubuntu.com/xubuntu/releases/18.04/release/xubuntu-18.04.4-desktop-amd64.iso
wget -q "$URL"

mv *.iso original.iso

echo "Mount the ISO..."

mkdir mnt
sudo mount -o loop,ro original.iso mnt/

echo "Extract .iso contents into dir 'extract-cd'..."

mkdir extract-cd
sudo rsync --exclude=/casper/filesystem.squashfs -a mnt/ extract-cd
ls extract-cd/casper || exit 1

echo "Extract the SquashFS filesystem..."

sudo unsquashfs -n mnt/casper/filesystem.squashfs
sudo mv squashfs-root edit

echo "Prepare chroot..."

# Mount needed pseudo-filesystems for the chroot
sudo mount --rbind /sys edit/sys
sudo mount --rbind /dev edit/dev
sudo mount -t proc none edit/proc
sudo mount -o bind /run/ edit/run
sudo cp /etc/hosts edit/etc/
# sudo mount --bind /dev/ edit/dev
# sudo cp -vr /etc/resolvconf edit/etc/resolvconf
sudo rm -rf edit/etc/resolv.conf || true
sudo cp /etc/resolv.conf edit/etc/

echo "Moving customization script to chroot..."
sudo mv customize.sh edit/customize.sh

echo "Entering chroot..."

sudo chroot edit <<EOF

echo "In chroot: Change host name..."
hostname ${TRAVIS_TAG}

echo "In chroot: Run customization script..."
chmod +x customize.sh && ./customize.sh && rm ./customize.sh

echo "In chroot: Removing packages..."
apt-get -y remove libreoffice-* gigolo thunderbird pidgin fonts-liberation 'fonts-smc*' fonts-lao fonts-beng fonts-beng-extra fonts-deva fonts-deva-extra fonts-droid-fallback fonts-gargi fonts-gujr-extra fonts-guru fonts-guru-extra fonts-kacst fonts-kacst-one fonts-kalapi fonts-khmeros-core fonts-lklug-sinhala fonts-lohit-beng-assamese fonts-lohit-beng-bengali fonts-lohit-deva fonts-lohit-knda fonts-lohit-mlym fonts-lohit-orya fonts-lohit-taml fonts-lohit-taml-classical fonts-nakula fonts-navilu fonts-noto-cjk fonts-noto-mono fonts-opensymbol fonts-pagul fonts-roboto fonts-roboto-hinted fonts-sahadeva fonts-samyak-deva fonts-samyak-gujr fonts-sarai fonts-sil-abyssinica fonts-sil-padauk fonts-symbola fonts-taml fonts-telu fonts-tibetan-machine fonts-tlwg-garuda fonts-tlwg-garuda-ttf fonts-tlwg-kinnari fonts-tlwg-laksaman-ttf fonts-tlwg-loma fonts-tlwg-loma-ttf fonts-tlwg-mono fonts-tlwg-norasi-ttf fonts-tlwg-purisa fonts-tlwg-purisa-ttf fonts-tlwg-sawasdee fonts-tlwg-typewriter-ttf fonts-tlwg-typist fonts-tlwg-typist-ttf fonts-tlwg-typo fonts-tlwg-umpush-ttf fonts-tlwg-waree fonts-tlwg-waree-ttf # fonts-noto-hinted is needed by xubuntu-default-settings
# TODO: How to remove/replace fonts-dejavu-core and fonts-noto-hinted without removing xubuntu-desktop and xubuntu-core?
# Without fonts-freefont-ttf Chrome-based apps refuse to start
# TODO: How to remove/replace fonts-mathjax without removing atril?
apt-get -y autoremove

echo "In chroot: Installing NVidia drivers..."
sudo -E add-apt-repository -y ppa:graphics-drivers
sudo apt-get -y install nvidia-384 nvidia-settings # run ubuntu-drivers devices on a local machine on this OS to find out the recmomended versions

echo "In chroot: Disabling nouveau..."
sudo apt-get -y purge xserver-xorg-video-nouveau || true
# https://linuxconfig.org/how-to-disable-nouveau-nvidia-driver-on-ubuntu-18-04-bionic-beaver-linux
sudo bash -c "echo blacklist nouveau > /etc/modprobe.d/blacklist-nvidia-nouveau.conf"
sudo bash -c "echo options nouveau modeset=0 >> /etc/modprobe.d/blacklist-nvidia-nouveau.conf"
sudo rm -rf /lib/modules/*/kernel/drivers/gpu/drm/nouveau/ # Since it was still loaded even after doing all of the above
# Do we also need to rebuild initrd here?

echo "In chroot: Installing proper Broadcom driver..."
sudo apt-get -y install b43-fwcutter 
sudo apt-get -y --reinstall install bcmwl-kernel-source

echo "In chroot: Disabling b43 which makes the screen flicker..."
sudo bash -c "echo blacklist b43 > /etc/modprobe.d/blacklist-b43.conf"

echo "In chroot: Updating initramfs..."
sudo /usr/sbin/update-initramfs.distrib -u || sudo /usr/sbin/update-initramfs -u

echo "In chroot: Delete temporary files..."
( cd /etc ; sudo rm resolv.conf ; sudo ln -s ../run/systemd/resolve/stub-resolv.conf resolv.conf )

rm -rf /tmp/* ~/.bash_history
exit
EOF

echo "Exiting chroot..."

# Unmount pseudo-filesystems for the chroot
sudo umount -lfr edit/proc
sudo umount -lfr edit/sys
sudo umount -lfr edit/dev

echo "Copying initramfs to casper..."
sudo cp edit/boot/initrd.img-5.3.0-28-generic extract-cd/casper/initrd

echo "Repacking..."

sudo chmod +w extract-cd/casper/filesystem.manifest

sudo su <<HERE
chroot edit dpkg-query -W --showformat='${Package} ${Version}\n' > extract-cd/casper/filesystem.manifest <<EOF
exit
EOF
HERE

sudo cp extract-cd/casper/filesystem.manifest extract-cd/casper/filesystem.manifest-desktop
sudo sed -i '/ubiquity/d' extract-cd/casper/filesystem.manifest-desktop
sudo sed -i '/casper/d' extract-cd/casper/filesystem.manifest-desktop

sudo mksquashfs edit extract-cd/casper/filesystem.squashfs -noappend
echo ">>> Recomputing MD5 sums"

sudo su <<HERE
( cd extract-cd/ && find . -type f -not -name md5sum.txt -not -path '*/isolinux/*' -print0 | xargs -0 -- md5sum > md5sum.txt )
exit
HERE

cd extract-cd 	
sudo mkisofs \
    -V "Custom OS" \
    -r -cache-inodes -J -l \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
	-o ../custom-desktop-amd64.iso .
sudo chown -R $USER ../*iso

cd ..

rm original.iso

# Write update information for use by AppImageUpdate; https://github.com/AppImage/AppImageSpec/blob/master/draft.md#update-information
echo "gh-releases-zsync|probonopd|system|latest|custom-*amd64.iso.zsync" | dd of="custom-desktop-amd64.iso" bs=1 seek=33651 count=512 conv=notrunc

# Write zsync file
zsyncmake *.iso

ls -lh *.iso
