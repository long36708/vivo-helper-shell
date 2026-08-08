# GT 玩机助手「强制安装 OTA」逆向分析

> 分析对象：`com.wellqrg.gt`（GT 玩机助手，MainActivity `com.projectkr.shell.MainActivity`），
> 反编译自设备 `base.apk`（versionCode 20220404）。jadx 输出见
> `reconbridge/pc/work/com.wellqrg.gt/apk/base-jadx`。

---

## 1. 入口与执行链路

### 1.1 动作定义（UI 层）

动作定义在 `assets/kr-script/payload/payload.xml` 的「系统更新」组「强制安装OTA包」：

```xml
<action interruptible="false">
    <title>强制安装OTA包</title>
    <desc>适用于A/B(含VAB)分区设备的手动安装更新</desc>
    <summary>支持官方包偷渡，降级，转换任意地区版本和第三方OTA包</summary>
    <params>
        <param name="ChongQi" label="自动重启系统" type="switch" />
        <param name="root"   label="保留系统ROOT" type="switch" />
        <param name="Format" label="格式化手机"   type="switch" />
        <param name="fota"   label="是自定义OTA包" type="switch" />
        <param name="rom"    label="ROM文件路径" type="file" suffix="zip" required="true" />
    </params>
    <set>sh $START_DIR/kr-script/payload/ab_updater.sh</set>
</action>
```

点击后执行 `sh $START_DIR/kr-script/payload/ab_updater.sh`。

### 1.2 脚本引擎与参数注入（Java 层）

脚本由 `com.omarea.krscript` 引擎（`d/c/b/n/b.java`）拉起，机制如下：

- **root 拉起**：`g()` 里 `f1412d ? exec("su") : exec("sh")` —— 有 root 权限时用 `su` 起 shell。
- **环境变量注入**：`executor.sh` 中 `$({START_DIR})`、`$({MAGISK_PATH})`、`$({ROOT_PERMISSION})`
  等占位符在 Java 侧被替换成实际值（`k()` → `e()`），再写回 `kr-script/executor.sh`。
- **动作参数 export**：UI 上每个 `<param>` 的值会被放进 `HashMap`，由 `i()` 转成
  `export 参数名='值'` 前缀写入 shell 输入流（`c()` 方法），所以 `ab_updater.sh` 里直接
  读 `$rom`、`$root`、`$Format`、`$fota`、`$ChongQi` 变量。
- **执行方式**：`executor.sh` 先 `source` 具体脚本，再 `cd "$START_DIR"`。

| 参数 | 含义 |
|---|---|
| `rom` | OTA zip 绝对路径（必填） |
| `fota` | `1` = 自定义/非官方 OTA 包（走证书绕过） |
| `root` | `1` = 更新后自动刷入 Magisk 保留 ROOT |
| `Format` | `1` = 安装后清数据（POWERWASH） |
| `ChongQi` | `1` = 安装完成后自动重启 |

---

## 2. `ab_updater.sh` 逐段分析

完整脚本：`assets/kr-script/payload/ab_updater.sh`。

### 2.0 准备

```sh
if [ ! -f "/data/7za" ]; then
    cp -r "$workdir"/7za /data && chmod 777 /data/7za
fi
resetprop ro.build.date.utc 1600000000
alias 7za="/data/7za"
```

- 把随包的 `7za`（7-Zip 静态版）部署到 `/data/7za`。
- **`resetprop ro.build.date.utc 1600000000`**：把构建时间戳改成一个过去值，
  绕过 OTA 的**时间/降级校验**（官方包通常拒绝比当前系统更旧的时间戳，这是降级的关键前置）。

### 2.1 ROM 校验

```sh
if [[ "$rom" == "" ]] || [[ ! -f "$rom" ]]; then
  echo '未选择ROM文件，或指定的文件无法访问！' 1>&2; exit 1
fi
```

### 2.2 签名检测 + payload 定位（核心分叉）

