require 'spec_helper'

describe Krikri::Job do
  let(:agent) { double('agent') }

  describe '.perform' do
    let(:activity_id) { 1 }
    let(:activity) { double('activity') }

    before do
      allow(Krikri::Activity).to receive(:find).with(activity_id)
                                  .and_return(activity)
    end

    it 'calls #run on activity by id' do
      expect(activity).to receive(:run).and_return(true)
      described_class.perform(activity_id)
    end

    it 'passes its run method to block' do
      uri = double('uri')
      expect(activity).to receive(:run).and_yield(agent, uri)
      expect(described_class).to receive(:run).with(agent, uri)
      described_class.perform(activity_id)
    end
  end

  describe '.run' do
    it 'calls #run on agent' do
      activity_uri = double('uri')
      expect(agent).to receive(:run).with(activity_uri).and_return(true)
      described_class.run(agent, activity_uri)
    end

    it 'passes with no args if no activity given' do
      expect(agent).to receive(:run).with(no_args).and_return(true)
      described_class.run(agent)
    end

    it 'passes with no args if no agent accepts no args' do
      arity_zero = Proc.new {}
      allow(agent).to receive(:method).with(:run).and_return(arity_zero)

      expect(agent).to receive(:run).with(no_args).and_return(true)
      described_class.run(agent)
    end
  end
end
