// 绑定管理 UI（定制层）
//
// 入口：设置页里的「绑定管理」/「已绑定的老人机」按钮。
// 该文件同时服务两端：
//   - 老人端(ROLE!=helper)：展示「谁绑定了我」并提供「解除绑定」。
//   - 老板端(ROLE=helper)：展示「我绑定了哪台老人机」并提供「解除绑定」；
//     另外 helperBindingBanner() 在远程控制界面顶部给出一眼可辨的状态条。
//
// 注意：解除绑定只影响「未来的连接」；正在进行的远程协助不会被打断。

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/custom/secure_binding.dart';

/// 绑定状态变化通知器：绑定/解绑后触发状态条重建（跨 widget 树刷新）。
final ValueNotifier<int> elderBindTick = ValueNotifier<int>(0);

/// 通知状态条刷新（绑定/解绑后调用）。
void notifyElderBindChanged() => elderBindTick.value++;

/// 设置页统一入口：按角色分流到对应弹窗。
Future<void> showBindingManagementDialog(BuildContext context) async {
  if (BindingStore.isElder) {
    await _showElderDialog(context);
  } else {
    await _showHelperDialog(context);
  }
}

/// 老板端首次连接某台老人机时的「确认绑定」对话框（防误连陌生人）。
///
/// - 仅当尚未绑定才会在进入远程界面时自动弹出（见 remote_page.initState）。
/// - 点「确认绑定」才建立一对一绑定；点「取消」则保持未绑定，状态条保持橙色提示。
/// - 若已绑定另一台（换绑场景），会明确提示「将替换原有绑定」。
Future<void> confirmBindElderDialog(
    BuildContext context, String id, VoidCallback onBound) async {
  final existing = BindingStore.getBoundElderPeer();
  final isRebind = existing != null && existing.isNotEmpty && existing != id;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.verified_user, color: Colors.orange),
          SizedBox(width: 8),
          Expanded(
            child: Text('确认绑定此老人机？', style: TextStyle(fontSize: 20)),
          ),
        ],
      ),
      content: Text(
        isRebind
            ? '当前已绑定另一台老人机（$existing）。\n\n'
                '确认将此设备（$id）设为新的绑定对象吗？\n此操作会替换原有绑定。'
            : '请确认当前连接的是您家人（老人）的手机，再建立一对一绑定。\n\n'
                '设备 ID：$id\n\n'
                '绑定后，今后只有此设备可被您远程控制；其他设备连入会被拒绝。',
        style: const TextStyle(fontSize: 16, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消', style: TextStyle(fontSize: 18)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('确认绑定', style: TextStyle(fontSize: 18)),
        ),
      ],
    ),
  );
  if (result == true) {
    if (isRebind) {
      BindingStore.rebindElder(id);
    } else {
      BindingStore.bindElderIfUnbound(id);
    }
    onBound();
  }
}

/// 老人端「绑定管理」弹窗。
Future<void> _showElderDialog(BuildContext context) async {
  await showDialog(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx2, setState) {
          final bound = BindingStore.getBoundPeer();
          final isBound = bound != null && bound.isNotEmpty;

          return AlertDialog(
            title: const Text('绑定管理',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(
              child: Text(BindingStore.detailText(),
                  style: const TextStyle(fontSize: 16, height: 1.5)),
            ),
            actions: [
              if (isBound)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: ctx2,
                      builder: (c) => AlertDialog(
                        title: const Text('确定解除绑定？',
                            style: TextStyle(fontSize: 20)),
                        content: const Text(
                            '解除绑定后，任何人都可以请求控制您的手机，'
                            '每次都需要您本人手动点「允许」。\n\n确定要继续吗？',
                            style: TextStyle(fontSize: 16, height: 1.5)),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(c).pop(false),
                            child: const Text('取消', style: TextStyle(fontSize: 18)),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.red),
                            onPressed: () => Navigator.of(c).pop(true),
                            child:
                                const Text('解除绑定', style: TextStyle(fontSize: 18)),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      BindingStore.unbind();
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已解除绑定')),
                      );
                    }
                  },
                  child: const Text('解除绑定', style: TextStyle(fontSize: 18)),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx2).pop(),
                child: const Text('关闭', style: TextStyle(fontSize: 18)),
              ),
            ],
          );
        },
      );
    },
  );
}

/// 老板端「已绑定的老人机」弹窗。
Future<void> _showHelperDialog(BuildContext context) async {
  await showDialog(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx2, setState) {
          final bound = BindingStore.getBoundElderPeer();
          final isBound = bound != null && bound.isNotEmpty;

          return AlertDialog(
            title: const Text('已绑定的老人机',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(
              child: Text(BindingStore.elderDetailText(),
                  style: const TextStyle(fontSize: 16, height: 1.5)),
            ),
            actions: [
              if (isBound)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: ctx2,
                      builder: (c) => AlertDialog(
                        title: const Text('确定解除绑定？',
                            style: TextStyle(fontSize: 20)),
                        content: const Text(
                            '解除绑定后，下次连接老人机不会自动绑定。\n'
                            '如需换绑另一台老人机，解除后重新连接即可。\n\n确定要继续吗？',
                            style: TextStyle(fontSize: 16, height: 1.5)),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(c).pop(false),
                            child: const Text('取消', style: TextStyle(fontSize: 18)),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.red),
                            onPressed: () => Navigator.of(c).pop(true),
                            child:
                                const Text('解除绑定', style: TextStyle(fontSize: 18)),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      BindingStore.unbindElder();
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已解除绑定')),
                      );
                    }
                  },
                  child: const Text('解除绑定', style: TextStyle(fontSize: 18)),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx2).pop(),
                child: const Text('关闭', style: TextStyle(fontSize: 18)),
              ),
            ],
          );
        },
      );
    },
  );
}

/// 远程控制界面（老板端）顶部的「绑定状态条」。
/// 仅老板端显示；进入远程界面时若未绑定会弹确认框（见 remote_page.initState）。
/// 绑定/解绑后会随 [elderBindTick] 自动重建，无需手动 setState。
/// 返回 Column：顶部一条状态条 + 原始远程画面。
Widget helperBindingBanner(String id, Widget child) {
  if (BindingStore.isElder) return child;

  return Column(
    children: [
      ValueListenableBuilder<int>(
        valueListenable: elderBindTick,
        builder: (ctx, _, __) {
          final bound = BindingStore.getBoundElderPeer();
          final hasBound = bound != null && bound.isNotEmpty;
          final matched = hasBound && bound == id;

          final String text;
          final Color bg;
          final bool showConfirm;
          if (matched) {
            text = '已绑定此老人机 ✓';
            bg = Colors.green.shade700;
            showConfirm = false;
          } else if (!hasBound) {
            text = '未绑定（首次连接，请确认是您的家人）';
            bg = Colors.orange.shade700;
            showConfirm = true;
          } else {
            text = '⚠ 当前连接的不是已绑定的老人机';
            bg = Colors.red.shade700;
            showConfirm = false;
          }

          return Container(
            width: double.infinity,
            color: bg,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                if (showConfirm)
                  TextButton(
                    onPressed: () =>
                        confirmBindElderDialog(ctx, id, notifyElderBindChanged),
                    child: const Text(
                      '确认绑定',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
      Expanded(child: child),
    ],
  );
}
