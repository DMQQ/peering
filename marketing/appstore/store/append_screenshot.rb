#!/usr/bin/env ruby
# Adds one more screenshot to the iPhone set of each locale, leaving the ones already there.
#
#   ASC_KEY_PATH=... ASC_KEY_ID=... ASC_ISSUER_ID=... \
#     ruby store/append_screenshot.rb --version 202610061 --prefix 08 [--dry-run]
#
# upload_screenshots.rb replaces the whole set; this one only appends, and skips a locale that
# already holds as many screenshots as the folder has, so a second run adds nothing twice.
require "spaceship"

def option(name, default = nil)
  ARGV.include?("--#{name}") ? ARGV[ARGV.index("--#{name}") + 1] : default
end

ROOT = File.expand_path("../upload/screenshots", __dir__)
VERSION = option("version") or abort "Pass --version."
PREFIX = option("prefix") or abort "Pass --prefix (08 for 08_<lang>.png)."
DRY_RUN = ARGV.include?("--dry-run")
DISPLAY_TYPE = Spaceship::ConnectAPI::AppScreenshotSet::DisplayType::APP_IPHONE_67

key_path, key_id, issuer_id = ENV.values_at("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")
abort "Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID." if [key_path, key_id, issuer_id].any? { |v| v.nil? || v.empty? }
Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(key_id: key_id, issuer_id: issuer_id, filepath: File.expand_path(key_path))

app = Spaceship::ConnectAPI::App.find("pl.dmq.peering") or abort "No app."
version = app.get_app_store_versions.find { |v| v.version_string == VERSION } or abort "No version #{VERSION}."

version.get_app_store_version_localizations.sort_by(&:locale).each do |localization|
  folder = File.join(ROOT, localization.locale)
  file = Dir.exist?(folder) && Dir.children(folder).find { |n| n.start_with?("#{PREFIX}_") && n.end_with?(".png") }
  unless file
    puts "  #{localization.locale}: no #{PREFIX} file, left alone"
    next
  end
  wanted = Dir.children(folder).count { |n| n.end_with?(".png") }
  set = localization.get_app_screenshot_sets.find { |s| s.screenshot_display_type == DISPLAY_TYPE }
  have = set ? set.app_screenshots.to_a.count : 0
  if have >= wanted
    puts "  #{localization.locale}: already #{have}, skipped"
    next
  end
  puts "  #{localization.locale}: #{have} there, adding #{file}"
  next if DRY_RUN
  set ||= localization.create_app_screenshot_set(attributes: { screenshotDisplayType: DISPLAY_TYPE })
  set.upload_screenshot(path: File.join(folder, file), wait_for_processing: false)
end
