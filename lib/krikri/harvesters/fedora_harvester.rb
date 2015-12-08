require 'uri'
require_relative 'async_uri_getter'

module Krikri::Harvesters
  ##
  # A harvester implementation for Fedora 3
  #
  # Accepts options passed as `:fedora => opts`
  #
  # Options allowed are:
  #
  #   - batch_size:  The number of records to fetch asynchronously
  #                  in a batch (default: 10)
  #   - max_records: The maximum number of records to harvest
  #                  0 means no limit (default 0)
  #
  class FedoraHarvester
    include Krikri::Harvester

    FedoraHarvestError = Class.new(StandardError)

    def initialize(opts = {})
      @opts = opts.fetch(:fedora, {})
      super

      @opts[:batch_size] ||= 10
      @opts[:max_records] ||= 0

      @getter = AsyncUriGetter.new

      @collection_mets = nil
      @collection_mods = nil
      @records_mets = nil
    end

    ##
    # @return [Integer] the number of records available for harvesting.
    def count
      Integer(records_mets.count)
    end

    ##
    # @return [Enumerator::Lazy] an enumerator of the records targeted by this
    #   harvester.
    def records
      batch_size = @opts.fetch(:batch_size)
      max_records = @opts.fetch(:max_records)
      last_record = max_records == 0 ? count : [count, max_records].min

      (0...last_record - 1).step(batch_size).lazy.flat_map do |offset|
        enumerate_records(records_mets[offset, batch_size])
      end
    end

    ##
    # @param identifier [#to_s] the identifier of the record to get
    # @return [#to_s] the record
    def get_record(identifier)
      enumerate_records(collection_mets
                        .xpath("//mets:dmdSec[@ID=\"#{identifier}\"]"))
    end

    private

    ##
    # Get a batch of records
    # @param mets [Nokogiri] the parsed mets for the records to get
    # @return [Array] an array of @record_class instances
    def enumerate_records(mets)
      batch = []
      mets.each do |rec|
        uri = rec.xpath('mets:mdRef').first.attribute('href').value
        batch << { :request => @getter.add_request(uri: URI.parse(uri)),
                   :id => rec.attribute('ID').value }
      end

      batch.lazy.map do |record|
        record[:request].with_response do |response|
          unless response.code == '200'
            raise FedoraHarvestError, "Couldn't get record #{record[:id]}"
          end
          mods = Nokogiri::XML(response.body)

          mods.child.add_child('<extension />')[0]
            .add_child(collection_mods.xpath('//mods:dateIssued').to_xml)

          @record_class.build(mint_id(record[:id]), mods.to_xml)
        end
      end
    end

    ##
    # Only download and parse the collection level mets file once
    # @return [Nokogiri] the collection mets file, parsed
    def collection_mets
      return @collection_mets if @collection_mets

      @getter.add_request(uri: URI.parse(uri)).with_response do |response|
        unless response.code == '200'
          raise FedoraHarvestError, "Couldn't get collection mets file"
        end

        @collection_mets = Nokogiri::XML(response.body)
      end
    end

    def collection_mods
      return @collection_mods if @collection_mods

      mods_ref = collection_mets
                 .xpath('//mets:dmdSec[@ID="collection-description-mods"]')
                 .first
      uri = mods_ref.xpath('mets:mdRef').first.attribute('href').value

      @getter.add_request(uri: URI.parse(uri)).with_response do |response|
        unless response.code == '200'
          raise FedoraHarvestError, "Couldn't get collection mods file"
        end

        @collection_mods = Nokogiri::XML(response.body)
      end
    end

    def records_mets
      return @records_mets if @records_mets

      @records_mets =
        collection_mets
        .xpath('//mets:dmdSec[@ID!="collection-description-mods"]')
    end
  end
end
