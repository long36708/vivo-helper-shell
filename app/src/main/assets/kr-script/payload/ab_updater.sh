#!/system/bin/sh
workdir=$(
    cd $(dirname $0)
    pwd
)
if [ ! -f "/data/7za" ]; then
    cp -r "$workdir"/7za /data
    chmod 777 /data/7za
else
    chmod 777 /data/7za
fi
resetprop ro.build.date.utc 1600000000
#mount --bind otacerts.zip /system/etc/security/otacerts.zip
alias 7za="/data/7za"
if [[ "$rom" == "" ]] || [[ ! -f "$rom" ]]; then
  echo '未选择ROM文件，或指定的文件无法访问！' 1>&2
  echo "选择的文件：$rom" 1>&2
  exit 1
fi

files=$(7za l $rom)
if [[ $(echo "$files" | grep "signed by SignApk") == "" ]] ; then
  echo '检测到非编译ROM，解压安装' 1>&2
  #解压安装
     out_dir=${rom%.*}
      if [[ "$out_dir" == "" ]]; then
      echo "路径解析失败 $out_dir" 1>&2
      exit 1
      elif [[ ! -f "$out_dir/payload.bin"  ]]; then
      echo "解压ROM文件至$out_dir ……"
      7za e -o"$out_dir" "$rom" # > /dev/null 
  
  elif [[ -e "$out_dir" ]]; then
  echo "解压路径已存在,跳过解压 $out_dir" 
    if [[ ! -f "$out_dir/payload.bin" ]] && [[ ! -f "$out_dir/payload_properties.txt" ]]; then
      echo '文件缺失，请删除$out_dir目录并重试' 1>&2
      exit 1
        fi
  fi
headers=$(cat "$out_dir/payload_properties.txt")
binfile=$out_dir/payload.bin
  else
  echo "检测到编译ROM，直读安装" 1>&2
  rm payload_properties.txt >/dev/null 2>&1
  rm metadata >/dev/null 2>&1
  7za e $rom META-INF/com/android/metadata >/dev/null 2>&1
  7za e $rom payload_properties.txt >/dev/null 2>&1
  device=$(cat metadata |grep "pre-device")
  device=${device#*=}
t=$(cat metadata |grep "post-timestamp")
t=${t#*=}
echo 当前手机代号是：$(getprop ro.product.device)
echo "OTA包的机型代号为：$device" 1>&2
echo OTA包的编译时间为：$(date  +'%F %T' -d @$t)
binhex=$(cat metadata |grep "ota-streaming-property-files")
binhex=${binhex#*payload.bin:}
binhex=${binhex%,payload_properties.txt:*}
offset=${binhex%:*}
size=${binhex#*:}
echo 解析payload.bin数据地址为:$offset   长度为:$size
headers=$(cat "payload_properties.txt")
binfile=$rom
fi

if [[ $(echo "$headers" |grep POWERWASH=1) == "POWERWASH=1" ]] ; then
  echo '您选择的ROM必须清除数据' 1>&2
else
   if [[ $Format == 1 ]]; then
     headers=$headers$'\n'POWERWASH=1
     echo '当前模式安装完后会自动清除数据' 1>&2
   fi
fi

# echo 'progress:[-1/100]'


echo '即将开始更新系统，根据设备性能，可能需要5~10分钟甚至更久'
sleep 5
if [[  $root == 1 ]]; then
  echo '当前模式更新后会自动刷入ROOT' 1>&2
else
    echo '当前模式更新后不会自动刷入ROOT' 1>&2
fi

slot=$(getprop ro.boot.slot_suffix)
 echo -n '当前插槽：' $slot
 if [[ "$slot" == "_a" ]]; then
   echo '，新系统将会安装到：_b'
   SLOT="_b"
 else
   echo '，新系统将会安装到：_a'
   SLOT="_a"
fi
if [[ $fota == 1 ]]; then
echo "检测到非官方包，开始补丁证书路径" 1>&2
cd $(pwd)
cp -f kr-script/payload/testcerts.zip /data/fuck_oddo_ota_testcerts.zip
cp -f /system/bin/update_engine update_engine
if [[ -f /data/adb/magisk/magiskboot ]];then
/data/adb/magisk/magiskboot hexpatch update_engine 2F73797374656D2F6574632F73656375726974792F6F746163657274732E7A6970 2F646174612F6675636B5F6F64646F5F6F74615F7465737463657274732E7A6970 >/dev/null 2>&1
else
/data/adb/ksu/bin/magiskboot hexpatch update_engine 2F73797374656D2F6574632F73656375726974792F6F746163657274732E7A6970 2F646174612F6675636B5F6F64646F5F6F74615F7465737463657274732E7A6970 >/dev/null 2>&1
fi
chmod 0777 ./update_engine
setprop ctl.stop update_engine
nohup ./update_engine --logtostderr --logtofile --foreground >/sdcard/ota.log 2>&1 &
else
   pkill -9 update_engine
   setprop ctl.start update_engine
fi

echo "将在5秒后开始安装，开始倒计时……"
        for i in $(seq 5 -1 1); do
            echo "$i"  1>&2
            sleep 1
        done
            
            

if [[  "$offset" == "" ]]; then
  echo '读取payload.bin安装' 1>&2
  update_engine_client --update  --payload="file://$binfile"  --headers="$headers" --follow

else
    echo '直读zip安装' 1>&2
    update_engine_client --update  --payload="file://$rom" --offset="$offset" --size="$size" --headers="$headers" --follow
fi

echo 系统安装成功
if [[ $root == 1 ]]; then
   BOOTIMAGE="/dev/block/by-name/boot$SLOT"
   echo "正在安装Magisk......" 1>&2
   cd  /data/adb/magisk
   . ./util_functions.sh
   install_magisk >/dev/null 2>&1
   echo "ROOT成功!"  1>&2
 fi
if [[ $ChongQi == 1 ]]; then
        echo "即将在5秒后自动重启，开始倒计时……"
        for i in $(seq 5 -1 1); do
            echo "$i"  1>&2
            sleep 1
        done
            echo "即将重启"
            reboot 
fi
