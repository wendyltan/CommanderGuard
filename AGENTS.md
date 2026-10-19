# CommanderGuard 工作规范

适用范围：本仓库所有代码、测试、安装脚本及文档。上层共享协作约定同时适用；开始工作前读取当前 Git、README、TODO 与实际运行状态。

## 每次功能变更的交付要求

- 每次新增或修改功能，必须在同一批交付中同步更新 `README.md` 和 `README.en.md`，以最终实现为准；不能只更新 TODO 或聊天说明。
- README 是正式对外项目文档。介绍用户用途、运行条件、操作、限制与可验证结果，不写个人工作日志或本机事故细节。
- 不得在公开文档新增个人用户名、真实主机名、设备 ID、局域网地址、个人绝对路径、私有服务地址、账户用量或任何凭据。已有内容触及时一并检查脱敏。
- 路径使用仓库相对路径、标准用户目录约定或明确标注的通用示例。不要为了脱敏把当前不支持的安装方式写成可用；维护者专用部署必须明确说明限制。
- 提交前检查两份 README 的功能、按钮名称、默认值、权限、费用和恢复边界一致，并检查敏感信息及链接。

## 恢复与验证

- 自动恢复保持严格的任务、进程、云端调用与冷却保护。人工本次授权不改变永久开关，不成为自动恢复的豁免。
- 授权只用于当前已展示影响范围的服务实例，禁止持久化可重放授权、重复执行、任意命令或任意服务重启。
- 服务重启、通道回应、实际工具执行和业务服务恢复分别记录。外部重启不得记为 Guard 自动恢复；不重放原业务调用。
- 预览与自检不得修改正式状态或操作 Commander。使用固定、脱敏样例；真实断链与重启验收必须另有明确授权。
- 功能验证完成后安装新版 Guard、保留偏好并核对实际运行版本；只提交本批文件和语义 Tag，不自动推送或合并。
- 构建、自检、界面检查、真实外部验证、人工验收分别报告；未执行写明 NOT RUN。

## 常用验证

```sh
./build.sh
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --self-test
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui --verify-ui
./build/CommanderGuard.app/Contents/MacOS/CommanderGuard --preview-ui --preview-dark --verify-ui
git diff --check
```
