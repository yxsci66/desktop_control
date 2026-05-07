# 远程桌面控制系统

基于 WebRTC 的远程桌面控制项目，通过 Flutter 客户端实时查看并控制远端 Windows 桌面。

## 架构

```
┌─────────┐     WebSocket      ┌─────────┐     WebSocket      ┌─────────┐
│ Client  │ ◄──────────────► │ Signal  │ ◄──────────────► │  Host   │
│(Flutter)│  信令 + 控制指令   │ Server  │  信令 + SDP/ICE   │(Python) │
└─────────┘                   │(Node.js)│                   └─────────┘
              WebRTC 直连 ──────────────────────────────►  屏幕推流 + 接收控制
```

- **Signal Server**：Node.js + WebSocket，负责 Host 与 Client 的 SDP/ICE 信令转发
- **Host**：Python + aiortc + pyautogui，捕获屏幕并通过 WebRTC 推流，接收并执行鼠标/键盘指令
- **Client**：Flutter + flutter_webrtc，渲染远端视频，将触摸手势转为控制指令

## 快速开始

### 1. 启动信令服务器

```bash
cd signal && npm install && npm start
```

### 2. 启动受控端（Host）

```bash
cd host
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python host.py
```

> Windows 需以登录用户会话运行，并授予 UAC 权限以便控制键鼠。

### 3. 启动控制端（Client）

```bash
cd client
flutter pub get
flutter run
```

在 Android 设备上运行，确保与 Host 在同一局域网。

## 配置

| 配置项 | 位置 | 默认值 |
|--------|------|--------|
| 信令服务器地址 | `client/lib/main.dart` → `AppConfig.signalUrl` | `ws://<SERVER_IP>:8080` |
| 信令端口 | `signal/server.js` → `PORT` 环境变量 | `8080` |
| Host 信令地址 | `host/host.py` → `SIGNAL_URL` 环境变量 | `ws://127.0.0.1:8080` |

Client 支持在应用内通过"设置"按钮动态修改服务器地址，保存到 `config.json`。

## 技术栈

- **信令服务器**：Node.js, ws
- **受控端**：Python, aiortc, pyautogui, mss, opencv-python
- **控制端**：Flutter, flutter_webrtc, web_socket_channel

## 注意事项

- 三端须在同一局域网，默认使用 **8080** 端口
- Windows 防火墙需放行 8080 端口
- Host 屏幕分辨率会自动发送给 Client，坐标映射自适应
- 修改端口时需同步更新 `signal/server.js`、`host/host.py`、`client/lib/main.dart`
