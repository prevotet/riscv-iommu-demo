sudo fdisk -l

sudo sgdisk --clear --new=1:2048:+32M --new=2 --typecode=1:3000 --typecode=2:8300 /dev/sdc -g


#/dev/sdc
sudo dd if=opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin of=/dev/sdc1 oflag=sync bs=1M
