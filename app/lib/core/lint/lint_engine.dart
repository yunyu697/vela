/// Lint 检查引擎。
///
/// 三级告警：
/// - error   阻断配置生成
/// - warning 红色提示 + 一键修复
/// - info    灰字建议
///
/// 在向导最后一步、以及任何"保存/应用"入口调用 [LintEngine.run]。
library;

import '../ir/profile.dart';
import '../ir/rule_set_registry.dart';

enum LintSeverity { error, warning, info }

class LintIssue {
  const LintIssue({
    required this.code,
    required this.severity,
    required this.message,
    this.fixHint,
    this.autoFixable = false,
  });

  final String code;
  final LintSeverity severity;
  final String message;

  /// 一键修复建议的说明（UI 据此展示"修复"按钮）。
  final String? fixHint;
  final bool autoFixable;

  @override
  String toString() => '[$code][${severity.name}] $message';
}

class LintEngine {
  const LintEngine();

  List<LintIssue> run(Profile p) {
    return [
      ..._compatibility(p),
      ..._dns(p),
      ..._rules(p),
    ];
  }

  bool hasBlockingErrors(List<LintIssue> issues) =>
      issues.any((i) => i.severity == LintSeverity.error);

  // -------------------------------------------------------------------
  // 内核兼容性矩阵
  // -------------------------------------------------------------------

  Iterable<LintIssue> _compatibility(Profile p) sync* {
    final unsupported =
        p.nodes.where((n) => !n.protocol.supportedOn(p.coreKind)).toList();
    if (unsupported.isNotEmpty) {
      yield LintIssue(
        code: 'E001',
        severity: LintSeverity.error,
        message: '所选内核 ${p.coreKind.name} 不支持以下节点的协议：\n'
            '${unsupported.map((n) => '${n.name} (${n.protocol.name})').join('、')}',
        fixHint: '剔除这些节点，或切换到支持的内核',
        autoFixable: true,
      );
    }
    if (p.nodes.isEmpty) {
      yield const LintIssue(
        code: 'E003',
        severity: LintSeverity.error,
        message: '配置中没有任何可用节点',
      );
    }
  }

  // -------------------------------------------------------------------
  // DNS 风险检查
  // -------------------------------------------------------------------

  Iterable<LintIssue> _dns(Profile p) sync* {
    final dns = p.dns;
    final tunEnabled = p.inbound.mode == AccessMode.tun ||
        p.inbound.mode == AccessMode.mixed;

    // W101: fake-ip 未配置过滤器 → 本地服务/NAS/路由器管理页异常
    if (dns.mode == DnsMode.fakeIp && dns.fakeIpFilter.isEmpty) {
      yield const LintIssue(
        code: 'W101',
        severity: LintSeverity.warning,
        message: 'fake-ip 模式未配置白名单过滤器，可能导致路由器管理页、'
            'NAS、本地服务等无法访问或解析异常。',
        fixHint: '加入常用白名单（*.lan、*.local、NTP、时间服务等）',
        autoFixable: true,
      );
    }

    // W102: TUN 未配置 DNS 劫持 → DNS 泄露
    if (tunEnabled && dns.mode == DnsMode.plain) {
      yield const LintIssue(
        code: 'W102',
        severity: LintSeverity.warning,
        message: 'TUN 模式 + 普通 DNS：系统 DNS 请求可能绕过代理直接发出，'
            '存在 DNS 泄露风险。',
        fixHint: '切换到 fake-ip 或 redir-host 模式（两者都会启用 DNS 劫持）',
        autoFixable: true,
      );
    }

    // W103: 不按规则分流 → 全部走外国 DNS，国内解析变慢
    if (!dns.followRules) {
      yield const LintIssue(
        code: 'W103',
        severity: LintSeverity.warning,
        message: 'DNS 未按分流规则选择服务器，所有解析都走外国 DNS，'
            '国内域名解析会明显变慢。',
        fixHint: '开启「DNS 按规则分流」',
        autoFixable: true,
      );
    }

    // W104: 主 DNS 为明文 53 端口 → 易被劫持
    final plainFirst = dns.domesticServers.isNotEmpty &&
        !dns.domesticServers.first.startsWith('https://') &&
        !dns.domesticServers.first.startsWith('quic://') &&
        !dns.domesticServers.first.startsWith('tls://');
    if (plainFirst) {
      yield const LintIssue(
        code: 'W104',
        severity: LintSeverity.info,
        message: '首选 DNS 为明文 53 端口，存在被运营商劫持的可能。'
            '建议使用 DoH（https://）或 DoT/DoQ。',
      );
    }
  }

  // -------------------------------------------------------------------
  // 规则完整性
  // -------------------------------------------------------------------

  Iterable<LintIssue> _rules(Profile p) sync* {
    // E002: 引用了未知规则集（custom: 前缀的自定义规则集在 M3 接入后校验）
    final unknownIds = p.rules.expand((r) => r.ruleSetIds).toSet();
    if (unknownIds.isEmpty) return;

    final bad = unknownIds
        .where((id) => !id.startsWith('custom:') && RuleSetRegistry.byId(id) == null)
        .toSet();
    if (bad.isNotEmpty) {
      yield LintIssue(
        code: 'E002',
        severity: LintSeverity.error,
        message: '规则引用了不存在的规则集：${bad.join('、')}',
      );
    }

    // E004: 没有任何启用的规则
    if (!p.rules.any((r) => r.enabled)) {
      yield const LintIssue(
        code: 'E004',
        severity: LintSeverity.error,
        message: '没有启用的分流规则，所有流量将走默认分组。',
        fixHint: '至少启用「国内域名直连」规则集',
        autoFixable: true,
      );
    }
  }

}
