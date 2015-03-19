module Krikri
  class ValidationReport
    include Krikri::QaProviderFilter
    attr_accessor :provider_id

    REQUIRED_FIELDS = ['dataProvider_name', 'isShownAt_id', 'preview_id',
                       'sourceResource_rights', 'sourceResource_title',
                       'sourceResource_type_id']

    ##
    # @param &block may contain provider_id
    #   Sample use:
    #     ValidationReport.new.all do
    #       self.provider_id = '0123'
    #     end
    # @return Array of Blacklight::SolrResponse::Facet's
    def all(&block)
      # set values from block 
      instance_eval &block if block_given?

      query_params = { :rows => 0,
                       'facet.field' => REQUIRED_FIELDS,
                       'facet.mincount' => 10000000,
                       'facet.missing' => true }
      query_params[:fq] = provider_fq(@provider_id) if @provider_id.present?

      Krikri::SolrResponseBuilder.new(query_params).response.facets
    end

    ##
    # @param id [String]
    # @param &block may contain provider_id
    #   Sample use:
    #     ValidationReport.new.find('sourceResource_title') do
    #       self.provider_id = '0123'
    #     end
    # @return Blacklight::SolrResponse
    def find(id, &block)
      # set values from block 
      instance_eval &block if block_given?

      query_params = { :qt => 'standard',
                       :rows => 100,
                       :q => "-#{id}:[* TO *]" }
      query_params[:fq] = provider_fq(@provider_id) if @provider_id.present?

      Krikri::SolrResponseBuilder.new(query_params).response
    end
  end
end