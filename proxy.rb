#!/usr/bin/env ruby

require 'rack'
require 'faraday'
require 'faraday_middleware/aws_signers_v4'
require 'net/http/persistent'
require 'yaml'
require 'patron'
require 'pry'

config = YAML.load_file(File.dirname(File.expand_path(__FILE__)) + '/config.yaml')

UPSTREAM_URL = config['upstream_url']
UPSTREAM_PATH_PREFIX = config['upstream_path_prefix']
UPSTREAM_SERVICE_NAME = config['upstream_service_name']
UPSTREAM_REGION = config['upstream_region']
LISTEN_PORT = config['listen_port'] || 8080
BIND_ADDRESS = config['bind_address']
HTTP_USERNAME = config['http_username']
HTTP_PASSWORD = config['http_password']
ACCESS_KEY = config['aws_access_key'] || ENV['AWS_ACCESS_KEY_ID']
SECRET_ACCESS_KEY = config['aws_secret_access_key'] || ENV['AWS_SECRET_ACCESS_KEY']


unless ACCESS_KEY.nil? || SECRET_ACCESS_KEY.nil?
  CREDENTIALS = Aws::Credentials.new(ACCESS_KEY, SECRET_ACCESS_KEY)
else
  CREDENTIALS = Aws::InstanceProfileCredentials.new
end

forwarder = Proc.new do |env|
  postdata = env['rack.input'].read

  client = Faraday.new(url: UPSTREAM_URL) do |faraday|
    faraday.options[:open_timeout] = 10
    faraday.options[:timeout] = 20
    faraday.request(:aws_signers_v4, credentials: CREDENTIALS, service_name: UPSTREAM_SERVICE_NAME, region: UPSTREAM_REGION)
    faraday.adapter :patron
  end

  headers = env.select {|k,v| k.start_with? 'HTTP_', 'CONTENT_' }
                .map{|key,val| [ key.sub(/^HTTP_/,''), val ] }
                .map{|key,val| { key.sub(/_/,'-') => val} }
                .select {|key,_| key != 'HOST'}
                .reduce Hash.new, :merge

  headers.delete("CONNECTION")
  request_path = "#{env['REQUEST_PATH']}?#{env['QUERY_STRING']}"
  if UPSTREAM_PATH_PREFIX && !request_path.match(/^\/?#{UPSTREAM_PATH_PREFIX}/)
    request_path = UPSTREAM_PATH_PREFIX
  end

  if env['REQUEST_METHOD'] == 'GET'
    response = client.get request_path, {}, headers
  elsif env['REQUEST_METHOD'] == 'HEAD'
    response = client.head request_path, {}, headers
  elsif env['REQUEST_METHOD'] == 'DELETE'
    response = client.delete request_path, {}, headers
  elsif env['REQUEST_METHOD'] == 'POST'
    response = client.post request_path, "#{postdata}", headers
  elsif env['REQUEST_METHOD'] == 'PUT'
    response = client.put request_path, "#{postdata}", headers
  elsif env['REQUEST_METHOD'] == 'OPTIONS'
    response = client.run_request(:options, request_path, "#{postdata}", headers)
  else
    response = nil
  end

  puts "#{response.status} #{env['REQUEST_METHOD']} #{env['REQUEST_PATH']}?#{env['QUERY_STRING']} #{postdata}"
  [response.status, response.headers, [response.body]]
end

webrick_options = {
  :Port => LISTEN_PORT
}
webrick_options[:Host] = BIND_ADDRESS if BIND_ADDRESS

app = Rack::Builder.new do
  if HTTP_USERNAME && HTTP_PASSWORD
    use Rack::Auth::Basic, "Restricted Area" do |username, password|
      [username, password] == [HTTP_USERNAME, HTTP_PASSWORD]
    end
  end
  run forwarder
end.to_app

Rack::Handler::WEBrick.run app, webrick_options
