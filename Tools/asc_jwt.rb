#!/usr/bin/env ruby
# asc_jwt.rb — mints a short-lived App Store Connect API JWT (ES256).
#
# Dependency-free on purpose: the macOS CI runner image ships openssl +
# base64, so the release pipeline pins no gem/npm packages (rubygems.org
# reachability from CI is not something this repo depends on).
#
# Reads the API key material from an env-configurable location so callers
# control cleanup:
#   ASC_KEY_FILE   path to the PKCS#8 .p8 (default: $RUNNER_TEMP/asc-api-key.p8)
#   ASC_KEY_ID     the Key ID from App Store Connect (secret NAME only in logs)
#   ASC_ISSUER_ID  the Issuer ID UUID
#
# Usage: ruby Tools/asc_jwt.rb   -> prints the compact JWT to stdout.
# Everything diagnostic goes to stderr and never contains key material.

require 'json'
require 'tempfile'
require 'base64'

key_file = ENV['ASC_KEY_FILE'] || File.join(ENV['RUNNER_TEMP'].to_s, 'asc-api-key.p8')
key_id = ENV['ASC_KEY_ID']
issuer_id = ENV['ASC_ISSUER_ID']

%w[ASC_KEY_ID ASC_ISSUER_ID].each do |name|
  abort "ERROR: #{name} is not set" if ENV[name].to_s.empty?
end
abort "ERROR: key file not found at #{key_file}" unless File.exist?(key_file)

def b64url(data)
  Base64.urlsafe_encode64(data, padding: false)
end

header = b64url(JSON.generate({ 'alg' => 'ES256', 'kid' => key_id, 'typ' => 'JWT' }))
now = Time.now.to_i
payload = b64url(JSON.generate({
                               'aud' => 'appstoreconnect-v1',
                               'iss' => issuer_id,
                               'iat' => now,
                               'exp' => now + 600 # 10 minutes, ASC max
                             }))
signing_input = "#{header}.#{payload}"

# Sign with openssl (ES256 = ecdsa-with-SHA256, DER output), then convert
# the DER signature to the raw r||s form JWTs require (64 bytes).
der = IO.popen(
  ['openssl', 'dgst', '-sha256', '-sign', key_file],
  'r+b') do |io|
  io.write(signing_input)
  io.close_write
  io.read
end
abort 'ERROR: openssl signing failed' if der.nil? || der.empty?

def der_int(der, offset)
  raise 'malformed DER' unless der.getbyte(offset) == 0x02

  len = der.getbyte(offset + 1)
  body = der.byteslice(offset + 2, len)
  body = body[1..] if body.getbyte(0) == 0x00 # strip sign byte
  [body.rjust(32, "\x00".b), offset + 2 + len]
end

offset = 2 # skip the SEQUENCE tag (0x30) + length byte
r, offset = der_int(der, offset)
s, _ = der_int(der, offset)
signature = b64url((r + s).b)

warn "JWT minted (kid present, 600s lifetime); secret values not logged."
print "#{signing_input}.#{signature}"
