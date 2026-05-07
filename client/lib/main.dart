import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/services.dart';

const String CONFIG_FILE = 'config.json';

class AppConfig {
  static String signalUrl = 'ws://<SERVER_IP>:8080';

  static Future<void> load() async {
    try {
      final file = File(CONFIG_FILE);
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        signalUrl = data['signalUrl'] ?? signalUrl;
      }
    } catch (e) {
      print('Config load error: $e');
    }
  }

  static Future<void> save(String url) async {
    try {
      final file = File(CONFIG_FILE);
      await file.writeAsString(jsonEncode({'signalUrl': url}));
      signalUrl = url;
    } catch (e) {
      print('Config save error: $e');
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const RemoteDesktopApp());
}

class RemoteDesktopApp extends StatelessWidget {
  const RemoteDesktopApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '远程桌面',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFF76FF03),
          surface: Color(0xFF0D1B2A),
          onSurface: Color(0xFFE0E0E0),
        ),
        fontFamily: 'Roboto Mono',
      ),
      home: const RemoteDesktopPage(),
    );
  }
}

class RemoteDesktopPage extends StatefulWidget {
  const RemoteDesktopPage({Key? key}) : super(key: key);

  @override
  State<RemoteDesktopPage> createState() => _RemoteDesktopPageState();
}

