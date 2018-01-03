#!/usr/bin/env ruby

require 'rack'
require 'faraday'
require 'faraday_middleware/aws_signers_v4'
require 'net/http/persistent'
require 'yaml'

config = YAML.load_file(File.dirname(File.expand_path(__FILE__)) + '/config.yaml')

UPSTREAM_URL = config['upstream_url']
UPSTREAM_SERVICE_NAME = config['upstream_service_name']
UPSTREAM_REGION = config['upstream_region']
LISTEN_PORT = config['listen_port'] || 8080
USERNAME = config['username']
PASSWORD = config['password']


unless ENV['AWS_ACCESS_KEY_ID'].nil? || ENV['AWS_SECRET_ACCESS_KEY'].nil? || ENV['AWS_SESSION_TOKEN'].nil?
  CREDENTIALS = Aws::Credentials.new(ENV['AWS_ACCESS_KEY_ID'],ENV['AWS_SECRET_ACCESS_KEY'],ENV['AWS_SESSION_TOKEN'])
else
  CREDENTIALS = Aws::InstanceProfileCredentials.new
end

forwarder = Proc.new do |env|
  postdata = env['rack.input'].read

  client = Faraday.new(url: UPSTREAM_URL) do |faraday|
    faraday.request(:aws_signers_v4, credentials: CREDENTIALS, service_name: UPSTREAM_SERVICE_NAME, region: UPSTREAM_REGION)
    faraday.adapter(:net_http_persistent)
  end

  headers = env.select {|k,v| k.start_with? 'HTTP_', 'CONTENT_' }
                .map{|key,val| [ key.sub(/^HTTP_/,''), val ] }
                .map{|key,val| { key.sub(/_/,'-') => val} }
                .select {|key,_| key != 'HOST'}
                .reduce Hash.new, :merge

  if env['REQUEST_METHOD'] == 'GET'
    response = client.get "#{env['REQUEST_PATH']}?#{env['QUERY_STRING']}", {}, headers
  elsif env['REQUEST_METHOD'] == 'HEAD'
    response = client.head "#{env['REQUEST_PATH']}?#{env['QUERY_STRING']}", {}, headers
  elsif env['REQUEST_METHOD'] == 'DELETE'
    response = client.delete "#{env['REQUEST_PATH']}?#{env['QUERY_STRING']}", {}, headers
  elsif env['REQUEST_METHOD'] == 'POST'
    response = client.post "#{env['REQUEST_PATH']}?#{env['QUERY_STRING']}", "#{postdata}", headers
  elsif env['REQUEST_METHOD'] == 'PUT'
    response = client.put "#{env['REQUEST_PATH']}?#{env['QUERY_STRING']}", "#{postdata}", headers
  elsif env['REQUEST_METHOD'] == 'OPTIONS'
    response = client.run_request(:options, "#{env['REQUEST_PATH']}?#{env['QUERY_STRING']}", "#{postdata}", headers)
  else
    response = nil
  end
  puts "#{response.status} #{env['REQUEST_METHOD']} #{env['REQUEST_PATH']}?#{env['QUERY_STRING']} #{postdata}"
  [response.status, response.headers, [response.body]]
end

webrick_options = {
    :Port => LISTEN_PORT,
}

app = Rack::Builder.new do
  if USERNAME && PASSWORD
    use Rack::Auth::Basic, "Restricted Area" do |username, password|
      [username, password] == [USERNAME, PASSWORD]
    end
  end
  run forwarder
end.to_app

Rack::Handler::WEBrick.run app, webrick_options
