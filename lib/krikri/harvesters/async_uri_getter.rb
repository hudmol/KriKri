require 'net/http'
require 'thread'
require 'uri'

# Get URIs asynchronously
class AsyncUriGetter
  def initialize(opts: {})
    super()
    @follow_redirects = follow_redirects(opts: opts)
  end

  def add_request(uri: '', headers: {}, opts: {})
    raise 'uri must be a URI' unless uri.is_a?(URI)
    Request.new(uri, headers, follow_redirects: follow_redirects(opts))
  end

  Request = Struct.new(:uri, :headers, :opts) do
    def initialize(*)
      super
      @follow_redirects = opts[:follow_redirects]
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
        response = nil
        uri_to_try = uri
        10.times do
          http = Net::HTTP.new(uri_to_try.host, uri_to_try.port)
          http.use_ssl = true if uri_to_try.scheme == 'https'

          request = Net::HTTP::Get.new(uri_to_try)
          headers.each do |header, value|
            request[header.to_s] = value
          end

          response = http.request(request)

          break unless @follow_redirects
          break unless response.is_a? Net::HTTPRedirection

          if response['location']
            uri_to_try = URI.parse(response['location'])
          else
            # this shouldn't happen, let the caller deal with it
            break
          end
        end

        response
      end
    end
  end

  private

  def follow_redirects(opts: {})
    if opts.key?(:follow_redirects)
      opts[:follow_redirects]
    else
      @follow_redirects
    end
  end
end
