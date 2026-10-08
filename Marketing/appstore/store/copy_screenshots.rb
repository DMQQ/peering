#!/usr/bin/env ruby
# Copies one screenshot set from one version of the app to another, same locale, same display type.
#
# A new version starts with no media, and only the iPhone set is regenerated for it: the capture
# pipeline draws iPhone frames, and doing the same for iPad would mean capturing and framing a
# second device in ten languages. The iPad shots are not per-language anyway, so the honest thing is
# to lift the set the live version already has and put it on the version being submitted.
#
#   ASC_KEY_PATH=... ASC_KEY_ID=... ASC_ISSUER_ID=... \
#     ruby store/copy_screenshots.rb --from 1.0.0 --to 202610051 --locale en-US \
#       --display APP_IPAD_PRO_3GEN_129 [--folder upload/screenshots/ipad-en-US] [--dry-run]
#
# The images are kept in the folder as well as uploaded, under the names the live set had, so the
# next version does not have to ask the App Store for them again.
require "spaceship"
require "net/http"
require "fileutils"

def option(name, default = nil)
  ARGV.include?("--#{name}") ? ARGV[ARGV.index("--#{name}") + 1] : default
end

FROM = option("from") or abort "Pass --from <version> (e.g. 1.0.0)."
TO = option("to") or abort "Pass --to <version> (e.g. 202610051)."
LOCALE = option("locale", "en-US")
DISPLAY = option("display", "APP_IPAD_PRO_3GEN_129")
APPSTORE = File.expand_path("..", __dir__)
# Relative to the appstore folder, not to this script: `--folder upload/screenshots/ipad` is how
# anybody would write it, and resolving that against `store/` put the images somewhere nobody looks.
FOLDER = File.expand_path(option("folder", "upload/screenshots/ipad-#{LOCALE}"), APPSTORE)
DRY_RUN = ARGV.include?("--dry-run")
BUNDLE_ID = "pl.dmq.peering"

key_path, key_id, issuer_id = ENV.values_at("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")
if [key_path, key_id, issuer_id].any? { |value| value.nil? || value.empty? }
  abort "Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID."
end

Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id: key_id, issuer_id: issuer_id, filepath: File.expand_path(key_path)
)
app = Spaceship::ConnectAPI::App.find(BUNDLE_ID) or abort "No app #{BUNDLE_ID}."

def localization(app, version_string, locale)
  version = app.get_app_store_versions.find { |v| v.version_string == version_string }
  abort "No version #{version_string}." unless version
  version.get_app_store_version_localizations.find { |l| l.locale == locale } or
    abort "No #{locale} localization on #{version_string}."
end

source = localization(app, FROM, LOCALE)
source_set = source.get_app_screenshot_sets.find { |s| s.screenshot_display_type == DISPLAY }
abort "#{FROM} has no #{DISPLAY} set for #{LOCALE}." unless source_set

shots = source_set.app_screenshots.sort_by(&:file_name)
puts "source: #{FROM} #{LOCALE} #{DISPLAY} -> #{shots.count} screenshots"

FileUtils.mkdir_p(FOLDER)
files = shots.map do |shot|
  path = File.join(FOLDER, shot.file_name)
  unless File.exist?(path)
    asset = shot.image_asset
    # The App Store serves the original size from the same template URL it uses for thumbnails:
    # the placeholders are the only thing standing between the two.
    url = asset["templateUrl"].gsub("{w}", asset["width"].to_s)
                                .gsub("{h}", asset["height"].to_s)
                                .gsub("{f}", File.extname(shot.file_name).delete("."))
    puts "  downloading #{shot.file_name} (#{asset["width"]}x#{asset["height"]})"
    body = Net::HTTP.get(URI(url))
    abort "  failed: #{url}" if body.nil? || body.empty?
    File.binwrite(path, body)
  end
  path
end
puts "kept in #{FOLDER}"

target = localization(app, TO, LOCALE)
set = target.get_app_screenshot_sets.find { |s| s.screenshot_display_type == DISPLAY }
if DRY_RUN
  puts "would upload #{files.count} to #{TO} #{LOCALE} #{DISPLAY} (set #{set ? "exists, #{set.app_screenshots.count} there" : "created"})"
  exit 0
end

set ||= target.create_app_screenshot_set(attributes: { screenshotDisplayType: DISPLAY })
set.app_screenshots.each(&:delete!)
files.each { |path| set.upload_screenshot(path: path, wait_for_processing: false) }

after = localization(app, TO, LOCALE).get_app_screenshot_sets.find { |s| s.screenshot_display_type == DISPLAY }
states = after.app_screenshots.map { |shot| shot.asset_delivery_state && shot.asset_delivery_state["state"] }.tally
puts "#{TO} #{LOCALE} #{DISPLAY}: #{after.app_screenshots.count} screenshots #{states.inspect}"
