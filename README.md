# ps-sync-deps

PowerShell 依赖同步工具：根据 `DEPS.json` 同步 git 仓库，或下载并解压 zip / 7z，并可选下载 binary。

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
| `-SyncDir` / 位置 1 | 是 | 依赖同步目录（如 `third_party`） |
| `-BinDir` | 否 | binary / 压缩包缓存目录；默认 `<SyncDir 的父目录>/bin` |
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
    },
    "ffmpeg": {
      "url": "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-8.1.2-full_build-shared.7z",
      "extract_to": "ffmpeg"
    }
  }
}
```

### dependencies 模式（按 URL 路径后缀）

| 后缀 | 模式 | 行为 |
|------|------|------|
| `.zip` | zip | 下载到 `BinDir` 缓存，解压到 `SyncDir/<extract_to 或 name>` |
| `.7z` | 7z | 同上（需要 7-Zip / `7z`） |
| 其他 | git | shallow clone 到 `SyncDir/<name>`，checkout 到指定 `commit` |

- git：需要 `url` + `commit`
- zip / 7z：需要 `url`；可选 `extract_to`（默认依赖名）；已解压且 URL 未变则跳过
- 压缩包若只有一层顶层目录，会剥掉该目录再落到目标路径

### binaries

下载到 `BinDir/<url 文件名>`；已存在则跳过。

示例见 [`example/DEPS.json`](example/DEPS.json)。

## 要求

- PowerShell 5.1+
- git 依赖需要 `git` 在 PATH 中
- 下载需要网络（`Invoke-WebRequest`）
- `.7z` 依赖需要 [7-Zip](https://www.7-zip.org/)（`7z` 或常见安装路径）

## License

MIT
