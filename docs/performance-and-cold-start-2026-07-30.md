# 短信中心冷启动与页面性能调查（2026-07-30）

## 结论

页面截图中的两个错误不是“没有短信”的正常状态，而是前端在 LuCI
RPC 超时或服务未及时返回时使用的通用兜底文案。仓库现有交接记录已经
确认目标机 `SM`、`ME` 串行读取耗时约 23–44 秒，但该结论只通过设备上
手工把缓存改为 300 秒解决，包内默认配置仍是 `cache_seconds=10`，读取
超时仍是 30 秒。因此重启服务、缓存失效或配置被 conffile 恢复后，首次
进入页面仍可能重复触发冷扫描并显示 `SERVICE_UNAVAILABLE`。

本次修复：

1. 将包内默认缓存改为 300 秒，将后端读取超时改为 60 秒，覆盖当前现场
   冷读取实测上限。
2. 守护进程首次加载时立即返回 `loading: true` 和空列表，并只启动一次
   后台 `SM/ME` 扫描。LuCI 不再把等待中的冷扫描误报为服务不可用；扫描
   完成后页面自动轮询并展示结果。
3. 明确保留“手动刷新调制解调器”为前台操作。已有快照的普通进入和切换
   收件箱/发件箱使用缓存，不会再次访问串口。
4. 为默认值与前端加载态增加静态回归门禁，短信守护进程包版本提升到
   `0.1.0-r3`。

## 现有安装的注意事项

`/etc/config/modem-sms` 是 conffile。升级包不会覆盖管理员已经存在的配置，
所以目标机升级后必须只读核对：

```sh
uci get modem-sms.main.cache_seconds
uci get modem-sms.lteat.read_call_timeout_seconds
```

若仍为旧值，应在确认当前没有发送任务后执行：

```sh
uci set modem-sms.main.cache_seconds='300'
uci set modem-sms.lteat.read_call_timeout_seconds='60'
uci commit modem-sms
/etc/init.d/modem-smsd restart
```

随后先调用 `ubus call modem.sms capabilities '{}'`，再调用一次不带
`refresh` 的 `list`。首次返回 `loading:true` 是预期状态，待后台扫描结束
后再次调用应返回 `loading:false`、`ok:true` 和缓存时间。真实设备的双存储
读取、`usb0` 连通性以及发送/删除仍需按部署文档单独验收；本次源码检查
没有把历史交接记录当作当前设备状态。
