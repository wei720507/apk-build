// 老人端主界面二维码组件（v12：Wi-Fi 地址优选 + 自动刷新 + 直连端口自检）
//
// 二维码内容格式（不含任何服务器信息，纯直连）：
//     RDCDIRECT|<最佳地址>|<备用地址>|pwd=family2026
// 控制端扫码后取第一个地址，由 connect() 直接 P2P 连接。
//
// ── 为什么必须做「接口优选」（v12 关键修复）────────────────────────────
// 安卓手机同时开着 Wi-Fi 和移动数据时，NetworkInterface.list() 返回的接口里，
// 蜂窝接口(rmnet_data0)常常排在 wlan0 **前面**，而两者都是私网地址
// （蜂窝是 10.x.x.x 的运营商 NAT 地址，Wi-Fi 是 192.168.x.x）。
// 旧版直接把第一个私网地址编进二维码 → 控制端拿到的是手机流量卡的 10.x 地址
// → 在同一个 Wi-Fi 下根本路由不到 → 永远"正在连接"。这解释了多轮失败的很大一部分。
// v12 按「接口类型 + 地址族」打分排序，wlan 的 IPv4 永远排第一。
//
// ── 另外两个必备前提 ──────────────────────────────────────────────────
// 1) 老人端「屏幕共享服务」必须运行，否则 Rust 核心不会启用 FFI.startServer，
//    直连端口(21118)根本不监听。v11 起在 initState 自动调用 startService()，
//    等效于手动点一次「启动服务」（会弹安卓系统"屏幕录制"授权框，需点允许）。
// 2) direct-server=Y 由 hardconfig.dart 在启动时设置。
//
// ── v12 新增自检 ──────────────────────────────────────────────────────
// 每 3 秒重新采集地址 + 主动 TCP 探测 127.0.0.1:端口，把"端口到底有没有在监听"
// 直接显示在屏幕上（这是唯一不会骗人的判据），方便一眼定位卡在哪一步。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart' as pm;
import 'package:flutter_hbb/custom/secure_binding.dart';
import 'package:flutter_hbb/custom/hardconfig.dart';
import 'package:flutter/services.dart';

/// 候选地址：接口名 + 地址 + 优先级 + 是否局域网 + 可读说明
class _Addr {
  final String iface;
  final String addr; // ip:port 或 [ipv6]:port
  final String ip;
  final bool isV6;
  final bool isLan;
  final int rank; // 越小越优
  _Addr(this.iface, this.addr, this.ip, this.isV6, this.isLan, this.rank);

  String get label => isLan ? '局域网' : (isV6 ? '公网IPv6' : '公网IPv4');
}

class ElderQRCode extends StatefulWidget {
  const ElderQRCode({super.key});

  @override
  State<ElderQRCode> createState() => _ElderQRCodeState();
}

class _ElderQRCodeState extends State<ElderQRCode> with WidgetsBindingObserver {
  List<_Addr> _candidates = [];
  bool _loading = true;

  // 输入控制（无障碍 RustDesk Input）状态 —— 协助机能否触控老人的关键
  bool? _inputEnabled;
  Timer? _inputTimer;

  // 直连监听诊断
  String _directServer = '';
  String _listenPort = '21118';
  bool _portListening = false; // 唯一可信判据：本机 TCP 能否连上直连端口

  // 屏幕共享服务
  bool _serviceStarted = false;
  int _startAttempts = 0;