```sh
files=$(7za l $rom)
if [[ $(echo "$files" | grep "signed by SignApk") == "" ]] ; then
  # 非编译ROM —— 解压安装
  out_dir=${rom%.*}
  7za e -o"$out_dir" "$rom"          # 解出 payload.bin / payload_properties.txt
  headers=$(cat "$out_dir/payload_properties.txt")
  binfile=$out_dir/payload.bin
else
  # 编译ROM —— 直读安装
  7za e $rom META-INF/com/android/metadata
  7za e $rom payload_properties.txt
  device=$(cat metadata |grep "pre-device");   device=${device#*=}
  t=$(cat metadata |grep "post-timestamp");    t=${t#*=}
  binhex=$(cat metadata |grep "ota-streaming-property-files")
  binhex=${binhex#*payload.bin:};   binhex=${binhex%,payload_properties.txt:*}
  offset=${binhex%:*};   size=${binhex#*:}
  headers=$(cat "payload_properties.txt")
  binfile=$rom
fi
```

- 用 `7za l` 列目录，看 zip 内是否有 **`signed by SignApk`** 标记判断是否官方编译包。
- **非编译包**：整包解压到 `ROM路径去扩展名/`，取解压出的 `payload.bin` 安装。
- **编译/官方包**：只解出 `META-INF/com/android/metadata` 和 `payload_properties.txt`，
  从 `ota-streaming-property-files` 解析出 `payload.bin:OFFSET:SIZE`，随后**直读 zip** 流式安装。

### 2.3 POWERWASH（清数据）

```sh
if [[ $(echo "$headers" |grep POWERWASH=1) == "POWERWASH=1" ]] ; then
  echo '您选择的ROM必须清除数据'
else
   if [[ $Format == 1 ]]; then
     headers=$headers$'\n'POWERWASH=1
   fi
fi
```

官方包自身声明 `POWERWASH=1`，或用户勾选「格式化手机」时，往 headers 追加
`POWERWASH=1`，让 update_engine 安装后执行 factory reset。

### 2.4 双槽位检测

```sh
slot=$(getprop ro.boot.slot_suffix)
if [[ "$slot" == "_a" ]]; then SLOT="_b"; else SLOT="_a"; fi
```

A/B 设备永远把新系统写到**对侧槽位**，之后重启切换。

### 2.5 证书绕过（`fota=1`，本工具的精髓）

```sh
if [[ $fota == 1 ]]; then
  cp -f kr-script/payload/testcerts.zip /data/fuck_oddo_ota_testcerts.zip
  cp -f /system/bin/update_engine update_engine          # 备份到当前目录
  # magiskboot hexpatch: 把硬编码证书路径 /system/etc/security/otacerts.zip
  #   → /data/fuck_oddo_ota_testcerts.zip
  /data/adb/magisk/magiskboot hexpatch update_engine \
      2F73797374656D2F6574632F73656375726974792F6F746163657274732E7A6970 \
      2F646174612F6675636B5F6F64646F5F6F74615F7465737463657274732E7A6970
  # 或 KernelSU 的 magiskboot: /data/adb/ksu/bin/magiskboot
  chmod 0777 ./update_engine
  setprop ctl.stop update_engine                        # 停掉系统服务
  nohup ./update_engine --logtostderr --logtofile --foreground >/sdcard/ota.log 2>&1 &
else
  pkill -9 update_engine
  setprop ctl.start update_engine                       # 官方包: 重启系统服务
fi
```

- `update_engine` 二进制里**硬编码**了 OTA 公钥证书路径 `/system/etc/security/otacerts.zip`。
- 用 `magiskboot hexpatch` 把这段 ASCII 路径串替换成 `/data/fuck_oddo_ota_testcerts.zip`
  （两段 hex 恰好是这两个路径的字节序列），并在 `/data` 放好自签 `testcerts.zip`。
- 停掉系统 update_engine 服务，**手动前台拉起补丁版 update_engine**，后续
  `update_engine_client` 连上的就是这个签名校验已被替换的引擎 → 第三方/非官方包可过。
- 官方包（`fota` 未勾选）则直接杀进程重启系统服务，用系统原版证书。

> 注意：`testcerts.zip` 的 "testcerts" 是自签测试证书，只对**自有或明确授权**设备的
> 调试/降级场景使用，不能用于生产发布。

