#!/usr/bin/env ruby
# Replaces the App Store screenshots of the version with the framed set in upload/screenshots.
#
# The folder is the source of truth: `04-shortcuts` means upload/screenshots/<locale>/04_<lang>.png,
# in file-name order, which is the order the App Store shows them in. The existing set is deleted
# first because a set holds at most ten and this one is seven: appending to it would be refused
# rather than replace anything.
#
# Credentials are not in here. Pass the App Store Connect key in the environment:
#
#   ASC_KEY_PATH=~/Downloads/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX \
#   ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
#     ruby store/upload_screenshots.rb [--dry-run] [--version 1.0.1]
require "spaceship"

ROOT = File.expand_path("../upload/screenshots", __dir__)
BUNDLE_ID = "pl.dmq.peering"
VERSION = ARGV.include?("--version") ? ARGV[ARGV.index("--version") + 1] : "1.0.1"
DRY_RUN = ARGV.include?("--dry-run")
DISPLAY_TYPE = Spaceship::ConnectAPI::AppScreenshotSet::DisplayType::APP_IPHONE_67

key_path, key_id, issuer_id = ENV.values_at("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")
if [key_path, key_id, issuer_id].any? { |value| value.nil? || value.empty? }
  abort "Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID (see the comment at the top)."
end

Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id: key_id,
  issuer_id: issuer_id,
  filepath: File.expand_path(key_path)
)

app = Spaceship::ConnectAPI::App.find(BUNDLE_ID) or abort "No app #{BUNDLE_ID}."
version = app.get_app_store_versions.find { |candidate| candidate.version_string == VERSION }
abort "No version #{VERSION} on App Store Connect." unless version
puts "App Store Connect: #{app.name} #{version.version_string} (#{version.app_store_state})"

version.get_app_store_version_localizations.sort_by(&:locale).each do |locale|
  folder = File.join(ROOT, locale.locale)
  unless Dir.exist?(folder)
    puts "  #{locale.locale}: no folder, left alone"
    next
  end

  files = Dir.children(folder).select { |name| name.end_with?(".png") }.sort
  set = locale.get_app_screenshot_sets.find { |candidate| candidate.screenshot_display_type == DISPLAY_TYPE }
  existing = set ? set.app_screenshots.to_a : []
  puts "  #{locale.locale}: #{existing.count} there, #{files.count} to upload"
  next if DRY_RUN

  set ||= locale.create_app_screenshot_set(attributes: {
    screenshotDisplayType: DISPLAY_TYPE
  })
  existing.each(&:delete!)
  files.each do |name|
    set.upload_screenshot(path: File.join(folder, name), wait_for_processing: false)
  end
end

puts "\nApp Store Connect now holds:"
version.get_app_store_version_localizations.sort_by(&:locale).each do |locale|
  set = locale.get_app_screenshot_sets.find { |candidate| candidate.screenshot_display_type == DISPLAY_TYPE }
  shots = set ? set.app_screenshots.to_a : []
  # The delivery state is the App Store's own answer on the images, and it is not instant: a set
  # that says AWAITING_UPLOAD or PROCESSING is one that will be there in a minute, not one that
  # failed. Anything else (FAILED) is the case worth seeing.
  states = shots.map { |shot| shot.asset_delivery_state && shot.asset_delivery_state["state"] }.tally
  puts "  #{locale.locale}: #{shots.count} screenshots #{states.empty? ? "" : states.inspect}"
end
