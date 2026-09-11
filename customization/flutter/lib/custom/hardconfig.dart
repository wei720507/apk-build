// 私有化 / 硬编码配置（定制层）
//
// 目标：确保「不用公共服务器、端到端、一对一」。
//  - 不再强制清空 rendezvous/relay/api 服务器（清空=回退官方rs-ny，不可达）。
//    改为保留默认/由用户配置，依赖 LAN discovery（同Wi-Fi直连）或自定义服务器。
//  - 关闭「允许通过深链接/二维码修改服务器」开关，防止被社工诱导指向第三方。
//  - 老人端免登录、出二维码（由 elder_qr_code + home_page 注入实现）。
//  - 老人端开启直接IP访问 + 设定固定连接密码（控制端扫码自动带入，老人不用输）。

import 'package:flutter_hbb/models/platform_model.dart' as pm;
import 'package:flutter_hbb/custom/secure_binding.dart';

/// 家庭远程调试固定连接密码。
/// 控制端扫码后自动带入此密码，老人端不需要手动输入。
/// 如需更换，同步改此常量与 elder_qr_code.dart 里的即可。
const String kFamilyPassword = 'family2026';

/// 应用启动时应用私有化配置。在 runMobileApp -> initEnv 之后调用，
/// 此时全局 FFI（bind）已就绪。
Future<void> applyHardcodedConfig() async {
  // 1) 安全选项：不允许通过深链接/二维码修改服务器，防社工
  await pm.bind.mainSetOption(key: 'allow-deep-link-server-settings', value: 'N');

  // 2) 老人端（被控端）专属配置
  if (BindingStore.isElder) {
    // 2a) 开启「直接IP访问」(direct-server)，默认 N(关闭)。
    //     没开时老人端不在直连端口上监听 → 控制端一直"正在连接"、老人端无反应。
    await pm.bind.mainSetOption(key: 'direct-server', value: 'Y');

    // 2b) 直连端口默认 21118（与二维码里使用的端口保持一致）
    final dap = pm.bind.mainGetOptionSync(key: 'direct-access-port');
    if (dap.isEmpty) {
      await pm.bind.mainSetOption(key: 'direct-access-port', value: '21118');
    }

    // 2c) 设定固定连接密码。
    //     RustDesk 直连（IP:port）也要求密码认证；不设密码时控制端走 URI 路径
    //     会因 password=null 静默卡在"正在连接"（移动端无弹窗上下文）。
    //     此密码编入二维码，控制端扫码自动带入，老人无需记忆/输入。
    await pm.bind.mainSetOption(key: 'password', value: kFamilyPassword);

    // 2d) 关闭「仅允许有密码的入站连接」——我们的安全模型是
    //     一对一绑定 + 老人点按授权（elderGuardIncoming），不靠密码防陌生人。
    //     如果此项默认 Y 且没密码时会拒绝所有连接，必须显式关闭。
    await pm.bind.mainSetOption(key: 'access-security-mode', value: 'N');
  }

  // 注意：不再清空 custom-rendezvous-server / relay-server / api-server。
  // 清空会导致回退到官方 rs-ny.rustdesk.com（国内不可达）。
  // 同 Wi-Fi 下 LAN discovery 可自动发现设备；跨网络需配可达的协调服务器。
}
