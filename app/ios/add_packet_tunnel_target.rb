#!/usr/bin/env ruby
# 把 PacketTunnel（Network Extension）接入 Flutter 生成的 Runner 工程。
#
# 为什么不手改 project.pbxproj：新增 target 要同步 PBXNativeTarget /
# 两个 BuildConfigurationList / PBXTargetDependency / PBXContainerItemProxy /
# 嵌入阶段 / 产品引用，手写极易漏项且难以 review。这里用 xcodeproj gem 做
# 结构化修改，脚本入库，工程可随时重建（幂等，可重复执行）。
#
# 用法： cd app && ruby ios/add_packet_tunnel_target.rb
require 'xcodeproj'

PROJECT_PATH = 'ios/Runner.xcodeproj'
EXT_NAME = 'PacketTunnel'
EXT_BUNDLE_ID = 'dev.boxhub.boxhub.PacketTunnel'
APP_GROUP = 'group.dev.boxhub.boxhub'
DEPLOYMENT_TARGET = '15.0'
# 相对 app/ios/（工程文件所在目录）：内核产物在 boxhub/mobile-libs/ios
XCFRAMEWORK = '../../mobile-libs/ios/Boxhubmobile.xcframework'

project = Xcodeproj::Project.open(PROJECT_PATH)
runner = project.targets.find { |t| t.name == 'Runner' }
raise 'Runner target 不存在' unless runner

# ---- 1. Runner：把 CoreBridgePlugin.swift 加进编译 ----
# （本工程内的 Swift 文件不会被 GeneratedPluginRegistrant 自动收进来）
runner_group = project.main_group.find_subpath('Runner', true)
runner_group.set_source_tree('SOURCE_ROOT')
# Runner 组的路径本身就是 ios/Runner，引用要相对该组，不能重复写 Runner/
plugin_ref = runner_group.files.find { |f| f.path == 'CoreBridgePlugin.swift' } ||
             runner_group.new_reference('CoreBridgePlugin.swift')
unless runner.source_build_phase.files.any? { |f| f.file_ref == plugin_ref }
  runner.source_build_phase.add_file_reference(plugin_ref, true)
end
unless runner_group.files.any? { |f| f.path == 'Runner.entitlements' }
  runner_group.new_reference('Runner.entitlements')
end

runner.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

# ---- 2. 扩展 target（已存在则跳过，避免重复 target / 悬挂依赖） ----
ext = project.targets.find { |t| t.name == EXT_NAME }
if ext
  puts "#{EXT_NAME} 已存在，跳过创建"
else
  ext = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOYMENT_TARGET)

  group = project.main_group.find_subpath(EXT_NAME, true)
  group.set_source_tree('SOURCE_ROOT')
  # 参与编译的源文件（utun fd 走 packetFlow 私有接口，不需要 C 桥）
  sources = [group.new_reference("#{EXT_NAME}/PacketTunnelProvider.swift")]
  ext.add_file_references(sources)
  # plist / entitlements 只作工程内可见引用，不进编译阶段
  group.new_reference("#{EXT_NAME}/Info.plist")
  group.new_reference("#{EXT_NAME}/PacketTunnel.entitlements")

  # ---- 3. 链接 Go 内核（gomobile 产出静态 framework，无需嵌入） ----
  framework_group = project.main_group.find_subpath('Frameworks', true)
  framework_group.set_source_tree('<group>')
  xcframework = framework_group.new_reference(XCFRAMEWORK)
  ext.frameworks_build_phase.add_file_reference(xcframework, true)

  # ---- 4. 扩展编译设置 ----
  ext.build_configurations.each do |config|
    # 复用 Flutter 的 xcconfig：扩展的 CFBundleShortVersionString /
    # CFBundleVersion 取自 FLUTTER_BUILD_NAME / FLUTTER_BUILD_NUMBER，
    # 与主 App 自动同步（版本号不一致会被安装器拒绝：Invalid
    # placeholder attributes）。
    xcconfig_path = config.name == 'Debug' ? 'Flutter/Debug.xcconfig' : 'Flutter/Release.xcconfig'
    config.base_configuration_reference = project.files.find { |f| f.path == xcconfig_path }

    settings = config.build_settings
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_BUNDLE_ID
    settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    settings['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
    settings['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/PacketTunnel.entitlements"
    settings['GENERATE_INFOPLIST_FILE'] = 'NO'
    settings['SWIFT_VERSION'] = '5.0'
    settings['SKIP_INSTALL'] = 'YES'
    settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
    # 内核 XCFramework 只含 arm64 切片（Apple Silicon 模拟器 + 真机）。
    # Debug 只编当前架构，避免 x86_64 模拟器找不到切片；Intel Mac 上
    # 需要用 build_mobile.sh 额外产出 iossimulator/amd64。
    settings['ONLY_ACTIVE_ARCH'] = config.name == 'Debug' ? 'YES' : 'NO'
    settings['CLANG_ENABLE_MODULES'] = 'YES'
    settings['LD_RUNPATH_SEARCH_PATHS'] = [
      '$(inherited)',
      '@executable_path/Frameworks',
      '@executable_path/../../Frameworks'
    ]
    # 路径相对 app/ios/：内核产物在 boxhub/mobile-libs/ios
    settings['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', '$(SRCROOT)/../../mobile-libs/ios']
    # gomobile 生成的胶水代码引用了 UIDevice；Go 运行时需要系统 resolver
    settings['OTHER_LDFLAGS'] = ['$(inherited)', '-lresolv', '-framework', 'UIKit']
  end

  # ---- 5. Runner 依赖并嵌入扩展 ----
  runner.add_dependency(ext)
  embed = runner.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' }
  if embed.nil?
    embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
    embed.dst_subfolder_spec = '13' # 13 = PlugIns，扩展必须落在 App.app/PlugIns
  end
  build_file = embed.add_file_reference(ext.product_reference, true)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

  # 嵌入阶段必须排在 "Thin Binary" 之前：Flutter 的 Thin Binary 会重写
  # App 里的可执行文件，若嵌扩展排在它后面，Xcode 会报
  # 「Cycle inside Runner」（Info.plist 处理 ← 嵌入 ← Thin Binary ← ...）。
  thin = runner.build_phases.index { |ph| ph.display_name == 'Thin Binary' }
  if thin
    runner.build_phases.move_from(runner.build_phases.index(embed), thin)
  end
end

project.save
puts "已写入 #{PROJECT_PATH}：#{EXT_NAME} → #{EXT_BUNDLE_ID}（App Group #{APP_GROUP}）"
