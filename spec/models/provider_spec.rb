require 'spec_helper'
require 'rdf/isomorphic'

module RDF
  module Isomorphic
    alias_method :==, :isomorphic_with?
  end
end

describe Krikri::Provider do
  let(:local_name) { '123' }

  let(:provider) do
    provider = Krikri::Provider.new(local_name)
    provider.providedLabel = "moomin"
    provider
  end

  let(:agg) do
    a = build(:aggregation, :provider => provider)
    a.set_subject! 'moomin'
    a
  end

  shared_context 'with indexed item' do
    before do
      agg.save
      indexer = Krikri::QASearchIndex.new
      indexer.add(agg.to_jsonld['@graph'].first)
      indexer.commit
    end

    after do
      indexer = Krikri::QASearchIndex.new
      indexer.delete_by_query(['*:*'])
      indexer.commit
    end
  end

  describe '.all' do
    it 'with no items is empty' do
      expect(described_class.all).to be_empty
    end

    context 'with item' do
      include_context 'with indexed item'

      it 'returns all items' do
        # todo: ActiveTriples::Resource equality needs work
        expect(described_class.all.map(&:rdf_subject))
          .to contain_exactly provider.rdf_subject
      end
    end

    context 'with bnode provider' do
      include_context 'with indexed item'

      let(:provider) { DPLA::MAP::Agent.new }

      it 'ignores bnodes' do
        expect(described_class.all).to be_empty
      end
    end
  end

  describe '.find' do
    include_context 'with indexed item'

    it 'finds the provider' do
      expect(described_class.find(local_name)).to eq provider
    end

    it 'populates graph' do
      expect(described_class.find(local_name).count)
        .to eq provider.count
    end

    it 'returns property values' do
      expect(described_class.find(local_name).providedLabel)
        .to eq provider.providedLabel
    end
  end

  describe '#records' do
    include_context 'with indexed item'

    it 'gives the record' do
      # @todo fix once {ActiveTriples::RDFSource} equality is figured out
      expect(provider.records.map(&:rdf_subject))
        .to contain_exactly agg.rdf_subject
    end
  end

  describe '#id' do
    it 'gives a valid id for initializing resource' do
      expect(Krikri::Provider.new(provider.id).rdf_subject)
        .to eq provider.rdf_subject
    end

    it 'does not include the base uri' do
      expect(provider.id).not_to include provider.base_uri
    end
  end

  describe '#provider_name' do
    it 'gives prefLabel if present' do
      provider.label = 'littly my'
      expect(provider.provider_name).to eq provider.label.first
    end

    it 'with multiple labels gives just one' do
      provider.label = ['little my', 'snork']
      expect(provider.provider_name).to eq provider.label.first
    end

    it 'gives providedLabel if no prefLabel present' do
      expect(provider.provider_name).to eq provider.providedLabel.first
    end

    it 'gives `#id` with with no labels' do
      provider.label = nil
      provider.providedLabel = nil
      expect(provider.provider_name).to eq provider.id
    end
  end
end