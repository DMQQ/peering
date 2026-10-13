#!/usr/bin/env ruby
# Uploads the product page header videos and the search result images to the App Asset Library and
# places them on the version's localizations, then reads every asset and placement back.
#
# Neither fastlane's `deliver` nor Spaceship knows the App Asset Library yet, so this borrows only
# Spaceship's API-key token and speaks to the documented endpoints itself:
#   https://developer.apple.com/documentation/appstoreconnectapi/app-asset-library
#
# **It never submits anything for review.** Placements follow their parent surface, so the version
# still has to be submitted from App Store Connect (or by whatever submits the version).
#
# Files, one per locale folder name (the same names upload/metadata uses):
#   upload/creative/header/<locale>.mp4   3840x1646, 30 fps, 5 to 30 seconds
#   upload/creative/search/<locale>.png   3840x2560
#
# Credentials are not in here. Pass the App Store Connect key in the environment:
#
#   ASC_KEY_PATH=~/Downloads/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX \
#   ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 \
#   PATH="/opt/homebrew/opt/ruby/bin:$PATH" GEM_PATH="$(brew --prefix fastlane)/libexec" \
#     ruby store/upload_creative_assets.rb [--dry-run] [--version 1.0.1] [--only de-DE,ja] [--spec-report]
#
# (The PATH and GEM_PATH are what the `fastlane` launcher sets, so `require "spaceship"` finds the
# copy Homebrew installed. Run python3 store/stage_creative.py first: it fills upload/creative.)
#
# `--spec-report` prints what the reference data says about the two placement types and uploads
# nothing: run it first, since the placement groups come from there and not from this file.
require "spaceship"
require "json"
require "net/http"
require "uri"

ROOT = File.expand_path("../upload/creative", __dir__)
API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "pl.dmq.peering"
VERSION = ARGV.include?("--version") ? ARGV[ARGV.index("--version") + 1] : "1.0.1"
DRY_RUN = ARGV.include?("--dry-run")
SPEC_REPORT = ARGV.include?("--spec-report")
ONLY = ARGV.include?("--only") ? ARGV[ARGV.index("--only") + 1].split(",") : nil

HEADER = { placement_type: "PRODUCT_PAGE_HEADER_ASSET", folder: "header", extension: "mp4", resource: "appAssetLibraryVideos", relationship: "video" }
SEARCH = { placement_type: "APP_STORE_SEARCH_RESULTS_ASSET", folder: "search", extension: "png", resource: "appAssetLibraryImages", relationship: "image" }

key_path, key_id, issuer_id = ENV.values_at("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")
if [key_path, key_id, issuer_id].any? { |value| value.nil? || value.empty? }
  abort "Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID (see the comment at the top)."
end

TOKEN = Spaceship::ConnectAPI::Token.create(key_id: key_id, issuer_id: issuer_id, filepath: File.expand_path(key_path))
Spaceship::ConnectAPI.token = TOKEN

# One request to the API. A failure raises with the body Apple sent, because its error text is the
# only explanation there is for a 409 or a 422.
def api(method, path, body: nil)
  uri = URI(path.start_with?("http") ? path : "#{API}#{path}")
  request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
  request["Authorization"] = "Bearer #{TOKEN.text}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  raise "#{method.upcase} #{uri.path} -> #{response.code}: #{response.body}" unless response.code.to_i.between?(200, 299)

  response.body.to_s.empty? ? {} : JSON.parse(response.body)
end

# Sends each part Apple asks for to the URL it gave. Those URLs are signed: no token goes with them.
def upload_parts(operations, path)
  operations.each do |operation|
    uri = URI(operation["url"])
    request = Net::HTTP.const_get(operation["method"].capitalize).new(uri)
    operation["requestHeaders"].each { |header| request[header["name"]] = header["value"] }
    request.body = File.binread(path, operation["length"], operation["offset"])
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
    raise "part at #{operation['offset']} -> #{response.code}: #{response.body}" unless response.code.to_i.between?(200, 299)
  end
end

def poll(resource, id, done_states)
  60.times do
    asset = api(:get, "/v1/#{resource}/#{id}")["data"]
    state = asset["attributes"]["state"]
    return asset if done_states.include?(state)
    raise "#{resource} #{id} #{state}: #{asset['attributes']['stateDetails']}" if state == "FAILED"

    sleep 5
  end
  raise "#{resource} #{id} still processing after five minutes"
end

def reference_data
  api(:get, "/v1/appAssetLibraryRefData")