  Timer? _timer;
  String _lastQrData = '';
  bool _inited = false;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _checkInput();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    // 首帧之后再启动服务：startService() 会 notifyListeners()，
    // 在 build 阶段调用会触发 "markNeedsBuild during build"。
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureService());
    // 每 3 秒刷新一次：网络切换 / 地址变化 / 服务启动后端口打开，
    // 二维码与自检状态都能自动跟上，不用重启 App。
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _inputTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkInput();
  }

  Future<void> _checkInput() async {
    try {
      final r = await const MethodChannel('mChannel').invokeMethod('get_input_control_enabled');
      if (mounted) setState(() => _inputEnabled = r == true);
    } catch (_) {
      if (mounted) setState(() => _inputEnabled = false);
    }
  }

  Future<void> _openInputSettings() async {
    try {
      await const MethodChannel('mChannel').invokeMethod('open_accessibility_settings');
    } catch (_) {}
    _inputTimer?.cancel();
    _inputTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _checkInput();
      if (_inputEnabled == true) _inputTimer?.cancel();
    });
  }

  /// 启动「屏幕共享服务」（= 首页那个「启动服务」按钮）。
  ///
  /// 只有服务起来，MainService.onCreate() 里的 FFI.startServer() 才会执行，
  /// 直连端口才会真正打开。安卓强制要求用户点一次系统「屏幕录制」授权框，
  /// 这一段无法用代码静默完成——所以这里同时提供手动重试按钮。
  Future<void> _ensureService() async {
    if (_portListening) return;
    try {
      if (!gFFI.serverModel.isStart) {
        // 与首页「启动服务」一致的前置权限，缺了服务可能起不来
        try {
          await gFFI.serverModel.checkRequestNotificationPermission();
        } catch (_) {}
        try {
          if (pm.bind.mainGetLocalOption(key: 'disable-floating-window') != 'Y') {
            await gFFI.serverModel.checkFloatingWindowPermission();
          }
        } catch (_) {}

        await gFFI.serverModel.startService();
        // 兜底：强制把 direct-server=Y 写进运行时配置。
        // hardconfig.dart 在启动时也会设，但万一其时序/生效路径有偏差，
        // 这里再显式写一次，确保 direct_server() 的监听前置条件一定满足。
        try {
          await pm.bind.mainSetOption(key: 'direct-server', value: 'Y');
        } catch (_) {}
        // 服务起来后给系统一点时间绑定，再刷新一次自检
        await Future.delayed(const Duration(seconds: 1));
      }
      if (mounted) {
        setState(() {
          _serviceStarted = gFFI.serverModel.isStart;
          _startAttempts++;
        });
      }
      await _refresh(forceProbe: true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _serviceStarted = gFFI.serverModel.isStart;
          _startAttempts++;
        });
      }
    }
  }

  /// 采集本机可用于直连的地址（按接口类型 + 地址族排序）。
  Future<void> _refresh({bool forceProbe = false}) async {
    final cands = <_Addr>[];
    bool listening = false;
    String ds = _directServer;
    String port = _listenPort;
    try {
      final portRaw = pm.bind.mainGetOptionSync(key: 'direct-access-port');
      port = portRaw.isNotEmpty ? portRaw : '21118';
      ds = pm.bind.mainGetOptionSync(key: 'direct-server');

      // ---- IPv4 ----
      final v4 = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in v4) {
        for (final a in iface.addresses) {
          final ip = a.address;
          if (ip.startsWith('169.254') || ip == '0.0.0.0') continue;
          final lan = _isPrivateV4(ip);
          cands.add(_Addr(iface.name, '$ip:$port', ip, false, lan,
              _rank(iface.name, false)));
        }
      }

      // ---- IPv6 ----
      final v6 = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv6,
      );
      for (final iface in v6) {
        for (final a in iface.addresses) {
          final ip = a.address.split('%').first; // 去掉 %iface 后缀
          if (ip.startsWith('fe80') || ip == '::1' || ip == '::') continue;
          final lan = _isPrivateV6(ip);
          cands.add(_Addr(iface.name, '[$ip]:$port', ip, true, lan,
              _rank(iface.name, true)));
        }
      }

      cands.sort((x, y) => x.rank.compareTo(y.rank));

      // ---- 直连端口自检（本机 TCP 连自己的直连端口）----
      _tick++;
      // 每 6 秒探测一次即可（避免高频自连），启动服务后强制立刻探一次
      if (forceProbe || _tick.isOdd || _tick <= 1) {
        listening = await _probePort(port, cands);
      } else {
        listening = _portListening;
      }
    } catch (_) {
      // 采集失败时保留空列表，UI 会提示
    }

    final newQr = _buildQrData(cands);
    if (!mounted) return;
    // 只有内容真变了才 setState，避免二维码每 3 秒无谓重绘闪烁；
    // 但首次必须无条件刷新一次，否则会卡在 loading 圆圈上。
    if (!_inited ||
        cands.length != _candidates.length ||
        newQr != _lastQrData ||
        listening != _portListening ||
        ds != _directServer ||
        port != _listenPort) {
      setState(() {
        _candidates = cands;
        _portListening = listening;
        _directServer = ds;
        _listenPort = port;
        _lastQrData = newQr;
        _loading = false;
        _inited = true;
        _serviceStarted = gFFI.serverModel.isStart;
      });
    } else {
      _candidates = cands;
    }
  }

  /// 本机 TCP 探测直连端口：能连上 = 端口在监听 = 服务已真正跑起来。
  ///
  /// 先试回环地址；个别实现只绑在具体网卡上，再退化为试第一个业务地址，
  /// 避免"明明在监听却报未监听"的误判。
  Future<bool> _probePort(String port, List<_Addr> cands) async {
    final p = int.tryParse(port);
    if (p == null) return false;
    if (await _tryConnect(InternetAddress.loopbackIPv4, p)) return true;
    for (final c in cands.take(2)) {
      final ip = InternetAddress.tryParse(c.ip);
      if (ip == null) continue;
      if (await _tryConnect(ip, p)) return true;
    }
    return false;
  }

  Future<bool> _tryConnect(InternetAddress ip, int port) async {
    try {
      final s = await Socket.connect(ip, port,
          timeout: const Duration(milliseconds: 900));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 接口打分：越小越优先。wlan 的 IPv4 最优；蜂窝接口排最后。
  int _rank(String ifaceName, bool isV6) {
    final n = ifaceName.toLowerCase();
    final isWifi = n.startsWith('wlan') ||
        n.startsWith('swlan') ||
        n.startsWith('ap') ||
        n.startsWith('p2p');
    final isCell = n.startsWith('rmnet') ||
        n.startsWith('ccmni') ||
        n.startsWith('pdp') ||
        n.startsWith('seth') ||
        n.startsWith('wwan') ||
        n.startsWith('clat');
    if (isWifi) return isV6 ? 1 : 0; // Wi-Fi 的 IPv4 永远第一
    if (isCell) return isV6 ? 5 : 4; // 流量卡地址最不可达
    return isV6 ? 3 : 2; // eth/usb 等其它接口居中
  }

  bool _isPrivateV4(String ip) {
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('192.168.')) return true;
    if (ip.startsWith('172.')) {
      final seg = int.tryParse(ip.split('.').elementAt(1));
      if (seg != null && seg >= 16 && seg <= 31) return true;
    }
    return false;
  }

  bool _isPrivateV6(String ip) {
    // 唯一本地地址 (ULA) 视为私网
    if (ip.startsWith('fc') || ip.startsWith('fd')) return true;
    return false;
  }

  /// 构造二维码内容：RDCDIRECT|<主用地址>|<备用地址>|pwd=<password>
  ///
  /// v14 关键修正：只编**直连地址**，绝不编 ID。原因（实测踩坑）：
  ///   - 编 ID → 控制端 `connect(id)` 必须走 RustDesk 官方协调/中继服务器；
  ///     而官方服务器在中国**禁止"控制手机"类连接**（`Access to mobile devices is
  ///     restricted in your country`），必被拒 → 扫码连不上。
  ///   - 编地址（`192.168.0.x:21118` / `[2409:...]:21118`）→ 客户端判定为地址、
  ///     走纯 P2P 直连，一个服务器都不碰，绝不报那个错，同 Wi-Fi / 跨网(公网IPv6)都通。
  /// 地址排序：主用=局域网 IPv4（同 Wi-Fi 最快），备用=公网 IPv6（跨网络直连）。
  String _buildQrData(List<_Addr> cands) {
    final picks = <String>[];
    // 1) 主用：局域网 IPv4
    for (final c in cands) {
      if (c.isLan && !c.isV6 && !picks.contains(c.addr)) {
        picks.add(c.addr);
        break;
      }
    }
    // 2) 备用：公网 IPv6（跨网络直连）
    for (final c in cands) {
      if (c.isV6 && !c.isLan && !picks.contains(c.addr)) {
        picks.add(c.addr);
        if (picks.length >= 2) break;
      }
    }
    // 3) 兜底：其余地址补齐到 2 个
    for (final c in cands) {
      if (!picks.contains(c.addr)) picks.add(c.addr);
      if (picks.length >= 2) break;
    }
    if (picks.isEmpty) return '';
    return 'RDCDIRECT|${picks.join('|')}|pwd=$kFamilyPassword';
  }

  @override
  Widget build(BuildContext context) {
    final id = gFFI.serverModel.serverId.value.text;
    final qrData = _lastQrData;

    // 二维码内容：优先直连地址串；地址未就绪时退回 ID（仅占位，不能直连）
    final data = qrData.isNotEmpty
        ? qrData
        : '{"id":"$id","role":"elder","ts":${DateTime.now().millisecondsSinceEpoch}}';

    final okColor = _portListening ? Colors.green : Colors.redAccent;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: _portListening ? Colors.green.shade300 : Colors.blue.shade200,
            width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.blue.shade600,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              '老人端 · 被控（只能被家人协助）',
              style: TextStyle(fontSize: 14, color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '家人扫码即可直连',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            '打开控制端 → 主界面右下角扫一扫 → 扫本码即直连',
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 16),

          // 二维码
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: _loading
                ? const SizedBox(
                    width: 220,
                    height: 220,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : QrImageView(
                    data: data,
                    version: QrVersions.auto,
                    size: 220,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black87,
                    ),
                  ),
          ),
          const SizedBox(height: 12),

          // ── 自检结果（每 3 秒刷新）────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _portListening
                  ? Colors.green.withAlpha(20)
                  : Colors.red.withAlpha(18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _portListening
                      ? '✅ 直连端口 $_listenPort 已监听，可以扫码连接'
                      : '❌ 直连端口 $_listenPort 未监听（服务没启动，控制端一定连不上）',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: okColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '共享服务：${_serviceStarted ? "已启动" : "未启动"}　'
                  'direct-server=${_directServer.isEmpty ? "?" : _directServer}　'
                  '端口=$_listenPort',
                  style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                      fontFamily: 'monospace'),
                ),
                if (_candidates.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '主用地址：${_candidates.first.addr}　(${_candidates.first.iface}·${_candidates.first.label})',
                    style: const TextStyle(
                        fontSize: 12,
                        color: Colors.blueGrey,
                        fontFamily: 'monospace'),
                  ),
                  if (_candidates.length > 1)
                    Text(
                      '备用地址：${_candidates[1].addr}　(${_candidates[1].iface}·${_candidates[1].label})',
                      style: const TextStyle(
                          fontSize: 12,
                          color: Colors.blueGrey,
                          fontFamily: 'monospace'),
                    ),
                ] else
                  const Text(
                    '正在获取本机网络地址…',
                    style: TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                const SizedBox(height: 4),
                Text(
                  _candidates.any((c) => !c.isLan)
                      ? '含公网地址，可跨网络直连；同 Wi-Fi 时用主用地址'
                      : '当前仅局域网地址，需两台手机连同一 Wi-Fi',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),

      // ── 输入控制状态（协助机能否触控老人的关键）────────────
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _inputEnabled == true
              ? Colors.green.withAlpha(20)
              : Colors.orange.withAlpha(22),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _inputEnabled == true
                  ? '✅ 输入控制已开启 → 协助机可以触控您的手机'
                  : (_inputEnabled == false
                      ? '⚠️ 输入控制未开启 → 协助机只能看、不能动'
                      : '⌛ 正在检测输入控制状态…'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: _inputEnabled == true
                    ? Colors.green.shade700
                    : Colors.orange.shade800,
              ),
            ),
            if (_inputEnabled != true) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _openInputSettings,
                  icon: const Icon(Icons.touch_app),
                  label: const Text('去开启输入控制（系统设置 → 无障碍 → RustDesk Input）'),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '开启后本页会自动变绿；若开关点不开，是手机“受限设置”拦截：长按本 App 图标→应用信息→右上角 ⋮ → 授予受限权限，再回来开启',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ],
        ),
      ),

      const SizedBox(height: 10),

          // 未监听时给一个明显的手动启动入口（老人/家人一键点）
          if (!_portListening) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _ensureService,
                icon: const Icon(Icons.play_circle_outline),
                label: Text(_startAttempts == 0
                    ? '启动共享服务（会弹系统授权框，请点“允许”）'
                    : '再次启动共享服务（点了几次=$_startAttempts）'),
              ),
            ),
          ],

          const SizedBox(height: 12),
          Text(
            'ID: $id',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
