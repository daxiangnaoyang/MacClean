# MacClean v0.5.0 · Apple Silicon 预览版

原生 macOS 空间分析、保守清理建议、应用卸载和可恢复操作。源码按 MIT 许可证公开。

本版将快速清理与全盘空间分析分开，按应用分组展示缓存和日志。精确可再生成缓存按用途判断，不统一等待14天；用户日志保留最近7天，系统日志只读。运行中的相关应用缓存暂缓，更新安装包需本人确认。建议删除、建议保留、必须保留三类判断保留，手动保留设置跨扫描保存。清理仅在本人确认后执行，重检变化与占用并移入废纸篓；扫描结束不会自动删除。

## 下载安装

- `MacClean-0.5.0-arm64.dmg`：打开后拖入 Applications。
- `MacClean-0.5.0-arm64.app.zip`：解压后的应用与 DMG 版本相同。
- `MacClean-0.5.0-docs.zip`：包含 README、全部说明图文、隐私边界、验收说明和许可证。
- `SHA256SUMS.txt`：三个附件的完整性校验清单。

**仅提供 Apple Silicon arm64。最低部署目标 macOS 14；跨设备和全部系统版本兼容性尚未验收。使用 ad-hoc 签名，未经过 Apple 公证，不是稳定发行版。**

[安装说明](https://github.com/daxiangnaoyang/MacClean/blob/v0.5.0/docs/INSTALL.md) · [八张说明图与操作指南](https://github.com/daxiangnaoyang/MacClean/blob/v0.5.0/docs/GUIDE.md) · [隐私与清理边界](https://github.com/daxiangnaoyang/MacClean/blob/v0.5.0/docs/PRIVACY.md) · [验收范围](https://github.com/daxiangnaoyang/MacClean/blob/v0.5.0/VERIFICATION.md)

公开图片使用虚构演示数据；真实扫描报告、应用清单、历史记录和本机备份不随发布上传。

重要文件应另行备份。废纸篓被清空后，MacClean 的历史记录不能恢复原文件。
