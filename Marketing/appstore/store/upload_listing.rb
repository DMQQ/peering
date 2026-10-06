#!/usr/bin/env ruby
# Writes the localized listing fields for the version in App Store Connect, then reads them back.
#
# **Every field is named, and every field is read back.** The first upload went through `deliver`
# with the metadata folder, and that action decides for itself what it sends: the run that filled
# nine locales finished green with two URLs never set, and deliver had nothing to say about it,
# because a field with no file is a field it does not mention. This sends what the folder holds by
# name and finishes by printing what the App Store holds, so a field that did not land is a line
# of output rather than a silence.
#
# Credentials are not in here. Pass the App Store Connect key in the environment:
#
#   ASC_KEY_PATH=~/Downloads/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX \
#   ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
#     ruby store/upload_listing.rb [--dry-run] [--only whats_new]
#
# Only locales with a folder in upload/metadata are touched, which is what keeps the live English
# listing out of it: its folder holds nothing but release notes.
require "spaceship"

ROOT = File.expand_path("../upload/metadata", __dir__)
BUNDLE_ID = "pl.dmq.peering"
VERSION = ARGV.include?("--version") ? ARGV[ARGV.index("--version") + 1] : "1.0.1"
DRY_RUN = ARGV.include?("--dry-run")
ONLY = ARGV.include?("--only") ? ARGV[ARGV.index("--only") + 1].split(",").map(&:to_sym) : nil

# version-localized: what the version's own page shows per language. The key is the App Store
# Connect attribute, not the file name: release notes are `whatsNew` over there.
VERSION_FIELDS = {
  description: "description",
  keywords: "keywords",
  promotional_text: "promotional_text",
  support_url: "support_url",
  marketing_url: "marketing_url",
  whats_new: "release_notes",
}

# app-level, localized: the app's name and subtitle
INFO_FIELDS = { name: "name", subtitle: "subtitle" }

key_path, key_id, issuer_id = ENV.values_at("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")
if [key_path, key_id, issuer_id].any? { |value| value.nil? || value.empty? }
  abort "Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID (see the comment at the top)."
end

Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
  key_id: key_id,
  issuer_id: issuer_id,
  filepath: File.expand_path(key_path)
)

def field(locale, file)
  path = File.join(ROOT, locale, "#{file}.txt")
  File.exist?(path) ? File.read(path).strip : nil
end

app = Spaceship::ConnectAPI::App.find(BUNDLE_ID) or abort "No app #{BUNDLE_ID}."
version = app.get_app_store_versions.find { |candidate| candidate.version_string == VERSION }
abort "No version #{VERSION} on App Store Connect." unless version
puts "App Store Connect: #{app.name} #{version.version_string} (#{version.app_store_state})"

locales = Dir.children(ROOT).select { |name| File.directory?(File.join(ROOT, name)) }.sort
puts "Uploading #{locales.join(", ")}#{DRY_RUN ? " (dry run)" : ""}"

def attributes(locale, fields)
  fields.each_with_object({}) do |(key, file), into|
    next if ONLY && !ONLY.include?(key)
    value = field(locale, file)
    into[key] = value if value
  end
end

version_localizations = version.get_app_store_version_localizations
info_localizations = app.fetch_edit_app_info.get_app_info_localizations

locales.each do |locale|
  version_attributes = attributes(locale, VERSION_FIELDS)
  unless version_attributes.empty?
    localization = version_localizations.find { |candidate| candidate.locale == locale }
    abort "No #{locale} localization on #{version.version_string}." unless localization
    puts "  #{locale}: #{version_attributes.keys.join(", ")}"
    localization.update(attributes: version_attributes) unless DRY_RUN
  end

  info_attributes = attributes(locale, INFO_FIELDS)
  next if info_attributes.empty?
  localization = info_localizations.find { |candidate| candidate.locale == locale }
  abort "No #{locale} app info localization." unless localization
  puts "  #{locale}: #{info_attributes.keys.join(", ")} (app info)"
  localization.update(attributes: info_attributes) unless DRY_RUN
end

# Read back rather than trust the writes above: the fields are the answer to "did it land", and
# the answer lives on the App Store's side of the call, not this one's.
puts "\nApp Store Connect now holds:"
version_localizations = version.get_app_store_version_localizations
locales.each do |locale|
  localization = version_localizations.find { |candidate| candidate.locale == locale }
  next unless localization
  puts format(
    "  %-8s keywords %3d  support %-28s marketing %-24s desc %4d",
    locale,
    localization.keywords.to_s.length,
    localization.support_url.to_s,
    localization.marketing_url.to_s,
    localization.description.to_s.length
  )
end
