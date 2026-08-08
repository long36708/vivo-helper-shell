#!/system/bin/sh
workdir=$(
    cd $(dirname $0)
    pwd
)
/data/adb/magisk/magisk64 --install-module $workdir/Fuck_OTA_Magisk-Modules.zip