#### ⚠ 实测坑：GT 单独刷不进去，需配套 `vivo_ota89_fix` 模块

`cp -f /system/bin/update_engine update_engine` 会把系统二进制复制到**当前目录**
（`$START_DIR` = `/data/user/0/com.wellqrg.gt/files`），随后 `nohup ./update_engine ...`
也在此目录启动。由于 executor.sh 强制 `cd "$START_DIR"`，这个 update_engine 在
**错误 cwd** 下运行，用相对路径读 `system/etc/oem-all-in-one.txt` 时失败：

```
ERROR: getFileContent filename system/etc/oem-all-in-one.txt open failed
ERROR: Replying with failure: ... Failed to get additional payloads   # 错误 89
```

配套面具模块 `vivo_ota89_fix`（守护进程每 2 秒检查该副本，一旦 >1MB 就替换成
「`cd /` + `exec /system/bin/update_engine`」的 shell 包装器）让副本实际 exec
系统原版、cwd 归 `/`，才能过 89。**代价**：包装器替换后，GT 对该副本做的证书
hexpatch 也被换掉 → 证书绕过失效，所以该方案只对**有效签名官方包**可行
（多代号包实测可过）。降级场景还需再配 `vivo_ota_downgrade_bypass`（错误 92）。

> 项目 `vivo_ota.sh` 之所以坚持「绝不复制 update_engine 二进制、直接用系统服务」，
> 正是为了从根上绕开这套外挂与 89 问题。

### 2.6 发起安装

```sh
if [[ "$offset" == "" ]]; then
  update_engine_client --update --payload="file://$binfile" --headers="$headers" --follow
else
  update_engine_client --update --payload="file://$rom" \
    --offset="$offset" --size="$size" --headers="$headers" --follow
fi
```

- 无 offset（解压模式）：装解压出的 `payload.bin`。
- 有 offset（直读模式）：从 zip 内给定 offset/size 流式读 payload。
- `--follow` 让客户端阻塞跟随安装进度。

### 2.7 保留 ROOT（`root=1`）

```sh
BOOTIMAGE="/dev/block/by-name/boot$SLOT"
cd /data/adb/magisk
. ./util_functions.sh
install_magisk
```

安装成功后，对**对侧槽位**的 `boot` 分区执行 Magisk 官方 `install_magisk` 修补，
刷完新系统仍是 ROOT（脚本注释注明"仅支持阿尔法面具"）。

### 2.8 自动重启（`ChongQi=1`）

```sh
reboot   # 5 秒倒计时后
```

---

## 3. 辅助脚本

| 脚本 | 内容 | 用途 |
|---|---|---|
| `payload/cat.sh` | `logcat -s update_engine:v` | 查看正在进行的更新进度 |
| `payload/exit.sh` | `update_engine_client --reset_status` | 撤销已完成但未重启的更新 |
| `payload/quit.sh` | `update_engine_client --cancel` | 取消进行中的更新 |
| `payload/fota.sh` | `/data/adb/magisk/magisk64 --install-module $workdir/Fuck_OTA_Magisk-Modules.zip` | 安装 Fuck_OTA Magisk 模块；**遗留死代码**（对应 zip 未随包附带，payload.xml 也未引用） |

---

## 4. 关键机制总结

1. **签名绕过**：hexpatch `update_engine` 硬编码 otacerts 路径 → 自定义 testcerts，
   手动前台起补丁版引擎，使第三方/降级包能通过校验。
2. **时间戳绕过**：`resetprop ro.build.date.utc` 改构建时间，绕过 OTA 降级/时间检查。
3. **对侧槽位直刷**：检测 `ro.boot.slot_suffix`，目标永远是对侧槽位，`update_engine_client`
   直喂 `payload.bin`（或 zip 内 offset/size）。
4. **双证书库**：官方多代号同系包用系统 `otacerts.zip` 即可过（不走 hexpatch），
   这也是 `vivo_ota.sh` 对 vivo 多代号包的经验结论。
5. **保留 ROOT**：成功后 `install_magisk` 修补对侧 `boot` 分区。
