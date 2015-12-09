require 'async_uri_getter'

module Krikri::Harvesters
  ##
  # A harvester for NYPL's API
  #
  class NyplHarvester
    include Krikri::Harvester

    DEFAULT_URI = 'http://api.repo.nypl.org/api/v1'
    DEFAULT_NAME = 'nypl'
    DEFAULT_BATCHSIZE = 10
    DEFAULT_THREAD_COUNT = 5

    ##
    # Initialize, and set default options as appropriate.
    #
    # @param opts [Hash] a hash of options as defined by {.expected_opts}
    #
    # @example
    #    Typical instantiation, good for most cases:
    #
    #        Krikri::Harvesters::NyplHarvester.new(apikey: '[key]')
    #
    # Parameters to 'opts':
    #
    # - uri:        See Krikri::Harvester#initialize.
    #               Defaults to "http://api.repo.nypl.org/api/v1'"
    # - name:       See Krikri::Harvester#initialize.  Defaults to "nypl"
    # - batchsize:  The number of records to fetch with each API request.
    #               Defaults to 10.
    # - threads:    The number of record pages to fetch in parallel.
    #               Defaults to 5.
    #
    def initialize(opts = {})
      @opts = opts.fetch(:nypl)
      @opts[:name] ||= DEFAULT_NAME
      @opts[:threads] ||= DEFAULT_THREAD_COUNT
      @opts[:batchsize] ||= DEFAULT_BATCHSIZE

      super({ uri: DEFAULT_URI }.merge(opts))

      @http = AsyncUriGetter.new
    end

    ##
    # @see Krikri::Harvester.expected_opts
    def self.expected_opts
      {
        key: :nypl,
        opts: {
          threads:  { type: :integer, required: false },
          batchsize:  { type: :integer, required: false }
        }
      }
    end

    ##
    # @see Krikri::Harvester#count
    def count
      collection_counts = list_collections.map do |collection_uuid|
        req = request("/items/#{collection_uuid}", page: 1, per_page: 0)
        req.with_response do |response|
          if response.code == '200'
            Integer(Nokogiri::XML(response.body)
                     .xpath('//nyplAPI/response/numResults')[0].text)
          else
            Krikri::Logger.log(:error, "request failed for URI #{req.uri}")
            raise
          end
        end
      end

      collection_counts.reduce(0) { |a, e| a + e }
    end

    ##
    # @return [Enumerator::Lazy] an enumerator of the records targeted by this
    #   harvester.
    def records
      Enumerator.new do |en|
        list_collections.each do |collection_uuid|
          page_count = collection_page_count(collection_uuid, @opts[:batchsize])

          # Fetch `thread_count` pages of records in parallel.
          (1..page_count).each_slice(@opts[:threads]) do |pages|
            requests = pages.map do |page|
              request("/items/#{collection_uuid}",
                      page: page,
                      per_page: @opts[:batchsize])
            end

            # Not strictly necessary, but just to ensure we wait for the
            # outstanding threads to finish before launching any others so we're
            # not hitting the API harder than we planned.
            requests.each(&:join)

            requests.each do |request|
              request.with_response do |response|
                if response.code == '200'
                  enumerate_records(response.body).each { |doc| en << doc }
                else
                  msg = "request failed for URI #{request.uri}"
                  Krikri::Logger.log(:error, msg)
                end
              end
            end
          end
        end
      end
    end

    private

    ##
    # Determine the number of pages of records we'll need to fetch for a given
    # collection.
    #
    # @param collection_uuid [String] The identifier of the collection
    #
    # @param page_size [Integer] The page size we're using
    #
    def collection_page_count(collection_uuid, page_size)
      req = request("/items/#{collection_uuid}", page: 1, per_page: page_size)
      req.with_response do |response|
        if response.code == '200'
          Integer(Nokogiri::XML(response.body)
                   .xpath('//nyplAPI/request/totalPages').text)
        else
          Krikri::Logger.log(:error, "request failed for URI #{req.uri}")
          raise
        end
      end
    end

    ##
    # Convert an (XML) page of capture records into OriginalRecords
    #
    # @param response_xml [String] A page of capture records
    #
    # @return [Array<OriginalRecord>]
    #
    def enumerate_records(response_xml)
      record_list = Nokogiri::XML(response_xml)
                    .xpath('//nyplAPI/response/capture')
                    .map do |capture|
        {
          identifier: capture.xpath('./uuid').text,
          mods_item_url: capture.xpath('./apiUri').text + '.xml',
          capture_record: capture
        }
      end

      # We need to fetch the MODS record for each item.  Do that in parallel.
      record_list.each_slice(@opts[:threads]) do |sublist|
        fetch_item_records(sublist)
      end

      record_list.map do |record|
        item_record = record[:mods_item_record]
                      .xpath('//nyplAPI/response/mods')[0]

        item_record.add_namespace('mods', 'http://www.loc.gov/mods/v3')
        item_record
          .add_child('<extension />')[0]
          .add_child(record[:capture_record])

        @record_class.build(mint_id(record[:identifier]), item_record.to_xml)
      end
    end

    ##
    # @param list [List<Hash>] a list of hashes, each containing a
    #   :mods_item_url to be fetched.
    #
    # @return [void] the :mods_item_record property of each hash will have been
    #   populated with the XML MODS record for the item.
    #
    def fetch_item_records(list)
      requests = list.map { |record| request(record[:mods_item_url]) }
      list.zip(requests).each do |record, request|
        request.with_response do |response|
          if response.code == '200'
            record[:mods_item_record] = Nokogiri::XML(response.body)
          else
            Krikri::Logger.log(:error,
                               "Failure when fetching #{request.uri}. " \
                               'Record skipped')
          end
        end
      end
    end

    ##
    # @param endpoint_uri [String] the (relative or absolute) URI to be fetched
    #
    # @param params [Hash<String, String>] Additional URL parameters to be sent
    # with the request
    #
    def request(endpoint_uri, params = {})
      abs_url = if endpoint_uri.start_with?('/')
                  "#{uri}#{endpoint_uri}.xml"
                else
                  endpoint_uri
                end

      request_uri = URI.parse(abs_url)
      request_uri.query = URI.encode_www_form(params) unless params.empty?

      @http.add_request(uri: request_uri, headers: headers)
    end

    ##
    # @return [Hash] A suitable Authorization header for NYPL
    #
    def headers
      {
        'Authorization' => "Token token=\"#{@opts.fetch(:apikey)}\""
      }
    end

    ##
    # @return [Array<String>] A list of collection UUIDs eligible for harvest
    #
    def list_collections
      request('/items/roots').with_response do |response|
        if response.code == '200'
          Nokogiri::XML(response.body)
            .xpath('//nyplAPI/response/uuids/uuid')
            .map(&:text)
        else
          Krikri::Logger.log(:error,
                             "couldn't fetch collection list: #{response.body}")
          raise
        end
      end
    end
  end
end
