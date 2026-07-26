# 回滚说明

正式回滚步骤、安装前后备份、APK SHA-256 门禁、配置恢复、幂等日志归档和卸载残留清理统一维护在 [deployment-and-rollback.md](deployment-and-rollback.md)。本文件作为发布清单要求的固定入口，避免不同文档出现相互冲突的命令。

最小包级回滚顺序为：停止 `modem-smsd`，卸载 `luci-app-modem-sms` 与 `modem-smsd`，清理 LuCI 缓存，确认菜单、ACL、init 服务和 ubus 对象均消失。`/etc/config/modem-sms` 与 `/etc/modem-sms-idempotency.json*` 默认保留；只有在外部归档且确认不再回装后，才按主文档中的精确路径清理。

没有目标 SDK 生成的两个 APK、`SHA256SUMS` 和安装前整机配置备份时，正式部署为 NO-GO，也就不得进入回滚演练。
