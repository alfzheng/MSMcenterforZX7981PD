# 短信设备删除安全热修 r5 记录

日期：2026-07-31（Asia/Shanghai）

状态：实施前基线已记录；r5 开发、构建、部署与验收进行中

## 1. 决策

独立对抗性审计确认：新版 PRD 已把安全设备删除限定在 Stage C，但当前 r4 代码仍
暴露旧同步删除链路。用户同意先发布安全热修，立即失败关闭设备删除；本地归档、
批量管理和异步安全删除后续按 Stage A/B/C 实现。

r5 不实现本地归档或新的删除流程，也不删除任何现有短信。读取、发送、状态查询、
缓存和 `usb0` 移动数据业务必须保持不变。

## 2. 实施前仓库基线

基线提交：`f82bc70456a04a6b86dbf79860bc3334571f2d38`

源码包版本：

- `modem-smsd 0.1.0-r4`
- `luci-app-modem-sms 0.1.0-r4`

已确认的旧删除暴露面：

1. rpcd ACL 的写权限包含 `modem.sms.delete`；
2. `backend-lteat` 声明 `features.delete=true`；
3. LuCI 详情页显示删除按钮并调用同步 `delete` RPC；
4. `modem-smsd` 注册旧 `delete(id,fingerprint)`，重新扫描后直接调用
   `backend.delete_record()`；
5. 删除保护使用源码明确标注为非密码学的 64 位指纹，不具备新版 PRD 要求的
   原始 PDU SHA-256、扫描 epoch、来源 generation、无损安全副本、durable
   delete intent、archive pin、幂等墓碑或 CPMS 独占租约。

最近一次真机部署记录显示目标机运行 r4；本轮实施前非交互 SSH 只读复核因目标机
未接受现有密钥而未完成。安装阶段必须通过已有授权会话重新读取包版本和服务状态，
不能把历史记录当作实时状态。

## 3. r5 热修范围

r5 必须同时完成五层失败关闭：

| 层级 | r5 行为 |
|---|---|
| 服务能力 | `capabilities.features.delete=false`，返回稳定禁用原因 |
| 兼容 RPC | 保留旧 `delete` 方法名，但在任何读取、排队或模组调用前返回 `DEVICE_DELETE_DISABLED` |
| 后端能力 | `backend-lteat` 不再声明删除可用 |
| rpcd ACL | LuCI 写权限只保留 `send`，移除 `delete` |
| LuCI/CLI | 页面不声明、不显示、不调用删除；CLI 不提供删除命令 |

旧浏览器缓存或旧客户端即使仍能构造 `delete` RPC，也只能命中后端兼容失败桩，
不得触发 `SM/ME` 刷新、`CPMS` 切换或 `lteat.del_sms`。

## 4. 发布验收

### 4.1 源码与离线包

- 两个 Makefile 均为 `PKG_RELEASE:=5`；
- 静态检查、前端存储测试、JavaScript 语法检查和 shell 语法检查通过；
- 真实 daemon/ubus 假基带集成测试确认删除返回 `DEVICE_DELETE_DISABLED`，且假后端
  的 `delete_record()` 调用计数为零；
- 目标 SDK 生成 r5 APK，`apk verify`、`adbdump`、解包内容和 SHA-256 全部通过；
- APK 内脚本保持 LF，不能重现 r3 的 CRLF 启动故障。

### 4.2 真机非破坏性验收

- 安装前保存包清单、短信配置、幂等发送状态和相关文件哈希到设备外；
- 安装后 `modem-smsd` 与 LuCI 包版本为 r5，服务已注册并运行；
- `capabilities.features.delete=false`；
- 使用不存在的测试 ID 调用旧 `delete`，稳定返回
  `ok:false,error_code:DEVICE_DELETE_DISABLED`；
- 删除失败桩调用前后短信数量、缓存时间和存储容量没有删除型变化；
- LuCI 新页面无删除按钮，rpcd ACL 不含 `delete`；
- `list`、`get`、`analyse`、`summary` 和发送状态查询可用；
- 不发送真实短信，除非用户另行提供测试号码并明确确认；
- `usb0` 地址与默认路由不变化，5G 数据业务不中断。

## 5. 回滚边界

若 r5 影响读取、发送或 `usb0`，允许包级回滚到安装前 r4 备份，并立即记录原因。
回滚会重新暴露不安全的旧删除链路，因此回滚后必须再次以独立后端门禁禁用删除，
不能把“恢复旧删除能力”视为成功回滚标准。