end

# The group a placement type accepts comes from the reference data's specMappings. Printing the
# whole entry is the point of --spec-report, so a wrong guess here shows up as text rather than a 422.
def groups_for(reference, placement_type)
  entry = JSON.parse(JSON.generate(reference)).dig("data")
  found = []
  walk = lambda do |node|
    case node
    when Hash
      found << node if node["placementType"] == placement_type
      node.each_value { |child| walk.call(child) }
    when Array
      node.each { |child| walk.call(child) }
    end
  end
  walk.call(entry)
  found
end

app = Spaceship::ConnectAPI::App.find(BUNDLE_ID) or abort "No app #{BUNDLE_ID}."
version = app.get_app_store_versions.find { |candidate| candidate.version_string == VERSION }
abort "No version #{VERSION} on App Store Connect." unless version
puts "App Store Connect: #{app.name} #{version.version_string} (#{version.app_store_state})"

reference = reference_data
if SPEC_REPORT
  [HEADER, SEARCH].each do |kind|
    puts "\n#{kind[:placement_type]}"
    puts JSON.pretty_generate(groups_for(reference, kind[:placement_type]))
  end
  exit
end

library = api(:get, "/v1/apps/#{app.id}/assetLibrary")["data"]
puts "Asset library #{library['id']}"

group_for = lambda do |kind|
  mapping = groups_for(reference, kind[:placement_type]).flat_map { |entry| entry["specMappings"] || [] }
  ids = mapping.map { |item| item["groupId"] || item["placementGroup"] || item["group"] }.compact.uniq
  abort "No placement group for #{kind[:placement_type]} in the reference data; run with --spec-report." if ids.empty?
  ids.first
end
groups = { HEADER => group_for.call(HEADER), SEARCH => group_for.call(SEARCH) }
groups.each { |kind, group| puts "#{kind[:placement_type]} goes in #{group}" }

# One asset: reserve, upload the parts, commit, wait for processing. An asset with the same
# reference name is reused, so a re-run after a failure does not upload everything again.
def asset_for(library_id, kind, locale, path)
  name = "#{kind[:folder]} #{locale} #{File.basename(path)}"
  listed = api(:get, "/v1/appAssetLibraries/#{library_id}/#{kind[:resource].sub('appAssetLibrary', '').downcase}?filter[referenceName]=#{URI.encode_www_form_component(name)}")["data"]
  return listed.first if listed.any?

  attributes = { fileName: File.basename(path), fileSize: File.size(path), category: "CREATIVE_ASSETS", referenceName: name }
  attributes[:previewFrameTimeCode] = "00:00:04:00" if kind == HEADER
  reserved = api(:post, "/v1/#{kind[:resource]}", body: { data: { type: kind[:resource], attributes: attributes,
    relationships: { assetLibrary: { data: { type: "appAssetLibraries", id: library_id } } } } })["data"]
  upload_parts(reserved["attributes"]["uploadOperations"], path)
  api(:patch, "/v1/#{kind[:resource]}/#{reserved['id']}", body: { data: { type: kind[:resource], id: reserved["id"], attributes: { uploaded: true } } })
  poll(kind[:resource], reserved["id"], %w[PREPARE_FOR_SUBMISSION APPROVED])
end

version.get_app_store_version_localizations.sort_by(&:locale).each do |localization|
  next if ONLY && !ONLY.include?(localization.locale)

  puts "\n#{localization.locale}"
  [HEADER, SEARCH].each do |kind|
    path = File.join(ROOT, kind[:folder], "#{localization.locale}.#{kind[:extension]}")
    unless File.exist?(path)
      puts "  #{kind[:folder]}: no file, left alone"
      next
    end
    puts "  #{kind[:folder]}: #{File.basename(path)} (#{File.size(path) / 1024} KB)"
    next if DRY_RUN

    asset = asset_for(library["id"], kind, localization.locale, path)
    placement = api(:post, "/v1/appAssetLibraryPlacements", body: { data: { type: "appAssetLibraryPlacements",
      attributes: { placementType: kind[:placement_type], placementGroup: groups[kind] },
      relationships: { kind[:relationship] => { data: { type: kind[:resource], id: asset["id"] } },
                       appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: localization.id } } } } })["data"]
    puts "    asset #{asset['id']} #{asset['attributes']['state']}, placement #{placement['id']} #{placement['attributes']['state']}"
  rescue RuntimeError => error
    puts "    #{error.message}"
  end
end
