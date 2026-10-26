import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/fnos_client.dart';
import '../core/prefs.dart';
import '../core/theme.dart';
import '../widgets/lan_devices_sheet.dart';
import 'about_page.dart';

/// 登录页 —— 登录页。
///
/// 布局自上而下：右上角「关于」齿轮 → Logo 与标题 → 地址 + 端口（同一行）
/// → 账号 → 密码 →「记住密码 · 忘记密码?」→「HTTPS 安全访问」
/// → 连接目标预览 →「登录」→ 底部「发现局域网内设备 / 查看已下载数据」。
///
/// ⚠️ **端口独立成框，且不内置任何默认值**：同一台 NAS 上 HTTP 与 HTTPS
/// 的端口是分别配置的，替用户猜端口必然连不上。
/// 端口只认用户输入；留空则提示补输，不切换、不兜底。
///
/// 访问码不常驻 —— 点登录后若 NAS 开了门禁才弹输入框。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _addr = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _pwd = TextEditingController();

  bool _obscure = true;
  bool _useTls = false;
  bool _remember = false;

  /// 信任自签名证书。
  ///
  /// fnOS 的 HTTPS 用的是**自签证书**，Dart 默认校验证书链会直接抛
  /// `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`
  /// —— 这就是「开了 HTTPS、端口也填对了却进不去」的根因。
  /// 默认打开（局域网 NAS 场景下公网 CA 不可能给它签证书，只能放行）。
  bool _trustCert = true;

  bool _prefilled = false;
  bool _showFnIdHint = false;

  /// 本次提交是否已在飞行中。
  ///
  /// 按钮的禁用条件用 [AppState.connecting]，而它是在 `connect()` 内部才置位的，
  /// 而 `_submit` 前面还要 `await AppPrefs.accessCode()` —— 这个间隙里按钮仍可点，
  /// 会并发触发两遍完整的门禁 + WebSocket 登录。
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _addr.addListener(_onAddrChanged);
    _loadForm();
  }

  @override
  void dispose() {
    _addr.removeListener(_onAddrChanged);
    _addr.dispose();
    _port.dispose();
    _user.dispose();
    _pwd.dispose();
    super.dispose();
  }

  void _onAddrChanged() {
    // 只在「裸 FN ID」出现/消失时重建提示文案
    final v = _isBareFnId;
    // 地址里显式写了 https:// 就联动打开 HTTPS 开关，避免出现
    // "预览按 https 显示、实际按明文去连 TLS 端口"这种自相矛盾的状态。
    final hint = AppState.tlsHintFromAddress(_addr.text);
    final syncTls = hint != null && hint != _useTls;
    if (v != _showFnIdHint || syncTls) {
      setState(() {
        _showFnIdHint = v;
        if (syncTls) _useTls = hint;
      });
    }
  }

  /// 拆 `host:port` 用的正则。
  ///
  /// `[^:]+` 而不是 `.+`：裸 IPv6（fe80::1）会被贪婪匹配拆成 host="fe80:"、
  /// port="1"，等于静默改写用户输入。带方括号的 IPv6（[fe80::1]:8080）
  /// 仍照常拆出端口。与 [AppState.resolveAddress] 保持同一口径。
  static final RegExp _hostPortRe = RegExp(r'^(\[[^\]]+\]|[^:]+):(\d+)$');

  /// 全角冒号会随中文输入法一起进来，统一成半角再解析 / 保存。
  static String _normalizeAddr(String s) => s.replaceAll('：', ':').trim();

  Future<void> _loadForm() async {
    final f = await AppPrefs.loadLoginForm();
    var host = _normalizeAddr(f.host);
    var port = f.port;
    // 老版本可能把端口写在地址里（`host:port` 形式）—— 拆开回填到两个框
    final m = _hostPortRe.firstMatch(host);
    if (m != null) {
      host = m.group(1)!;
      port = m.group(2)!;
    }
    if (!mounted) return;
    setState(() {
      _addr.text = host;
      _port.text = port;
      _user.text = f.user;
      _pwd.text = f.password;
      // 上次存的地址里若带 scheme，以它为准，避免开关与地址不一致
      _useTls = AppState.tlsHintFromAddress(host) ?? f.useTls;
      _remember = f.rememberPassword;
      _trustCert = f.trustCert;
      _prefilled = true;
      _showFnIdHint = _isBareFnId;
    });
  }

  /// 裸 FN ID：不含点、不是 IP、不含端口 —— 这种地址走不了fnOS中继
  bool get _isBareFnId {
    var a = _addr.text.trim();
    a = a.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
    a = a.replaceAll(RegExp(r'/+$'), '');
    if (a.isEmpty) return false;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(a)) return false;
    return !a.contains('.') && !a.contains(':');
  }

  /// 把 `host:port` 拆回两个输入框（最近使用 / 局域网扫描的结果都长这样）
  void _applyAddress(String display) {
    var host = _normalizeAddr(display);
    String? port;
    final m = _hostPortRe.firstMatch(host);
    if (m != null) {
      host = m.group(1)!;
      port = m.group(2)!;
    }
    setState(() {
      _addr.text = host;
      if (port != null) _port.text = port;
      final hint = AppState.tlsHintFromAddress(host);
      if (hint != null) _useTls = hint;
      _showFnIdHint = _isBareFnId;
    });
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s)));
  }

  // ─────────────────────────── 登录 ───────────────────────────

  /// 四个输入框全部必填，且**没有任何默认值/自动推断**（用户明确要求）：
  /// 地址、端口、账号、密码缺一不可，端口绝不由 App 自动补全。
  Future<void> _submit() async {
    if (_submitting) return;
    final st = AppState.I;
    if (_addr.text.trim().isEmpty) {
      _snack('请填写 IP 地址或域名');
      return;
    }
    // 端口范围校验（此前只有「发现局域网内设备」那一处做了校验）
    final portText = _port.text.trim();
    if (portText.isNotEmpty) {
      final p = int.tryParse(portText);
      if (p == null || p < 1 || p > 65535) {
        _snack('端口号必须是 1–65535 之间的数字');
        return;
      }
    }
    // 提交校验与同页的「连接目标预览」共用同一套解析规则。
    // 以前这里自己用正则判断"地址里有没有端口"，粘贴带路径的 URL 时会出现
    // 预览说能连、提交却说「请填写端口号」的自相矛盾。
    if (AppState.resolveAddress(
            address: _addr.text, port: _port.text, tls: _useTls) ==
        null) {
      _snack('请填写端口号（1–65535 的数字）：NAS 上 HTTP 与 HTTPS 的端口是分开配置的');
      return;
    }
    if (_user.text.trim().isEmpty) {
      _snack('请填写账号');
      return;
    }
    if (_pwd.text.isEmpty) {
      _snack('请填写密码');
      return;
    }

    setState(() => _submitting = true);
    try {
      var code = await AppPrefs.accessCode();
      // 最多问三轮：第一轮没带码 → 要码；第二轮带错误码 → 提示重输
      for (var round = 0; round < 3; round++) {
        final ok = await st.connect(
          address: _addr.text,
          port: _port.text,
          user: _user.text.trim(),
          password: _pwd.text,
          accessCode: code,
          useTls: _useTls,
          rememberPassword: _remember,
          trustSelfSigned: _trustCert,
        );
        if (!mounted) return;
        if (ok) {
          final r = AppState.resolveAddress(
              address: _addr.text, port: _port.text, tls: _useTls);
          await AppPrefs.pushAddress(r?.display ?? _addr.text.trim());
          return;
        }

        if (st.errorCode == kErrNeedAccessCode) {
          final input = await _askAccessCode(
            title: code.isEmpty ? '需要访问码' : '访问码不正确',
            initial: code,
          );
          if (input == null) return;
          code = input;
          continue;
        }
        return;
      }
    } finally {
      // 失败信息由 AppState 持有，这里只要把按钮从 loading 态放回来
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<String?> _askAccessCode({
    required String title,
    String initial = '',
  }) async {
    final ctrl = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('该 NAS 开启了访问码门禁，请输入访问码。',
                style: TextStyle(fontSize: 13, color: FnosColors.textSub)),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '访问码',
                prefixIcon:
                    Icon(Icons.key_outlined, color: FnosColors.textSub),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消',
                style: TextStyle(color: FnosColors.textSub)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(72, 40)),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return r;
  }

  void _forgotPassword() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('忘记密码',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: const Text(
          '这里登录的是你自己 NAS 上的账号，密码由你的 NAS 管理，'
          '本应用既不能重置也不会保存到任何服务器。\n\n'
          '请打开 NAS 网页端 →「系统设置 → 用户」重置密码，'
          '然后回到本页重新登录。',
          style: TextStyle(fontSize: 14, height: 1.7),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────── 地址历史 ───────────────────────────

  Future<void> _showHistory() async {
    final list = await AppPrefs.addressHistory();
    if (!mounted) return;
    if (list.isEmpty) {
      _snack('还没有用过其他地址');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text('最近使用',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: FnosColors.textMain)),
            ),
            for (final h in list)
              ListTile(
                leading: const Icon(Icons.history,
                    size: 20, color: FnosColors.textSub),
                title: Text(h, style: const TextStyle(fontSize: 15)),
                trailing: IconButton(
                  tooltip: '删除这条记录',
                  icon: const Icon(Icons.close,
                      size: 18, color: FnosColors.textSub),
                  onPressed: () async {
                    await AppPrefs.removeAddress(h);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) _showHistory();
                  },
                ),
                onTap: () => Navigator.pop(ctx, h),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _applyAddress(picked);
  }

  Future<void> _discover() async {
    // 扫描端口 = 用户已填写的端口。App 不内置任何默认端口：
    // 没填就提示先填，绝不替用户假定一个值去扫。
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _snack('请先填写端口号，再扫描局域网设备（端口以 NAS 上实际配置的为准）');
      return;
    }
    final r = await showLanDevicesSheet(context, port: port, tls: _useTls);
    if (r == null || !mounted) return;
    _applyAddress(r);
    _snack('已填入 $r');
  }

  // ─────────────────────────── 构建 ───────────────────────────

  InputDecoration _deco(String hint, {Widget? suffix, bool compact = false}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            color: FnosColors.textSub, fontSize: compact ? 14 : 15),
        filled: true,
        fillColor: FnosColors.field,
        isDense: compact,
        contentPadding: EdgeInsets.symmetric(
            horizontal: compact ? 14 : 18, vertical: compact ? 16 : 18),
        suffixIcon: suffix,
        suffixIconConstraints:
            const BoxConstraints(minWidth: 36, minHeight: 36),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(FnosRadius.field),
            borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(FnosRadius.field),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(FnosRadius.field),
            borderSide:
                const BorderSide(color: FnosColors.primary, width: 1.4)),
      );

  /// 每个输入框右上角的「叉号」——一键清空当前框内容
  Widget _clearBtn(TextEditingController c) => IconButton(
        tooltip: '清空',
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        icon: const Icon(Icons.cancel, size: 18, color: FnosColors.textSub),
        onPressed: c.clear,
      );

  Widget _field({
    required TextEditingController controller,
    required String hint,
    TextInputType? keyboard,
    TextInputAction? action,
    bool obscure = false,
    bool compact = false,
    List<Widget> extra = const [],
    void Function(String)? onSubmitted,
    List<TextInputFormatter>? formatters,
  }) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, v, _) => TextField(
          controller: controller,
          keyboardType: keyboard,
          textInputAction: action,
          obscureText: obscure,
          onSubmitted: onSubmitted,
          inputFormatters: formatters,
          style: TextStyle(fontSize: compact ? 15 : 16),
          decoration: _deco(
            hint,
            compact: compact,
            // 有内容时才显示叉号，空框不显示
            suffix: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (v.text.isNotEmpty) _clearBtn(controller),
                ...extra,
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final st = AppState.I;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          const _LoginBackdrop(),
          SafeArea(
            child: ListenableBuilder(
              listenable: st,
              builder: (context, _) => Column(
                children: [
                  _topBar(),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: _form(st),
                        ),
                      ),
                    ),
                  ),
                  _bottomLinks(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() => SizedBox(
        height: 44,
        child: Row(
          children: [
            const Spacer(),
            IconButton(
              tooltip: '关于',
              iconSize: 22,
              color: FnosColors.textMain,
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AboutPage())),
              icon: const Icon(Icons.settings_outlined),
            ),
            const SizedBox(width: 6),
          ],
        ),
      );

  Widget _form(AppState st) {
    if (!_prefilled) return const SizedBox(height: 420);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        // ── Logo + 标题 ──
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Image.asset('assets/logo.jpg',
                width: 76, height: 76, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 14),
        const Text('NAS相册',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: FnosColors.textMain)),
        const SizedBox(height: 42),

        // ── 地址 + 端口（端口独立成框，不内置默认值）──
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _field(
                controller: _addr,
                hint: 'IP 地址或域名',
                keyboard: TextInputType.url,
                action: TextInputAction.next,
                extra: [
                  IconButton(
                    tooltip: '最近使用',
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints:
                        const BoxConstraints(minWidth: 34, minHeight: 34),
                    icon: const Icon(Icons.history,
                        size: 20, color: FnosColors.textSub),
                    onPressed: _showHistory,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 116,
              child: _field(
                controller: _port,
                hint: '端口',
                keyboard: TextInputType.number,
                action: TextInputAction.next,
                compact: true,
                formatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // ── 账号 ──
        _field(
          controller: _user,
          hint: '账号',
          action: TextInputAction.next,
        ),
        const SizedBox(height: 14),

        // ── 密码 ──
        _field(
          controller: _pwd,
          hint: '密码',
          obscure: _obscure,
          action: TextInputAction.done,
          onSubmitted: (_) => st.connecting ? null : _submit(),
          extra: [
            IconButton(
              tooltip: _obscure ? '显示密码' : '隐藏密码',
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              icon: Icon(
                  _obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 20,
                  color: FnosColors.textSub),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ── 记住密码 / 忘记密码 ──
        _rememberRow(),
        const SizedBox(height: 6),

        // ── HTTPS ──
        _httpsRow(),

        // ── 实际连接目标预览（端口没填会在这里直接提示）──
        _targetPreview(),
        const SizedBox(height: 22),

        // ── 登录 ──
        SizedBox(
          height: 52,
          child: FilledButton(
            onPressed: (st.connecting || _submitting) ? null : _submit,
            child: (st.connecting || _submitting)
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white))
                : const Text('登录'),
          ),
        ),

        if (st.error != null && st.errorCode != kErrNeedAccessCode) ...[
          const SizedBox(height: 14),
          Text(st.error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: FnosColors.danger)),
        ],

        if (_showFnIdHint) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0x14FA5151),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'FN ID 走的是私有中继通道，本应用暂不支持该方式。\n'
              '请改填局域网 IP（如 192.168.10.2）或你自己的 DDNS 域名。',
              style: TextStyle(
                  fontSize: 12.5, height: 1.7, color: Color(0xFFC0392B)),
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  /// 显示最终会连到哪个地址；端口缺失时给出明确提示，而不是偷偷补一个默认值。
  Widget _targetPreview() => ListenableBuilder(
        listenable: Listenable.merge([_addr, _port]),
        builder: (context, _) {
          if (_addr.text.trim().isEmpty) return const SizedBox.shrink();
          final r = AppState.resolveAddress(
              address: _addr.text, port: _port.text, tls: _useTls);
          final ok = r != null;
          final text = ok
              ? '将连接 ${r.tls ? 'https' : 'http'}://${r.display}'
              : '请填写端口号 —— 端口以 NAS 上实际配置的为准，不填无法连接';
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(ok ? Icons.link : Icons.error_outline,
                      size: 14,
                      color: ok ? FnosColors.textSub : FnosColors.danger),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(text,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color:
                              ok ? FnosColors.textSub : FnosColors.danger)),
                ),
              ],
            ),
          );
        },
      );

  Widget _rememberRow() => Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => setState(() => _remember = !_remember),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: Checkbox(
                      value: _remember,
                      shape: const CircleBorder(),
                      side: const BorderSide(
                          color: Color(0xFFC9CDD4), width: 1.4),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) =>
                          setState(() => _remember = v ?? false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('记住密码',
                      style: TextStyle(
                          fontSize: 14.5, color: FnosColors.textMain)),
                ],
              ),
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: _forgotPassword,
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('忘记密码?',
                style: TextStyle(fontSize: 14.5, color: FnosColors.primary)),
          ),
        ],
      );

  Widget _httpsRow() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('HTTPS 安全访问',
                  style: TextStyle(fontSize: 15, color: FnosColors.textMain)),
              const Spacer(),
              Transform.scale(
                scale: 0.9,
                child: Switch(
                  value: _useTls,
                  // 开关 HTTPS 不会去改端口 —— 端口由用户在 NAS 上怎么配就怎么填
                  onChanged: (v) => setState(() => _useTls = v),
                ),
              ),
            ],
          ),
          // 自签证书开关：只在 HTTPS 打开时有意义
          if (_useTls) ...[
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _trustCert = !_trustCert),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: Checkbox(
                        value: _trustCert,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (v) =>
                            setState(() => _trustCert = v ?? false),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('信任自签名证书',
                        style: TextStyle(
                            fontSize: 14.5, color: FnosColors.textMain)),
                  ],
                ),
              ),
            ),
          ],
        ],
      );

  Widget _bottomLinks() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        // 用 Wrap 而不是 Row + Spacer：两段文案在系统字体放大到约 1.5 倍时
        // 会超过屏幕宽度 —— Row 只会横向溢出（release 下右侧按钮被裁到屏外，
        // 而这一行在滚动视图之外救不回来），Wrap 则会自然换到第二行。
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: _discover,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('发现局域网内设备',
                  style: TextStyle(fontSize: 13.5, color: FnosColors.textSub)),
            ),
          ],
        ),
      );
}

/// 顶部极淡的蓝色光晕，往下过渡到纯白 —— 对应fnOS登录页的浅色背景
class _LoginBackdrop extends StatelessWidget {
  const _LoginBackdrop();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0, 0.32, 0.62, 1],
            colors: [
              Color(0xFFE9F1FF),
              Color(0xFFF6FAFF),
              Color(0xFFFFFFFF),
              Color(0xFFFFFFFF),
            ],
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}
