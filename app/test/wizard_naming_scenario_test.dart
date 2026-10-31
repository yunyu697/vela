/// 向导命名与常用场景的功能验证。
///
/// 覆盖：
///  1. 默认配置名不重复（含时间戳）且可中途改名，build() 采用最终名称
///  2. 场景应用后勾选集合整体替换、仍可自由增删
///  3. RuleScenarios.matching 的选中态判定
///  4. 规则集注册表：场景引用的 id 都真实存在
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/ir/profile.dart';
import 'package:vela/core/ir/rule_set_registry.dart';
import 'package:vela/features/wizard/wizard_controller.dart';

void main() {
  group('配置命名', () {
    test('suggestName 包含时间戳，两次实例不同名（跨秒）', () async {
      final a = WizardController.suggestName();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final b = WizardController.suggestName();
      expect(a, startsWith('我的配置 '));
      expect(b, isNot(a));
    });

    test('中途改名后 build() 使用最终名称', () {
      final c = WizardController();
      c.setProfileName('工作配置');
      final result = c.build();
      expect(result.profile.name, '工作配置');
    });

    test('空名称回落到自动建议名', () {
      final c = WizardController();
      c.setProfileName('   ');
      final result = c.build();
      expect(result.profile.name, startsWith('我的配置 '));
    });

    test('保存重名兜底：同名追加序号', () {
      // 直接测 _dedupeName 逻辑等价实现（在 wizard_page 内为私有，
      // 这里验证语义：existing 集合命中时依次尝试 2、3…）
      final existing = {'A', 'A 2'};
      String dedupe(String name) {
        if (!existing.contains(name)) return name;
        for (var i = 2;; i++) {
          final candidate = '$name $i';
          if (!existing.contains(candidate)) return candidate;
        }
      }

      expect(dedupe('B'), 'B');
      expect(dedupe('A'), 'A 3');
    });
  });

  group('常用场景', () {
    test('场景引用的规则集 id 全部存在', () {
      for (final s in RuleScenarios.builtin) {
        for (final id in s.ruleSetIds) {
          expect(RuleSetRegistry.byId(id), isNotNull,
              reason: '场景「${s.name}」引用了不存在的规则集 $id');
        }
      }
    });

    test('applyScenario 整体替换勾选集合', () {
      final c = WizardController();
      c.applyScenario('gaming');
      expect(
        c.selectedRuleSetIds,
        unorderedEquals(RuleScenarios.byId('gaming')!.ruleSetIds),
      );
      // 换场景
      c.applyScenario('streaming');
      expect(
        c.selectedRuleSetIds,
        unorderedEquals(RuleScenarios.byId('streaming')!.ruleSetIds),
      );
    });

    test('应用场景后仍可自由增删', () {
      final c = WizardController();
      c.applyScenario('global');
      c.toggleRuleSet('youtube');
      expect(c.selectedRuleSetIds.contains('youtube'), isTrue);
      // 增删后偏离场景集合 → 不再匹配任何场景
      expect(RuleScenarios.matching(c.selectedRuleSetIds), isNull);
      c.toggleRuleSet('youtube');
      expect(c.selectedRuleSetIds.contains('youtube'), isFalse);
      // 恢复后重新匹配回 global 场景
      expect(RuleScenarios.matching(c.selectedRuleSetIds)?.id, 'global');
    });

    test('matching 识别选中态（数量相同且包含全部）', () {
      final gaming = RuleScenarios.byId('gaming')!;
      expect(
        RuleScenarios.matching(gaming.ruleSetIds.toSet())?.id,
        'gaming',
      );
      // 子集不匹配
      expect(RuleScenarios.matching({'geosite-cn'}), isNull);
      // 空集合不匹配
      expect(RuleScenarios.matching(<String>{}), isNull);
    });

    test('默认勾选 = 第一个场景（日常均衡）', () {
      final c = WizardController();
      expect(
        RuleScenarios.matching(c.selectedRuleSetIds)?.id,
        RuleScenarios.builtin.first.id,
      );
    });
  });

  group('规则集注册表', () {
    test('规模：至少 20 个内置规则集', () {
      expect(RuleSetRegistry.builtin.length, greaterThanOrEqualTo(20));
    });

    test('id 唯一', () {
      final ids = RuleSetRegistry.builtin.map((r) => r.id).toSet();
      expect(ids.length, RuleSetRegistry.builtin.length);
    });

    test('新增规则集的 URL 指向 meta-rules-dat', () {
      for (final rs in RuleSetRegistry.builtin) {
        expect(rs.singboxUrl, startsWith('https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/'));
        expect(rs.mihomoUrl, startsWith('https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/'));
        expect(rs.singboxUrl, endsWith('.srs'));
        expect(rs.mihomoUrl, endsWith('.mrs'));
      }
    });

    test('场景应用到草稿：build() 的规则条目覆盖场景规则集', () {
      final c = WizardController();
      c.applyScenario('gaming');
      final result = c.build();
      final usedIds = <String>{};
      for (final rule in result.profile.rules) {
        usedIds.addAll(rule.ruleSetIds);
      }
      for (final id in RuleScenarios.byId('gaming')!.ruleSetIds) {
        expect(usedIds.contains(id), isTrue, reason: '规则集 $id 未进入生成结果');
      }
    });
  });

  test('RuleAction 枚举完整性（直接被场景测试依赖）', () {
    expect(RuleAction.values.length, 3);
  });
}
