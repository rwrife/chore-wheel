#!/usr/bin/env ruby
# Generates ChoreWheel.xcodeproj for the Chore Wheel iOS app.
# Run from any checkout location: ruby Tools/gen_project.rb
# Requires the `xcodeproj` gem (Docker: see docs/skeleton-verification.md).
require 'xcodeproj'
require 'fileutils'

repo_root = File.expand_path('..', __dir__)
Dir.chdir(repo_root)

proj_path = 'ChoreWheel.xcodeproj'
FileUtils.rm_rf(proj_path)

project = Xcodeproj::Project.new(proj_path)

# --- App target ------------------------------------------------------------
app = project.new_target(:application, 'ChoreWheel', :ios, '26.0')
app.add_file_references(
  Dir['Sources/ChoreWheel/App/**/*.swift'].sort.map { |f| project.main_group.new_file(f) }
)
app.add_file_references(
  Dir['Sources/ChoreWheel/Domain/**/*.swift'].sort.map { |f| project.main_group.new_file(f) }
)
app.resources_build_phase.add_file_reference(project.main_group.new_file('Resources/Assets.xcassets'))

# --- Unit test target ------------------------------------------------------
tests = project.new_target(:unit_test_bundle, 'ChoreWheelTests', :ios, '26.0')
tests.add_file_references(
  Dir['Tests/ChoreWheelTests/**/*.swift'].sort.map { |f| project.main_group.new_file(f) }
)
tests.add_dependency(app)

# No package dependencies yet. Persistence enters in issue #3; when it does,
# pin Xcode's package graph to the SwiftPM Package.resolved revision.

marketing_version = File.read('VERSION').strip
raise 'VERSION file is empty' if marketing_version.empty?

# --- Build settings --------------------------------------------------------
common = {
  'IPHONEOS_DEPLOYMENT_TARGET' => '26.0',
  'SWIFT_VERSION' => '6.0',
  'SWIFT_STRICT_CONCURRENCY' => 'complete',
  'CODE_SIGN_STYLE' => 'Automatic',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
  # iPhone only. iPad support requires explicit product opt-in (PLAN.md).
  'TARGETED_DEVICE_FAMILY' => '1',
}
project.build_configurations.each do |c|
  common.each { |k, v| c.build_settings[k] = v }
end

app.build_configurations.each do |c|
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.infinityball.chorewheel'
  c.build_settings['PRODUCT_NAME'] = 'ChoreWheel'
  c.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  c.build_settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
  # Release versioning: MARKETING_VERSION seeds from repo-root VERSION;
  # the future release workflow overrides CURRENT_PROJECT_VERSION with the
  # Actions run number for monotonic TestFlight build numbers.
  c.build_settings['MARKETING_VERSION'] = marketing_version
  c.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  c.build_settings['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
  c.build_settings['INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents'] = 'YES'
  c.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  c.build_settings['INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone'] = 'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
  c.build_settings['ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_EXTENSIONS'] = 'YES'
  c.build_settings['ENABLE_PREVIEWS'] = 'YES'
end

tests.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.infinityball.chorewheel.tests'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  # The xcodeproj gem defaults new targets to TARGETED_DEVICE_FAMILY = "1,2";
  # override at target level or it shadows the project-level '1'.
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
  c.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/ChoreWheel.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/ChoreWheel'
  c.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

project.save

# --- Shared scheme ----------------------------------------------------------
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(proj_path, 'ChoreWheel', true)

puts 'OK: generated ' + proj_path
