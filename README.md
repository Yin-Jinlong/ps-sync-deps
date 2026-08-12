# ps-sync-deps

PowerShell 依赖同步工具：根据 `DEPS.json` 将 git 仓库固定到指定 commit，并可选下载 binary。

## 用法

```powershell
# 位置参数：依赖 JSON、同步目录
.\Sync-Deps.ps1 .\DEPS.json .\third_party

# 命名参数
.\Sync-Deps.ps1 -DepsFile .\DEPS.json -SyncDir .\third_party -BinDir .\bin

# 只同步指定项
.\Sync-Deps.ps1 .\DEPS.json .\third_party cli11 zlib

# 预览（不改动磁盘）
.\Sync-Deps.ps1 .\DEPS.json .\third_party -DryRun
```

## 参数

| 参数 | 必填 | 说明 |
|------|------|------|
| `-DepsFile` / 位置 0 | 是 | 依赖清单 JSON 路径 |
| `-SyncDir` / 位置 1 | 是 | git 依赖同步目录（如 `third_party`） |
| `-BinDir` | 否 | binary 下载目录；默认 `<SyncDir 的父目录>/bin` |
| `-Name` / 剩余参数 | 否 | 只同步这些 `dependencies` / `binaries` 名 |
| `-DryRun` / `-n` | 否 | 只打印计划，不执行 |

## DEPS.json 格式

```json
{
  "binaries": {
    "my-tool": {
      "url": "https://example.com/tool.jar",
      "version": "1.0.0"
    }
  },
  "dependencies": {
    "cli11": {
      "url": "https://github.com/CLIUtils/CLI11.git",
      "commit": "37bb6edc5317e99af72ef48405e65d9ca5218861"
    }
  }
}
```

- `dependencies`：shallow clone 到 `SyncDir/<name>`，checkout 到指定 `commit`
- `binaries`：下载到 `BinDir/<url 文件名>`；已存在则跳过

示例见 [`example/DEPS.json`](example/DEPS.json)。

## 要求

- PowerShell 5.1+
- `git` 在 PATH 中
- 下载 binary 需要网络（`Invoke-WebRequest`）

## License

MIT
