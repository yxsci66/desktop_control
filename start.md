### 项目启动步骤

#### 1️⃣ 项目结构

```
desktop_control/
├─ signal/          # 信令服务器（Node.js + WebSocket）
│   └─ server.js
├─ host/            # 受控端（Python）
│   ├─ requirements.txt
│   ├─ host.py
│   └─ .venv/
└─ client/          # 控制端（Flutter）
    ├─ pubspec.yaml
    └─ lib/
        └─ main.dart
```

#### 2️⃣ 启动信令服务器

```bash
cd signal
npm install
npm start
```

#### 3️⃣ 启动受控端（Host）

```bash
cd host
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python host.py
```

> Windows 注意：必须在登录用户会话中运行，需要 UAC 权限控制鼠标/键盘。

#### 4️⃣ 启动控制端（Client）

```bash
cd client
flutter pub get
flutter run
```

> 在 Android 设备上运行，确保与 Host 在同一局域网。

#### 5️⃣ 配置说明

| 配置项 | 位置 | 默认值 |
|--------|------|--------|
| 信令服务器地址 | `client/lib/main.dart` 中 `AppConfig.signalUrl` | `ws://<SERVER_IP>:8080` |
| 信令服务器端口 | `signal/server.js` 中 `PORT` 环境变量 | `8080` |
| Host 信令地址 | `host/host.py` 中 `SIGNAL_URL` 环境变量 | `ws://127.0.0.1:8080` |

可在 Client 应用内通过"设置"按钮动态修改服务器地址，保存到 `config.json`。

#### 6️⃣ 验证

| 步骤 | 操作 | 预期结果 |
|------|------|----------|
| 1 | 启动 signal | 终端显示 `Signal server listening on ws://0.0.0.0:8080` |
| 2 | 启动 host | 控制台打印 `Connected to signal server` |
| 3 | 启动 client | Android 设备显示远端桌面实时视频 |
| 4 | 点击画面 | Windows 鼠标相应移动并点击 |

#### 7️⃣ 注意事项

- 三端须在同一局域网，默认端口 **8080**
- Windows 防火墙需放行 8080 端口
- Host 屏幕分辨率会自动发送给 Client，坐标映射自适应
- 修改端口时需同步更新 `signal/server.js`、`host/host.py`、`client/lib/main.dart`
