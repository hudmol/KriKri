require 'rubygems'
require 'rsolr'
require 'elasticsearch'

module Krikri
  ##
  # Search index base class that gets extended by QA and Production index
  # classes
  class SearchIndex
    def initialize(opts)
      @bulk_update_size = opts.delete(:bulk_update_size) { 10 }
    end

    ##
    # Add a single JSON document to the search index.
    # Implemented in a child class.
    #
    # @param _ [Hash] Hash that can be serialized to JSON with #to_json
    def add(_)
      fail NotImplementedError
    end

    ##
    # Add a number of JSON documents to the search index at once.
    # Implemented in a child class.
    #
    # @param _ [Array] Hashes that can be serialized to JSON with #to_json
    def bulk_add(_)
      fail NotImplementedError
    end

    ##
    # Shim that determines, for a particular type of index, which strategy
    # to use, adding a single document, or adding them in bulk.  Intended
    # to be overridden as necessary.
    #
    # @see #add
    # @see #bulk_add
    def update_from_activity(activity)
      incremental_update_from_activity(activity)
    end

    protected

    ##
    # Given an activity, use the bulk-update method to load its revised
    # entities into the search index.
    #
    # Any errors on bulk adds are caught and logged, and the batch is skipped.
    #
    # @param activity [Krikri::Activity]
    def bulk_update_from_activity(activity)
      all_aggs = entities_as_json_hashes(activity)
      agg_batches = bulk_update_batches(all_aggs)
      agg_batches.each do |batch|
        index_with_error_handling(activity) { bulk_add(batch) }
      end
    end

    ##
    # Enumerate arrays of JSON strings, one array per batch that is supposed
    # to be loaded into the search index.
    #
    # @param aggregations [Enumerator]
    # @return [Enumerator] Each array of JSON strings
    def bulk_update_batches(aggregations)
      en = Enumerator.new do |e|
        i = 1
        batch = []
        aggregations.each do |agg|
          batch << agg
          if i % @bulk_update_size == 0
            e.yield batch
            batch = []
          end
          i += 1
        end
        e.yield batch if batch.count > 0  # last one
      end
      en.lazy
    end

    ##
    # Given an activity, load its revised entities into the search index one
    # at a time.
    #
    # Any errors on individual record adds are caught and logged, and the 
    # record is skipped.
    #
    # @param activity [Krikri::Activity]
    def incremental_update_from_activity(activity)
      entities_as_json_hashes(activity).each do |h|
        index_with_error_handling(activity) { add(h) }
      end
    end

    ##
    # Given an activity, enumerate over revised entities, represented as
    # hashes that can be serialized to JSON.
    #
    # @param activity [Krikri::Activity]
    # @return [Enumerator]
    def entities_as_json_hashes(activity)
      activity.entities.lazy.map do |agg|
        hash_for_index_schema(agg)
      end
    end

    ##
    # Return a JSON string from the given aggregation in a format suitable for
    # the search index.
    #
    # The default behavior is to turn out the MAPv4 JSON-LD straight from
    # the aggregation.
    #
    # This can be overridden to convert this to MAPv3 JSON-LD or whatever.
    #
    # @param aggregation [DPLA::MAP::Aggregation] The aggregation
    # @return [Hash] Hash that can respond to #to_json for serialization
    def hash_for_index_schema(aggregation)
      aggregation.to_jsonld['@graph'][0]
    end

    private
    
    ##
    # Runs a block, catching any errors and logging them with the given 
    # activity id.
    def index_with_error_handling(activity, &block)
      begin
        yield if block_given?
      rescue => e
        Krikri::Logger
          .log(:error, "indexer error for Activity #{activity}:\n#{e.message}")
      end
    end
  end

  ##
  # Generates flattened Solr documents and manages indexing of DPLA MAP models.
  #
  # @example
  #
  #   indexer = Krikri::QASearchIndex.new
  #   agg = Krikri::Aggregation.new
  #   doc = agg.to_jsonld['@graph'].first
  #
  #   indexer.add(doc)
  #   indexer.commit
  #
  class QASearchIndex < Krikri::SearchIndex
    attr_reader :solr

    ##
    # @param opts [Hash] options to pass to RSolr
    # @see RSolr.connect
    def initialize(opts = {})
      # Override or append to default Solr options
      solr_opts = Krikri::Settings.solr.to_h.merge(opts)
      @solr = RSolr.connect(solr_opts)
      super(opts)
    end

    # TODO: Assure that the following metacharacters are escaped:
    # + - && || ! ( ) { } [ ] ^ " ~ * ? : \

    ##
    # Adds a single JSON document to Solr
    # @param doc [Hash]  A hash that complies with the Solr schema
    def add(doc)
      solr.add solr_doc(doc)
    end

    ##
    # @see Krikri::SearchIndex#update_from_activity
    def update_from_activity(activity)
      fail "#{activity} is not an Activity" unless 
        activity.class == Krikri::Activity
      result = bulk_update_from_activity(activity)
      solr.commit
      result
    end

    ##
    # Add multiple documents to Solr
    # @param docs [Array]  Array of hashes that comply with the Solr schema
    def bulk_add(docs)
      solr.add(docs.map { |d| solr_doc(d) })
    end

    ##
    # Deletes an item from Solr
    # @param String or Array
    def delete_by_id(id)
      solr.delete_by_id id
    end

    ##
    # Deletes items from Solr that match query
    # @param String or Array
    def delete_by_query(query)
      solr.delete_by_query query
    end

    ##
    # Commits changes to Solr, making them visible to new requests
    # Should be run after self.add and self.delete
    # Okay to add or delete multiple docs and commit them all with
    # a single self.commit
    def commit
      solr.commit
    end

    ##
    # Converts JSON document into a Hash that complies with Solr schema
    # @param [JSON]
    # @return [Hash]
    def solr_doc(doc)
      remove_invalid_keys(flat_hash(doc))
    end

    ##
    # Get field names from Solr schema in host application.
    # Will raise exception if file not found.
    # @return [Array]
    def schema_keys
      schema_file = File.join(Rails.root, 'solr_conf', 'schema.xml')
      file = File.open(schema_file)
      doc = Nokogiri::XML(file)
      file.close
      doc.xpath('//fields/field').map { |f| f.attr('name') }
    end

    private

    ##
    # Flattens a nested hash
    # Joins keys with "_" and removes "@" symbols
    # Example:
    #   flat_hash( {"a"=>"1", "b"=>{"c"=>"2", "d"=>"3"} )
    #   => {"a"=>"1", "b_c"=>"2", "b_d"=>"3"}
    def flat_hash(hash, keys = [])
      new_hash = {}

      hash.each do |key, val|
        new_hash[format_key(keys + [key])] = val unless
          val.is_a?(Array) || val.is_a?(Hash)
        new_hash.merge!(flat_hash(val, keys + [key])) if val.is_a? Hash

        if val.is_a? Array
          val.each do |v|
            if v.is_a? Hash
              new_hash.merge!(flat_hash(v, keys + [key])) do |key, f, s|
                Array(f) << s
              end
            else
              formatted_key = format_key(keys + [key])
              new_hash[formatted_key] =
                new_hash[formatted_key] ? (Array(new_hash[formatted_key]) << v) : v
            end
          end
        end
      end

      new_hash
    end

    ##
    # Formats a key to match a field name in the Solr schema
    #
    # Removes unnecessary special character strings that would
    # require special treatment in Solr
    #
    # @param Array
    #
    # TODO: Revisit this to make it more generalizable
    def format_key(keys)
      keys.join('_')
        .gsub('@', '')
        .gsub('http://www.geonames.org/ontology#', '')
        .gsub('http://www.w3.org/2003/01/geo/wgs84_pos#', '')
    end

    ##
    # Remove keys (ie. fields) that are not in the Solr schema.
    # @param [Hash]
    # @return [Hash]
    def remove_invalid_keys(solr_doc)
      valid_keys = schema_keys
      solr_doc.delete_if { |key, _| !key.in? valid_keys }
    end
  end


  ##
  # Production ElasticSearch search index class
  class ProdSearchIndex < Krikri::SearchIndex
    attr_reader :elasticsearch, :index_name

    ##
    # @param [Hash] opts
    #
    # Options used by this class:
    #   - index_name [String]  The name of the ElasticSearch index
    # Other options are passed along to Elasticsearch::Client.
    #
    def initialize(opts = {})
      options = Krikri::Settings.elasticsearch.to_h.merge(opts)
      super(options)
      @index_name = options.delete(:index_name) { 'dpla_alias' }
      @elasticsearch = Elasticsearch::Client.new(options)
    end

    ##
    # Add a number of JSON documents to the search index at once.
    # @param docs [Array] Array of hashes that can be serialized with #to_json
    def bulk_add(docs)
      body = docs.map do |doc|
        {
          index: {
            _index: @index_name,
            _type: doc[:ingestType],
            _id:  doc[:id],
            data: doc
          }
        }
      end
      @elasticsearch.bulk body: body
    end

    ##
    # @see Krikri::SearchIndex#update_from_activity
    def update_from_activity(activity)
      fail "#{activity} is not an Activity" \
        unless activity.class == Krikri::Activity
      bulk_update_from_activity(activity)
    end

    ##
    # @see Krikri::SearchIndex#hash_for_index_schema
    def hash_for_index_schema(aggregation)
      aggregation.to_3_1_json
    end
  end
end
