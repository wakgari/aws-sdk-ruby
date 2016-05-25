$LOAD_PATH.unshift(File.expand_path('../../../build_tools/lib',  __FILE__))
$LOAD_PATH.unshift(File.expand_path('../../../aws-sdk-code-generator/lib',  __FILE__))

require 'simplecov'
require 'rspec'
require 'webmock/rspec'
require 'aws-sdk-core'
require 'build_tools'
require 'aws-sdk-code-generator'

SimpleCov.command_name('test:unit:aws-sdk-core')

# Prevent the SDK unit tests from loading actual credentials while under test.
# By default the SDK attempts to load credentials from:
#
# * ENV, e.g. ENV['AWS_ACCESS_KEY_ID']
# * Shared credentials file, e.g. ~/.aws/credentials
# * EC2 instance metadata server running at 169.254.169.254
#
RSpec.configure do |config|
  config.before(:each) do

    stub_const('ENV', {})

    # disable loading credentials from shared file
    allow(Dir).to receive(:home).and_raise(ArgumentError)

    # disable instance profile credentials
    path = '/latest/meta-data/iam/security-credentials/'
    stub_request(:get, "http://169.254.169.254#{path}").to_raise(SocketError)

  end
end

# Simply returns the request context without any http response info.
class NoSendHandler < Seahorse::Client::Handler
  def call(context)
    Seahorse::Client::Response.new(context: context)
  end
end

# A helper :send_handler that does not send the request, it simply
# returns an empty response.
class DummySendHandler < Seahorse::Client::Handler

  def call(context)
    headers = context.config.response_headers
    headers = Seahorse::Client::Http::Headers.new(headers)
    context.http_response.headers = headers
    context.http_response.status_code = context.config.response_status_code
    context.http_response.body = StringIO.new(context.config.response_body)
    Seahorse::Client::Response.new(context: context)
  end

end

def call_handler(klass, opts = {}, &block)

  operation_name = opts.delete(:operation_name) || 'operation'
  params = opts.delete(:params) || {}

  config = opts.delete(:config) || Seahorse::Client::Configuration.new
  config.add_option(:response_status_code, 200)
  config.add_option(:response_headers, {})
  config.add_option(:response_body, '')
  opts.keys.each { |opt_name| config.add_option(opt_name) }

  context = Seahorse::Client::RequestContext.new(
    operation_name: operation_name,
    config: config.build!(opts),
    params: params)

  yield(context) if block_given?

  klass.new(DummySendHandler.new).call(context)

end

class DummySendPlugin < Seahorse::Client::Plugin
  class Handler < Seahorse::Client::Handler
    def call(context)
      Seahorse::Client::Response.new(
        context: context,
        data: context.config.response_data)
    end
  end
  option(:response_data) { { result: 'success' } }
  handler Handler, step: :send
end

module SpecHelper
  class << self

    def client_with_plugin(options = {}, &block)
      client_class = Class.new(Seahorse::Client::Base)
      client_class.set_plugins([Class.new(Seahorse::Client::Plugin, &block)])
      client_class.new(options)
    end

  end
end

def data_to_hash(obj)
  case obj
  when Struct
    obj.members.each.with_object({}) do |member, hash|
      value = obj[member]
      hash[member] = data_to_hash(value) unless value.nil?
    end
  when Hash
    obj.each.with_object({}) do |(key, value), hash|
      hash[key] = data_to_hash(value)
    end
  when Array then obj.collect { |value| data_to_hash(value) }
  when IO, StringIO then obj.read
  else obj
  end
end

module ApiHelper
  class << self
    def sample_shapes
      {
        'StructureShape' => {
          'type' => 'structure',
          'members' => {
            # complex members
            'Nested' => { 'shape' => 'StructureShape' },
            'NestedList' => { 'shape' => 'StructureList' },
            'NestedMap' => { 'shape' => 'StructureMap' },
            'NumberList' => { 'shape' => 'IntegerList' },
            'StringMap' => { 'shape' => 'StringMap' },
            # scalar members
            'Blob' => { 'shape' => 'BlobShape' },
            'Byte' => { 'shape' => 'ByteShape' },
            'Boolean' => { 'shape' => 'BooleanShape' },
            'Character' => { 'shape' => 'CharacterShape' },
            'Double' => { 'shape' => 'DoubleShape' },
            'Float' => { 'shape' => 'FloatShape' },
            'Integer' => { 'shape' => 'IntegerShape' },
            'Long' => { 'shape' => 'LongShape' },
            'String' => { 'shape' => 'StringShape' },
            'Timestamp' => { 'shape' => 'TimestampShape' },
          }
        },
        'StructureList' => {
          'type' => 'list',
          'member' => { 'shape' => 'StructureShape' }
        },
        'StructureMap' => {
          'type' => 'map',
          'key' => { 'shape' => 'StringShape' },
          'value' => { 'shape' => 'StructureShape' }
        },
        'IntegerList' => {
          'type' => 'list',
          'member' => { 'shape' => 'IntegerShape' }
        },
        'StringMap' => {
          'type' => 'map',
          'key' => { 'shape' => 'StringShape' },
          'value' => { 'shape' => 'StringShape' }
        },
        'BlobShape' => { 'type' => 'blob' },
        'ByteShape' => { 'type' => 'byte' },
        'BooleanShape' => { 'type' => 'boolean' },
        'CharacterShape' => { 'type' => 'character' },
        'DoubleShape' => { 'type' => 'double' },
        'FloatShape' => { 'type' => 'float' },
        'IntegerShape' => { 'type' => 'integer' },
        'LongShape' => { 'type' => 'long' },
        'StringShape' => { 'type' => 'string' },
        'TimestampShape' => { 'type' => 'timestamp' },
      }
    end

    def sample_service(options = {})
      module_name = next_sample_module_name
      options[:api] ||= default_api(options)
      options[:module_names] = [module_name]
      g = AwsSdkCodeGenerator::Generator.new(options)
      #puts(g.generate_src)
      Object.module_eval(g.generate_src)
      Object.const_get(module_name)
    end

    def sample_api(options = {})
      sample_service(options).const_get(:ClientApi).const_get(:API)
    end

    private

    def default_api(options)
      {
        'operations' => {
          'ExampleOperation' => {
            'http' => { 'method' => 'POST', 'requestUri' => '/' },
            'input' => { 'shape' => 'StructureShape' },
            'output' => { 'shape' => 'StructureShape' },
          }
        },
        'shapes' => options.delete(:shapes) || sample_shapes
      }
    end

    def next_sample_module_name
      @sample_api_count ||= 0
      @sample_api_count += 1
      "SampleApi#{@sample_api_count}"
    end

  end
end