class _RemoteDesktopPageState extends State<RemoteDesktopPage>
    with TickerProviderStateMixin {
  RTCPeerConnection? _pc;
  final _remoteRenderer = RTCVideoRenderer();
  late final WebSocketChannel _wsChannel;
  RTCDataChannel? _dataChannel;
  int _hostScreenWidth = 1920;
  int _hostScreenHeight = 1080;
  final _videoKey = GlobalKey();

  bool _isConnecting = true;
  bool _showControls = false;
  late AnimationController _pulseController;
  late AnimationController _slideController;
  late Animation<double> _slideAnimation;

  String _connectionStatus = '正在连接...';
  String _resolution = '';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _slideAnimation = CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    );

    _initRenderers();
    _setupSignaling();
  }

  Future<void> _initRenderers() async {
    await _remoteRenderer.initialize();
  }

  void _setupSignaling() {
    try {
      _wsChannel = WebSocketChannel.connect(Uri.parse(AppConfig.signalUrl));
      print('Attempting WS connection to ${AppConfig.signalUrl}');
      _wsChannel.sink.add(jsonEncode({'type': 'register', 'role': 'client'}));
      _setupConnection();
    } catch (e, st) {
      print('INIT ERROR: $e\n$st');
      setState(() {
        _connectionStatus = '连接失败';
      });
    }
  }

  Future<void> _setupConnection() async {
    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    };
    _pc = await createPeerConnection(config);

    _pc!.onTrack = (event) {
      if (event.track.kind == 'video' &&
          event.streams.isNotEmpty) {
        _setRemoteStream(event.streams[0]);
      }
    };

    _pc!.onAddStream = (stream) {
      _setRemoteStream(stream);
    };

    _pc!.onIceConnectionState = (state) {
      print('ICE connection state (client): $state');
      _updateConnectionStatus(state);
    };

    _dataChannel = await _pc!.createDataChannel('control', RTCDataChannelInit());
    print('DataChannel created');

    _dataChannel!.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary) return;
      try {
        final data = jsonDecode(message.text);
        if (data['type'] == 'screen_info') {
          setState(() {
            _hostScreenWidth = data['width'];
            _hostScreenHeight = data['height'];
            _resolution = '${_hostScreenWidth}x${_hostScreenHeight}';
          });
          print('Received host screen size: $_hostScreenWidth x $_hostScreenHeight');
        }
      } catch (e) {
        print('Error parsing DataChannel message: $e');
      }
    };

    _wsChannel.stream.listen((msg) {
      final data = jsonDecode(msg);
      if (data['type'] == 'answer') {
        _pc!.setRemoteDescription(RTCSessionDescription(data['sdp'], data['type']));
        print('Client received answer');
      } else if (data['type'] == 'candidate') {
        _pc!.addCandidate(RTCIceCandidate(
          data['candidate']['candidate'],
          data['candidate']['sdpMid'],
          data['candidate']['sdpMLineIndex'],
        ));
      }
    });

    print('Client creating offer...');
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    final localDesc = await _pc!.getLocalDescription();
    if (localDesc != null) {
      _wsChannel.sink.add(jsonEncode({
        'type': localDesc.type,
        'sdp': localDesc.sdp,
      }));
      print('Client sent offer: ${localDesc.type}');
    }
  }

  void _updateConnectionStatus(dynamic state) {
    setState(() {
      _connectionStatus = state.toString().split('.').last;
    });
  }

  void _setRemoteStream(MediaStream stream) {
    print('Setting remote stream to renderer: ${stream.id}');
    _remoteRenderer.srcObject = stream;
    setState(() {
      _isConnecting = false;
      _resolution = '${_hostScreenWidth}x${_hostScreenHeight}';
    });
    _slideController.forward();
  }

  void _sendControl(String action, Map<String, dynamic> payload) {
    if (_dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      final msg = jsonEncode({
        'type': 'control',
        'payload': {'action': action, ...payload}
      });
      _dataChannel!.send(RTCDataChannelMessage(msg));
    }
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
  }

  void _showSettingsDialog() {
    final parts = AppConfig.signalUrl.replaceFirst('ws://', '').split(':');
    final ipController = TextEditingController(text: parts[0]);
    final portController =
        TextEditingController(text: parts.length > 1 ? parts[1] : '8080');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF1B3A5C), width: 1),
        ),
        title: const Text('服务器设置',
            style: TextStyle(color: Color(0xFFE0E0E0), fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ipController,
              style: const TextStyle(
                  color: Color(0xFFE0E0E0), fontFamily: 'Roboto Mono'),
              decoration: InputDecoration(
                labelText: 'IP地址',
                labelStyle: const TextStyle(color: Color(0xFF607D8B)),
                hintText: '例如: 192.168.1.100',
                hintStyle: const TextStyle(color: Color(0xFF455A64)),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1B3A5C)),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF00E5FF)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              style: const TextStyle(
                  color: Color(0xFFE0E0E0), fontFamily: 'Roboto Mono'),
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '端口',
                labelStyle: const TextStyle(color: Color(0xFF607D8B)),
                hintText: '默认: 8080',
                hintStyle: const TextStyle(color: Color(0xFF455A64)),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1B3A5C)),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF00E5FF)),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                const Text('取消', style: TextStyle(color: Color(0xFF607D8B))),
          ),
          TextButton(
            onPressed: () async {
              final ip = ipController.text.trim();
              final port = portController.text.trim();
              if (ip.isNotEmpty) {
                final url = 'ws://$ip:$port';
                await AppConfig.save(url);
                if (mounted) Navigator.pop(context);
              }
            },
            child:
                const Text('保存', style: TextStyle(color: Color(0xFF00E5FF))),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _slideController.dispose();
    _remoteRenderer.dispose();
    _pc?.close();
    _wsChannel.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool hasVideo = _remoteRenderer.srcObject != null;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E17),
      body: Stack(
        children: [
          _buildBackgroundGrid(),
          Column(
            children: [
              _buildAppBar(),
              Expanded(
                child: Stack(
                  children: [
                    Center(
                      child: hasVideo
                          ? FadeTransition(
                              opacity: _slideAnimation,
                              child: _buildVideoDisplay(),
                            )
                          : _buildConnectingView(),
                    ),
                    if (hasVideo) _buildGestureLayer(),
                  ],
                ),
              ),
            ],
          ),
          if (_showControls) _buildControlPanel(),
        ],
      ),
    );
  }

  Widget _buildBackgroundGrid() {
    return CustomPaint(
      painter: _GridPainter(),
      size: Size.infinite,
    );
  }

  Widget _buildAppBar() {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B2A).withValues(alpha: 0.95),
        border: const Border(
          bottom: BorderSide(
            color: Color(0xFF1B3A5C),
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.6),
                width: 1.5,
              ),
            ),
            child: const Icon(
              Icons.desktop_windows,
              color: Color(0xFF00E5FF),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            '远程桌面控制',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFFE0E0E0),
              letterSpacing: 1.2,
            ),
          ),
          const Spacer(),
          _buildStatusIndicator(),
          const SizedBox(width: 16),
          if (_resolution.isNotEmpty) _buildInfoChip(_resolution),
          const SizedBox(width: 12),
          _buildIconButton(
            icon: Icons.settings,
            onTap: _showSettingsDialog,
            isActive: false,
          ),
          const SizedBox(width: 8),
          _buildIconButton(
            icon: Icons.tune,
            onTap: _toggleControls,
            isActive: _showControls,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIndicator() {
    final isConnected = !_isConnecting;
    return Row(
      children: [
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isConnected
                    ? const Color(0xFF76FF03)
                    : const Color(0xFFFF5252)
                        .withValues(alpha: 0.5 + 0.5 * _pulseController.value),
                boxShadow: isConnected
                    ? [
                        const BoxShadow(
                          color: Color(0xFF76FF03),
                          blurRadius: 6,
                          spreadRadius: 2,
                        )
                      ]
                    : null,
              ),
            );
          },
        ),
        const SizedBox(width: 8),
        Text(
          isConnected ? '已连接' : _connectionStatus,
          style: TextStyle(
            fontSize: 12,
            color: isConnected
                ? const Color(0xFF76FF03)
                : const Color(0xFFFF5252),
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1B3A5C),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: const Color(0xFF00E5FF).withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: Color(0xFF00E5FF),
          fontFamily: 'Roboto Mono',
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onTap,
    bool isActive = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0xFF00E5FF).withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive
                ? const Color(0xFF00E5FF).withValues(alpha: 0.5)
                : const Color(0xFF1B3A5C),
            width: 1,
          ),
        ),
        child: Icon(
          icon,
          color: isActive
              ? const Color(0xFF00E5FF)
              : const Color(0xFF607D8B),
          size: 18,
        ),
      ),
    );
  }

  Widget _buildVideoDisplay() {
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFF00E5FF).withValues(alpha: 0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.05),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AspectRatio(
          key: _videoKey,
          aspectRatio: _hostScreenWidth / _hostScreenHeight,
          child: RTCVideoView(
            _remoteRenderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          ),
        ),
      ),
    );
  }

  Widget _buildConnectingView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF00E5FF)
                          .withValues(alpha: 0.2 + 0.3 * _pulseController.value),
                      width: 2,
                    ),
                  ),
                ),
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF00E5FF)
                          .withValues(alpha: 0.4 + 0.4 * _pulseController.value),
                      width: 2,
                    ),
                  ),
                ),
                SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(
                      const Color(0xFF00E5FF).withValues(alpha: 0.8),
                    ),
                    strokeWidth: 2.5,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        Text(
          _connectionStatus,
          style: const TextStyle(
            fontSize: 14,
            color: Color(0xFFB0BEC5),
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          AppConfig.signalUrl,
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF546E7A),
            fontFamily: 'Roboto Mono',
          ),
        ),
      ],
    );
  }

  Widget _buildGestureLayer() {
    return Positioned.fill(
      child: GestureDetector(
        onTapDown: (details) {
          final videoRenderBox =
              _videoKey.currentContext?.findRenderObject() as RenderBox?;
          if (videoRenderBox == null) {
            print('ERROR: Video RenderBox not found!');
            return;
          }
          final videoSize = videoRenderBox.size;
          final videoOffset = videoRenderBox.localToGlobal(Offset.zero);
          final globalPos = details.globalPosition;

          double xInVideo =
              (globalPos.dx - videoOffset.dx).clamp(0.0, videoSize.width);
          double yInVideo =
              (globalPos.dy - videoOffset.dy).clamp(0.0, videoSize.height);

          final normalizedX = xInVideo / videoSize.width;
          final normalizedY = yInVideo / videoSize.height;

          final x = (normalizedX * _hostScreenWidth).toInt();
          final y = (normalizedY * _hostScreenHeight).toInt();

          print('=== Touch Debug ===');
          print(
              'Touch globalPos: (${globalPos.dx.toStringAsFixed(1)}, ${globalPos.dy.toStringAsFixed(1)})');
          print(
              'Video area: ${videoSize.width.toStringAsFixed(1)} x ${videoSize.height.toStringAsFixed(1)} at (${videoOffset.dx.toStringAsFixed(1)}, ${videoOffset.dy.toStringAsFixed(1)})');
          print(
              'In video: (${xInVideo.toStringAsFixed(1)}, ${yInVideo.toStringAsFixed(1)})');
          print(
              'Normalized: (${normalizedX.toStringAsFixed(3)}, ${normalizedY.toStringAsFixed(3)})');
          print(
              'Screen coord: ($x, $y) from ${_hostScreenWidth}x${_hostScreenHeight}');
          print('==================');

          if (x >= 0 &&
              x <= _hostScreenWidth &&
              y >= 0 &&
              y <= _hostScreenHeight) {
            _sendControl('move', {'x': x, 'y': y});
            _sendControl('click', {'button': 'left'});
          } else {
            print('WARN: Click outside screen bounds! (x=$x, y=$y)');
          }
        },
        behavior: HitTestBehavior.translucent,
        child: Container(color: Colors.transparent),
      ),
    );
  }

  Widget _buildControlPanel() {
    return Positioned(
      right: 0,
      top: 52,
      bottom: 0,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(_slideAnimation),
        child: Container(
          width: 240,
          decoration: BoxDecoration(
            color: const Color(0xFF0D1B2A).withValues(alpha: 0.95),
            border: const Border(
              left: BorderSide(
                color: Color(0xFF1B3A5C),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 12,
                offset: const Offset(-4, 0),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Color(0xFF1B3A5C),
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.tune,
                      color: Color(0xFF00E5FF),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      '控制面板',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE0E0E0),
                        letterSpacing: 0.8,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _toggleControls,
                      child: const Icon(
                        Icons.close,
                        color: Color(0xFF607D8B),
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
              _buildPanelSection(
                '连接信息',
                [
                  _buildInfoRow(
                      '状态', _isConnecting ? '连接中' : '已连接'),
                  _buildInfoRow('分辨率',
                      _resolution.isNotEmpty ? _resolution : '--'),
                  _buildInfoRow('信号服务器',
                      AppConfig.signalUrl.split('//').last),
                ],
              ),
              const Divider(color: Color(0xFF1B3A5C), height: 1),
              _buildPanelSection(
                '操作说明',
                [
                  _buildInfoRow('单击', '鼠标左键点击'),
                  _buildInfoRow(
                      '分辨率', '${_hostScreenWidth}x${_hostScreenHeight}'),
                ],
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: Color(0xFF1B3A5C),
                      width: 1,
                    ),
                  ),
                ),
                child: Column(
                  children: [
                    _buildActionButton(
                      icon: Icons.refresh,
                      label: '重新连接',
                      onTap: () {
                        // TODO: 实现重连逻辑
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildActionButton(
                      icon: Icons.power_settings_new,
                      label: '断开连接',
                      color: const Color(0xFFFF5252),
                      onTap: () {
                        // TODO: 实现断开逻辑
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPanelSection(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF00E5FF),
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF607D8B),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFB0BEC5),
                fontFamily: 'Roboto Mono',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = const Color(0xFF00E5FF),
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: color.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1B3A5C).withValues(alpha: 0.08)
      ..strokeWidth = 0.5;

    const spacing = 40.0;

    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
