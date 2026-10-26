import 'package:flutter/material.dart';

import '../core/lan_scanner.dart';
import '../core/theme.dart';

/// 「发现局域网内设备」弹层。
///
/// 扫描本机所在网段，列出在 [port] 端口上提供fnOS服务的设备
/// （端口由登录页传入 —— 就是用户自己填的值，不内置默认端口），
/// 选中后返回 `host:port` 字符串，由登录页填进地址栏。
Future<String?> showLanDevicesSheet(
  BuildContext context, {
  required int port,
  required bool tls,
}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _LanDevicesSheet(port: port, tls: tls),
    );

class _LanDevicesSheet extends StatefulWidget {
  final int port;
  final bool tls;

  const _LanDevicesSheet({required this.port, required this.tls});

  @override
  State<_LanDevicesSheet> createState() => _LanDevicesSheetState();
}

class _LanDevicesSheetState extends State<_LanDevicesSheet> {
  bool _scanning = true;
  bool _cancel = false;
  List<LanDevice> _devices = const [];
  int _done = 0;
  int _total = 0;
  String? _fatal;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _cancel = true;
    super.dispose();
  }

  Future<void> _start() async {
    _cancel = false;
    setState(() {
      _scanning = true;
      _devices = const [];
      _done = 0;
      _total = 0;
      _fatal = null;
    });
    try {
      final r = await LanScanner.scan(
        port: widget.port,
        tls: widget.tls,
        onProgress: (d, t) {
          if (mounted) {
            setState(() {
              _done = d;
              _total = t;
            });
          }
        },
        isCancelled: () => _cancel,
      );
      if (!mounted) return;
      setState(() {
        _devices = r;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _fatal = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return SizedBox(
      height: h * 0.56,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('发现局域网内设备',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: FnosColors.textMain)),
            const SizedBox(height: 6),
            Text(
              _scanning
                  ? '正在扫描本网段 ${widget.port} 端口上的 NAS 设备…'
                  : '共发现 ${_devices.length} 台设备，点击即可填入地址',
              style: const TextStyle(fontSize: 12.5, color: FnosColors.textSub),
            ),
            const SizedBox(height: 12),
            if (_scanning) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 4,
                  value: _total == 0 ? null : _done / _total,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _total == 0 ? '正在获取本机网段…' : '已探测 $_done / $_total',
                style: const TextStyle(
                    fontSize: 11.5, color: FnosColors.textSub),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(child: _body()),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _scanning ? null : _start,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    side: const BorderSide(color: FnosColors.line),
                    foregroundColor: FnosColors.textMain,
                  ),
                  child: const Text('重新扫描'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44)),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_fatal != null) {
      return _hint(
        icon: Icons.error_outline,
        title: '扫描失败',
        desc: '$_fatal\n可改用手动输入地址。',
      );
    }
    if (_scanning && _devices.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_devices.isEmpty) {
      return _hint(
        icon: Icons.wifi_tethering_off_outlined,
        title: '未发现设备',
        desc: '请确认手机与 NAS 在同一个局域网，\n'
            '且 NAS 在 ${widget.port} 端口上提供服务。\n'
            '若端口不对，请返回修改端口后重新扫描。',
      );
    }
    return ListView.separated(
      itemCount: _devices.length,
      separatorBuilder: (_, _) => const Divider(height: 0.6),
      itemBuilder: (context, i) {
        final d = _devices[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0x142B7FFF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.dns_outlined,
                size: 20, color: FnosColors.primary),
          ),
          title: Text(d.host,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600)),
          subtitle: Text('端口 ${d.port} · 本网段 ${d.shortName}',
              style: const TextStyle(
                  fontSize: 12, color: FnosColors.textSub)),
          trailing: const Icon(Icons.chevron_right,
              size: 20, color: FnosColors.textSub),
          onTap: () => Navigator.pop(context, d.label),
        );
      },
    );
  }

  Widget _hint({
    required IconData icon,
    required String title,
    required String desc,
  }) =>
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: FnosColors.textSub),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: FnosColors.textMain)),
            const SizedBox(height: 8),
            Text(desc,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.7, color: FnosColors.textSub)),
          ],
        ),
      );
}
