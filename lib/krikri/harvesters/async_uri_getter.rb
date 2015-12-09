require 'net/http'
require 'thread'
require 'uri'

# Get URIs asynchronously
class AsyncUriGetter
  def add_request(uri: '', headers: {})
    raise 'uri must be a URI' unless uri.is_a?(URI)
    Request.new(uri, headers)
  end

  Request = Struct.new(:uri, :headers) do
    def initialize(*)
      super
      @request_thread = start_request
    end

    def join
      @request_thread.join
    end

    def with_response
      yield(@request_thread.value)
    end

    private

    def start_request
      Thread.new do
        Net::HTTP.start(uri.host, uri.port) do |http|
          http.use_ssl = true if uri.scheme == 'https'

          request = Net::HTTP::Get.new(uri)
          headers.each do |header, value|
            request[header.to_s] = value
          end

          http.request(request)
        end
      end
    end
  end
end
