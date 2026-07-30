# CocoaPods integration for MobileVLCKit.
#
# Why CocoaPods (not SwiftPM) for VLC: there is NO reliable official SwiftPM
# artifact for the MobileVLCKit 3.x stable line. SwiftPM support only exists in
# the VLCKit 4.0 beta, which is not stable enough to depend on. Everything else
# in this project (the app target, the local HelmProtocol package) is wired via
# XcodeGen; CocoaPods is used ONLY for MobileVLCKit.
#
# Bootstrap order (re-run whenever project.yml or this Podfile changes):
#   xcodegen generate && pod install && open HelmMirror.xcworkspace
# After the first `pod install`, ALWAYS open the .xcworkspace, never the bare
# .xcodeproj (or Pods won't be linked).

platform :ios, '16.0'
install! 'cocoapods', :integrate_targets => true

target 'HelmMirror' do
  use_frameworks!
  # 3.7.x is the current stable line (3.7.3 latest, verified against the CocoaPods
  # trunk API). Prefer it over 3.6.0 for compatibility with recent Xcode releases.
  # CocoaPods ignores pre-release versions (3.7.0b1 etc.) unless asked explicitly.
  pod 'MobileVLCKit', '~> 3.7.0'
end
