# TouchBridge：iPad 远程坐标触控

基于 Appium WebDriverAgent 的 arm64 测试运行器。目标使用环境是未越狱的 iPadOS 26 及以上设备，由 Windows 电脑启动测试会话，服务器再向电脑下发点击指令。

```
你的服务器 → Windows 桥接程序 → 局域网中的 iPad / TouchBridge
                                  ↑ Windows 维持 XCTest 运行会话
```

## 交付与运行边界

- `TouchBridge.ipa` 是未签名 IPA，供你用自己的签名工具签名；不是已签名的安装包。
- 运行器 Bundle ID：`com.jonesnela.TouchBridge.xctrunner`。重新签名可能改变此 ID，启动命令要使用安装后的实际 ID。
- 安装并点击桌面图标不会自动开始触控服务。需要信任电脑、开发者模式、匹配的开发者磁盘映像（DDI）及电脑启动 XCTest。
- 个人签名需要覆盖主程序、`PlugIns/*.xctest` 及其中的 framework。只签最外层 App 可能安装成功，但测试启动失败。
- 免费 Apple ID 的签名有效期、设备限制和测试启动权限需以实际签名工具和描述文件为准。建议用 Development 类型描述文件验证；不能把“安装成功”等同于“触控可用”。
- 构建成功只能证明编译和打包通过。本项目没有连接实际 iPad，不能宣称已经验证 iPadOS 26 或所有未来版本。
- 点击按 XCTest 的方式执行，适合坐标点击和自动化操作；没有承诺游戏中的高频、多指或逐帧输入性能。

## GitHub 编译

工作流 `.github/workflows/touchbridge-ipa.yml` 在 `codex/touchbridge` 分支推送时编译，也支持手动触发。采用 GitHub macOS runner 和 Xcode 16.4，沿用上游支持的工具链；构建真机 arm64 运行器，打包为 `Payload/*.app`。

`TouchBridge-unsigned-ipa` 构建产物包含 IPA、SHA256 和编译元信息。按照上游 `Scripts/ci/build-real.sh` 的方式排除最外层 Frameworks，使 iOS 17+ 从设备 DDI 加载 XCTest；保留插件里的 WebDriverAgentLib。

```powershell
gh workflow run touchbridge-ipa.yml --repo JonesnelA/WebDriverAgent --ref codex/touchbridge
gh run list --repo JonesnelA/WebDriverAgent --workflow touchbridge-ipa.yml
gh run download <运行编号> --repo JonesnelA/WebDriverAgent --name TouchBridge-unsigned-ipa --dir artifacts
```

## Windows 首次配置

安装 Python 3.11 或以上，以及 Apple 官方桌面版 iTunes 的 Apple Mobile Device Support。Wi-Fi 设备发现需要对应的 Apple 服务；Microsoft Store 的 Apple Devices 服务可能不支持相同的无线发现方式。

电脑首次需要通过 USB 完成信任配对。以下步骤为待真机验证的操作路径，实际型号、签名工具和 iPadOS 小版本可能要求调整。

```powershell
python -m pip install "pymobiledevice3 @ git+https://github.com/doronz88/pymobiledevice3.git@03ba2270c0c80df77c37f65adc1967595970d31f"
python -m pymobiledevice3 usbmux list
python -m pymobiledevice3 lockdown pair
python -m pymobiledevice3 lockdown wifi-connections on
python -m pymobiledevice3 lockdown remotepairing --pair
```

在 iPad 的“设置 → 隐私与安全性 → 开发者模式”中启用开发者模式，并按系统提示重启确认。将签名后的 IPA 安装到 iPad，信任对应开发者。

```powershell
python -m pymobiledevice3 mounter auto-mount
```

之后电脑和 iPad 连接同一局域网，可尝试拔线建立无线隧道。在管理员 PowerShell 中运行并保持窗口打开：

```powershell
python -m pymobiledevice3 remote start-tunnel -t wifi
```

该命令输出 `RSD Address` 与 `RSD Port`。在另一个窗口运行并保持打开：

```powershell
python -m pymobiledevice3 developer dvt xcuitest --rsd <RSD地址> <RSD端口> com.jonesnela.TouchBridge.xctrunner
```

等到日志出现 WebDriverAgent 服务地址。若无法启动，应先核对实际 Bundle ID、插件签名、开发者模式、DDI 和无线配对；不能仅通过更换服务器地址解决测试权限问题。

## 验证坐标点击

假设 iPad 的 Wi-Fi 地址为 `192.168.1.50`，WDA 默认端口为 8100：

```powershell
python TouchBridge/bridge.py --wda http://192.168.1.50:8100 status
python TouchBridge/bridge.py --wda http://192.168.1.50:8100 screenshot screen.png
python TouchBridge/bridge.py --wda http://192.168.1.50:8100 tap 120 240
python TouchBridge/bridge.py --wda http://192.168.1.50:8100 tap 0.5 0.5 --units normalized
```

默认坐标单位为 iOS 逻辑点，原点在当前方向屏幕左上角。归一化坐标范围 `[0,1)`。使用截图像素坐标时必须同时提供截图尺寸，例如：

```powershell
python TouchBridge/bridge.py --wda http://192.168.1.50:8100 tap 600 800 --units pixels --image-width 2048 --image-height 2732
```

图片尺寸应取自当前实际截图，不能照抄例子的数值。旋转屏幕后重新截图取点。首版面向全屏 App，iPad 分屏、台前调度等窗口场景的坐标偏移需要额外真机验证。

## 对接你的服务器

电脑端提供一个带 Bearer Token 的 `/tap` 接口。默认只监听本机；服务器可通过你现有的私有网络/VPN访问 Windows 的指定地址。设置一段至少 24 字符的随机 token：

```powershell
$env:TOUCHBRIDGE_TOKEN = '<你生成的随机token>'
python TouchBridge/bridge.py --wda http://192.168.1.50:8100 serve --host <Windows私有网络IP> --port 8765
```

服务器发送：

```http
POST /tap
Authorization: Bearer <相同token>
Content-Type: application/json

{"x":120,"y":240,"units":"points"}
```

成功返回 `ok: true` 和最终逻辑点坐标。可使用 `GET /status` 检查 WDA。指令串行执行；错误或超时不自动重发点击，避免发生一次点击被执行两次。上层服务器也不要在不确定的失败后自动重试。

WDA 的 8100 接口本身没有本项目桥接 API 的认证。WDA 与桥接接口均应限制在你控制的局域网/私有网络中；公网服务器连接的是电脑的私有网络入口。

## 调研依据

- [iPhoneMirror 触控入口](https://github.com/RayrenSX/iPhoneMirror/blob/main/tools/iostouch/__init__.py)：电脑通过开发者 HID 服务注入触控，不依赖手机端 IPA。
- [WebDriverAgent](https://github.com/appium/WebDriverAgent)：链接 XCTest，提供坐标点击、应用控制和截图 HTTP 接口。
- [预安装 WDA 的运行要求](https://github.com/appium/appium-xcuitest-driver/blob/master/docs/guides/run-preinstalled-wda.md)：签名、DDI、测试启动与设备 XCTest 框架依赖。
- [pymobiledevice3 无线开发者隧道](https://github.com/doronz88/pymobiledevice3/blob/03ba2270c0c80df77c37f65adc1967595970d31f/docs/guides/ios17-tunnels.md)：USB 信任、远程配对、Wi-Fi 隧道和 RSD 参数。

上游来源提交：`d15c0b2dbaa850fa712fba817e51cf8d5026d9f2`。保留仓库 LICENSE 和原始版权声明。
