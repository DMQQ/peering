#!/usr/bin/env ruby
# Puts the Apple Watch screenshots on the app's editable App Store version, in its primary language.
#
# upload/screenshots/watch/ultra holds 422x514 pictures (Apple Watch Ultra 3) and
# upload/screenshots/watch/series10 holds 416x496 ones (Series 11, 46 mm). Each folder is one
# screenshot set, in file-name order, and the set is replaced rather than appended to.
#
# Needs the fastlane gems (spaceship) and an App Store Connect API key in the environment:
#
#   ASC_KEY_PATH=.private/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX \
#   ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
#     ruby store/upload_watch_screenshots.rb [--dry-run]
require "spaceship"

ROOT = File.expand_path("../upload/screenshots/watch", __dir__)
BUNDLE_ID = "pl.dmq.peering"
LOCALE = "en-US"
DRY_RUN = ARGV.include?("--dry-run")
SETS = {
  "ultra" => Spaceship::ConnectAPI::AppScreenshotSet::DisplayType::APP_WATCH_ULTRA,
  "series10" => Spaceship::ConnectAPI::AppScreenshotSet::DisplayType::APP_WATCH_SERIES_10
}.freeze

key_path, key_id, issuer_id = ENV.values_at("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")
if [key_path, key_id, issuer_id].any? { |value| value.nil? || value.empty? }
  abort "Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID (see the comment at the top)."
end

Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id: key_id, issuer_id: issuer_id, filepath: File.expand_path(key_path)
)

app = Spaceship::ConnectAPI::App.find(BUNDLE_ID) or abort "No app #{BUNDLE_ID}."
version = app.get_edit_app_store_version or abort "No editable version: create one in App Store Connect first."
puts "App Store Connect: #{app.name} #{version.version_string} (#{version.app_store_state})"

localization = version.get_app_store_version_localizations.find { |candidate| candidate.locale == LOCALE }
abort "The version has no #{LOCALE} localization." unless localization

SETS.each do |folder, display_type|
  files = Dir.children(File.join(ROOT, folder)).select { |name| name.end_with?(".png") }.sort
  set = localization.get_app_screenshot_sets.find { |candidate| candidate.screenshot_display_type == display_type }
  existing = set ? set.app_screenshots.to_a : []
  puts "  #{display_type}: #{existing.count} there, #{files.count} to upload"
  next if DRY_RUN

  set ||= localization.create_app_screenshot_set(attributes: { screenshotDisplayType: display_type })
  existing.each(&:delete!)
  files.each { |name| set.upload_screenshot(path: File.join(ROOT, folder, name), wait_for_processing: false) }
end
puts DRY_RUN ? "\nDry run: nothing changed." : "\nUploaded."
