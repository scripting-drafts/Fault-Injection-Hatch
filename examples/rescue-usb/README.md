# Rescue USB example

Build a UEFI FAT32 USB that restores faultlab boot changes before systemd starts.
The USB carries its own initramfs; the installed kernel is loaded from `/boot`.
Build into a mounted FAT32 directory:

    ./build-rescue-usb.sh /media/user/RESCUE

Read `docs/rescue-usb.md` for prerequisites, limits and recovery use.
Never store real keys or credentials on the rescue media.
