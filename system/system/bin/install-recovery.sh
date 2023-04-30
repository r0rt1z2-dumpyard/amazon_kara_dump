#!/system/bin/sh
if ! applypatch -c EMMC:/dev/block/platform/soc/11230000.mmc/by-name/recovery:13473792:8a3dafd4a49cefde939a83b0d7eacf90f0a6fe73; then
  applypatch  EMMC:/dev/block/platform/soc/11230000.mmc/by-name/boot:7827456:f2370263aa5c9d4dbbac0dc02fa161a0c2f830c6 EMMC:/dev/block/platform/soc/11230000.mmc/by-name/recovery a60fec5418e33ee1657cf808092721b191791f73 13471744 f2370263aa5c9d4dbbac0dc02fa161a0c2f830c6:/system/recovery-from-boot.p && installed=1 && log -t recovery "Installing new recovery image: succeeded" || log -t recovery "Installing new recovery image: failed"
  [ -n "$installed" ] && dd if=/system/recovery-sig of=/dev/block/platform/soc/11230000.mmc/by-name/recovery bs=1 seek=13471744 && sync && log -t recovery "Install new recovery signature: succeeded" || log -t recovery "Installing new recovery signature: failed"
else
  log -t recovery "Recovery image already installed"
fi
