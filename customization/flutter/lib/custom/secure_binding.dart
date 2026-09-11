// 一对一绑定核心（定制层）
//
// 安全模型：老人机只接受「被锁定的那一台助手机」连入。
// 绑定依据是 RustDesk 的对端 ID（peerId），它由助手机的密钥对派生，
// 外人即使通过某种方式知道了老人机的 ID，也无法用别的设备连入——
// 因为 peerId 不匹配会被直接拒绝，且不会弹出任何授权窗口（防社工/防骚扰）。
//
// 绑定时机：老人首次手动「允许」某个连接后，就把该 peerId 写死。
// 之后换手机/重置：调用 BindingStore.unbind()（可在设置页加按钮，见文档）。

import 'package:flutter_hbb/models/platform_model.dart' as pm;

class BindingStore {
  static const String _kBoundPeer = 'elder_bound_helper_peer';
  static const String _kBoundTs = 'elder_bound_helper_ts';

  /// 读取已绑定的助手机 peerId；未绑定返回 null。
  static String? getBoundPeer() {
    final v = pm.bind.mainGetLocalOption(key: _kBoundPeer);
    return (v.isEmpty) ? null : v;
  }

  /// 是否已绑定到指定 peerId。
  static bool isBoundTo(String peerId) => getBoundPeer() == peerId;

  /// 读取绑定时间（ISO8601 字符串）；未绑定返回 null。
  static String? getBoundTs() {
    final v = pm.bind.mainGetLocalOption(key: _kBoundTs);
    return (v.isEmpty) ? null : v;
  }

  /// 当前 App 角色是否为「老人端」。
  /// 助手机(ROLE=helper) 不显示解绑入口；其余(默认/elder)即老人端。
  static bool get isElder =>
      const String.fromEnvironment('ROLE', defaultValue: 'elder') != 'helper';

  /// 绑定到指定 peerId（仅在老人手动「允许」首次连接时调用）。
  static void bind(String peerId) {
    pm.bind.mainSetLocalOption(key: _kBoundPeer, value: peerId);
    pm.bind.mainSetLocalOption(
        key: _kBoundTs, value: DateTime.now().toIso8601String());
  }

  /// 解除绑定（换手机 / 重置时调用）。
  static void unbind() {
    pm.bind.mainSetLocalOption(key: _kBoundPeer, value: '');
    pm.bind.mainSetLocalOption(key: _kBoundTs, value: '');
  }

  /// 设置页 tile 用的简短状态文案。
  static String summaryText() {
    return (getBoundPeer()?.isEmpty ?? true) ? '未绑定' : '已绑定（一对一）';
  }

  /// 管理弹窗内展示的详情（含绑定设备 ID 与时间）。
  static String detailText() {
    final p = getBoundPeer();
    if (p == null || p.isEmpty) {
      return '当前未绑定任何设备。\n下次有人请求控制时，需您本人手动点「允许」才会建立绑定。';
    }
    final ts = getBoundTs();
    final when = (ts == null || ts.isEmpty) ? '' : '\n绑定时间：$ts';
    return '已绑定一位家人（一对一）\n设备 ID：$p$when\n\n'
        '解除绑定后，任何人都可以请求控制您的手机，每次都需要您本人手动「允许」。';
  }

  // ===== 老板端（控制侧）：绑定的老人机 =====

  static const String _kBoundElder = 'helper_bound_elder_peer';
  static const String _kBoundElderTs = 'helper_bound_elder_ts';

  /// 读取已绑定的老人机 peerId；未绑定返回 null。
  static String? getBoundElderPeer() {
    final v = pm.bind.mainGetLocalOption(key: _kBoundElder);
    return (v.isEmpty) ? null : v;
  }

  /// 读取绑定时间（ISO8601）；未绑定返回 null。
  static String? getBoundElderTs() {
    final v = pm.bind.mainGetLocalOption(key: _kBoundElderTs);
    return (v.isEmpty) ? null : v;
  }

  /// 仅当尚未绑定时，绑定当前连接的老人机（一对一：不覆盖既有绑定）。
  /// 在控制侧 RemotePage.initState（连接成功打开远程界面）时调用。
  static void bindElderIfUnbound(String elderPeerId) {
    final existing = getBoundElderPeer();
    if (existing == null || existing.isEmpty) {
      pm.bind.mainSetLocalOption(key: _kBoundElder, value: elderPeerId);
      pm.bind.mainSetLocalOption(
          key: _kBoundElderTs, value: DateTime.now().toIso8601String());
    }
  }

  /// 强制重新绑定（替换既有绑定）。用于「换绑另一台老人机」场景，
  /// 经老板端「确认绑定」对话框二次确认后调用。
  static void rebindElder(String elderPeerId) {
    pm.bind.mainSetLocalOption(key: _kBoundElder, value: elderPeerId);
    pm.bind.mainSetLocalOption(
        key: _kBoundElderTs, value: DateTime.now().toIso8601String());
  }

  /// 解除老人机绑定（换绑/重新配对时调用）。
  static void unbindElder() {
    pm.bind.mainSetLocalOption(key: _kBoundElder, value: '');
    pm.bind.mainSetLocalOption(key: _kBoundElderTs, value: '');
  }

  /// 当前连接的设备是否就是已绑定的老人机（用于远程界面顶部状态条）。
  static bool isCurrentElder(String peerId) {
    final b = getBoundElderPeer();
    return b != null && b.isNotEmpty && b == peerId;
  }

  static String elderSummaryText() {
    return (getBoundElderPeer()?.isEmpty ?? true) ? '未绑定' : '已绑定老人机';
  }

  static String elderDetailText() {
    final p = getBoundElderPeer();
    if (p == null || p.isEmpty) {
      return '当前未绑定任何老人机。\n连接老人机并成功进入远程界面后，会自动绑定该设备（一对一）。';
    }
    final ts = getBoundElderTs();
    final when = (ts == null || ts.isEmpty) ? '' : '\n绑定时间：$ts';
    return '已绑定一位家人（一对一）\n老人机 ID：$p$when\n\n'
        '解除绑定后，下次连接不会自动绑定，需您重新连接后再绑定。';
  }
}
