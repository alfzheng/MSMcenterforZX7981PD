# 部署、验收与回滚

本文适用于 ZX7981PD（OpenWrt 25.12.5，`mediatek/filogic`）。开发目录中的源文件不能直接视为正式发布包；正式部署只接受目标 SDK 构建出的 `.apk`、对应 SHA-256 清单和本页记录。

## 发布门禁

正式安装前必须同时满足：

1. `tests/static.ps1`、`tests/frontend-storage.js`、`tests/core.uc`、`tests/backend.uc` 全部通过。
2. 在目标机运行 `tests/daemon-integration.sh`，12 组真实 daemon/ubus 假基带测试全部通过；该测试不得接触真实 `lteat`。
3. 在目标机运行 `tests/daemon-live-read.sh`，SM 或 ME 至少一个可读；该测试只读，不发送、不删除。
4. 使用 OpenWrt 25.12.5 `mediatek/filogic` SDK 构建 `modem-smsd` 和 `luci-app-modem-sms` APK。
5. 对 APK 执行 `sha256sum`，将输出保存为随包交付的 `SHA256SUMS`；部署者在路由器上再次计算并逐项比对。
6. 记录安装前包清单、备份文件哈希、安装后版本和验收结果。任何一项缺失均为 NO-GO。
7. r5 额外要求 APK 中 LuCI/ACL 不含旧删除入口，daemon 兼容 `delete` RPC 只能返回
   `DEVICE_DELETE_DISABLED`，假后端删除调用次数必须为零。

本项目当前 Windows 工作区没有可执行的 Linux OpenWrt SDK，因此源代码测试通过不等于 APK 发布门禁已经满足；不得用手工复制文件冒充正式部署。

## 安装前备份

在路由器上执行，时间戳应替换为实际值：

```sh
mkdir -p /tmp/modem-sms-release
apk info -vv > /tmp/modem-sms-release/packages.before.txt
sysupgrade -b /tmp/modem-sms-release/sysupgrade-before.tar.gz
sha256sum /tmp/modem-sms-release/sysupgrade-before.tar.gz \
  > /tmp/modem-sms-release/sysupgrade-before.tar.gz.sha256
[ ! -e /etc/config/modem-sms ] || cp -p /etc/config/modem-sms \
  /tmp/modem-sms-release/modem-sms.uci.before
[ ! -e /etc/modem-sms-idempotency.json ] || cp -p \
  /etc/modem-sms-idempotency.json \
  /tmp/modem-sms-release/modem-sms-idempotency.before.json
```

将 `/tmp/modem-sms-release` 下载到路由器之外保存。`/tmp` 会在重启后清空，不能作为唯一备份位置。

## 安装与验收

```sh
cd /tmp/modem-sms-release
sha256sum -c SHA256SUMS
apk add --allow-untrusted ./modem-smsd-*.apk ./luci-app-modem-sms-*.apk \
  ./luci-i18n-modem-sms-zh-cn-*.apk
/etc/init.d/modem-smsd enable
/etc/init.d/modem-smsd restart
/etc/init.d/rpcd restart
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
ubus -S list modem.sms
modem-smsctl summary --json
modem-smsctl list --box all --storage ALL --limit 10 --refresh --json
```

r5 在任何真实短信操作前验证删除失败关闭：

```sh
capabilities="$(ubus call modem.sms capabilities '{}')"
[ "$(printf '%s' "$capabilities" | jsonfilter -e '@.features.delete')" = false ]
[ "$(printf '%s' "$capabilities" | jsonfilter -e '@.delete_error_code')" = DEVICE_DELETE_DISABLED ]

blocked="$(ubus call modem.sms delete \
  '{"id":"r5-safety-probe-nonexistent","fingerprint":"obsolete"}')"
[ "$(printf '%s' "$blocked" | jsonfilter -e '@.ok')" = false ]
[ "$(printf '%s' "$blocked" | jsonfilter -e '@.error_code')" = DEVICE_DELETE_DISABLED ]
```

该探针必须使用不存在的固定测试 ID，并在任何缓存刷新或模组调用前返回；不得使用
真实短信 ID、索引或指纹。调用前后保存 `logread -e modem-smsd`、短信计数和存储容量
摘要，确认只有 `device_delete_blocked` 审计记录，没有删除完成或后端删除记录。

安装验收阶段先做只读检查。只有在列表、能力、日志和存储容量均正常后，才使用用户明确指定的测试号码发送一条短信；`sent` 仅表示基带接受了所有分段，不等同于手机最终送达。

安装后保存：

```sh
apk info -vv > /tmp/modem-sms-release/packages.after.txt
apk info modem-smsd luci-app-modem-sms \
  > /tmp/modem-sms-release/modem-sms.versions.after.txt
logread -e modem-smsd > /tmp/modem-sms-release/modem-smsd.after.log
```

## 回滚

优先使用包级回滚，不覆盖整机固件：

```sh
/etc/init.d/modem-smsd stop
apk del luci-app-modem-sms modem-smsd
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
```

`/etc/config/modem-sms` 是 conffile，卸载后可能保留。幂等发送日志也会有意保留，以防旧 request ID 被静默重复使用。确认不再回装且已将日志归档到路由器之外后，才清理动态文件：

```sh
rm -f /etc/config/modem-sms
rm -f /etc/modem-sms-idempotency.json \
  /etc/modem-sms-idempotency.json.new \
  /etc/modem-sms-idempotency.json.purge-backup
```

如包级回滚不足，使用安装前的 `sysupgrade-before.tar.gz` 按 OpenWrt 的备份恢复流程恢复配置。恢复前核对其 SHA-256；不要在未核对目标型号和固件版本时刷写镜像。

## 中断恢复说明

若清除幂等历史时断电，`.purge-backup` 可能存在。守护进程会检测中断并进入保护逻辑；在确认备份内容和请求历史前，不得手工删除该文件或再次发送相同 request ID。将以下内容一并收集后再处置：

```sh
ls -l /etc/modem-sms-idempotency.json*
sha256sum /etc/modem-sms-idempotency.json* 2>/dev/null
logread -e idempotency
modem-smsctl summary --json
```

## 测试脚本安全边界

两份设备测试脚本都会在发现 `/etc/config/modem-sms`、`/usr/share/modem-sms` 或现有 `modem.sms` 服务时拒绝运行，避免覆盖正式安装。`daemon-integration.sh` 使用内存假后端，号码 `10010` 只进入假发送函数；`daemon-live-read.sh` 仅调用 capabilities/list。脚本退出时只删除自己创建的精确路径。
