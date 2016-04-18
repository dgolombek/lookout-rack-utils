require 'spec_helper'
require 'lookout/rack/utils/log'
require 'timecop'
require 'configatron'

describe Lookout::Rack::Utils::Log do
  subject(:log) { described_class.instance }
  subject(:log_message) { 'foo' }
  let(:filename) { "log" }

  before :each do
    configatron.logging.enabled = true
    allow(configatron.logging).to receive(:file).and_return(filename)
  end

  describe '.debug' do
    context 'if debug is in configatron.statsd.exclude_levels' do
      before { configatron.statsd.exclude_levels = [:debug] }
      after { configatron.statsd.exclude_levels = [] }

      it 'should not log a graphite stat' do
        Lookout::Rack::Utils::Graphite.should_not_receive(:increment).with('log.debug')
        log.debug log_message
      end
    end

    it 'should log a graphite stat' do
      Lookout::Rack::Utils::Graphite.should_receive(:increment).with('log.debug')
      log.debug log_message
    end
  end

  [:debug, :info, :warn, :error, :fatal].each do |method|
    describe ".#{method}" do
      it 'should log a graphite stat' do
        Lookout::Rack::Utils::Graphite.should_receive(:increment).with("log.#{method}")

        log.instance_variable_get(:@logger).should_receive(method).with(log_message).and_call_original

        processed = false
        b = Proc.new { processed = true }

        log.send(method, log_message, &b)
        expect(processed).to be(true)
      end

      it 'should invoke the internal logger object with a given block' do
        log.instance_variable_get(:@logger).should_receive(method).with(log_message).and_call_original
        processed = false
        b = Proc.new { processed = true }
        log.send(method, log_message, &b)
        expect(processed).to be(true)
      end

      it 'should invoke the internal logger object w/o a given block' do
        log.instance_variable_get(:@logger).should_receive(method).with(log_message).and_call_original
        log.send(method, log_message)
      end
    end
  end

  [:debug?, :info?, :warn?, :error?, :fatal?].each do |method|
    describe ".#{method}" do
      it 'returns true when level is debug' do
        expect(log.send(method)).to eq(true)
      end
    end
  end

  # Private method but tested since we can't otherwise test configuration of the singleton
  describe "#build_outputter" do
    let(:logger_name) { "logger" }
    subject(:build_outputter) { log.send(:build_outputter, logger_name)}

    context "when logging to a file" do
      let(:filename) { "foo.log" }
      it "should use a FileOutputter" do
        expect(subject).to be_a(Log4r::FileOutputter)
      end
    end

    context "when logging to STDOUT" do
      let(:filename) { "STDOUT" }
      it "should use a StdoutOutputter" do
        expect(subject).to be_a(Log4r::StdoutOutputter)
      end
    end
  end
end

describe Lookout::Rack::Utils::Log::LookoutFormatter do
  subject(:formatter) { described_class.new }
  let(:logger) do
    logger = double('Mock Logger')
    logger.stub(:name).and_return('RSpec Logger')
    logger.stub(:fullname).and_return('RSpec Logger')
    logger
  end
  let(:project_name) { 'some_project' }
  let(:basedir) { "/home/rspec/#{project_name}" }
  let(:tracer) do
    [
        "#{basedir}/log.rb:63:in `warn'",
        "#{basedir}/spec/log_spec.rb:9:in `block (2 levels) in <top (required)>'"
    ]
  end

  before :all do
    # The root logger creates the log levels, so making sure it's been
    # created
    Log4r::RootLogger.instance
  end


  before :each do
    formatter.stub(:basedir).and_return(basedir)
  end


  describe '#event_filename' do
    subject(:filename) { formatter.event_filename(tracer[1]) }

    context 'with a normal MRI LogEvent' do
      it { should eql('spec/log_spec.rb:9') }
    end

    # We have slightly different log formats under packaged .jar files
    context 'with a LogEvent from a packaged .jar' do
      let(:tracer) { [nil, "backend/metrics.rb:52:in `runloop'"] }
      let(:basedir) { 'file:/home/user/source/projects/stuff.jar!/project' }

      it { should eql('backend/metrics.rb:52') }
    end
  end

  describe '#format' do
    before :each do
      Timecop.freeze
    end

    after :each do
      Timecop.return
    end

    context 'with a valid LogEvent' do
      # Level 3 is the Log4r "warn" level
      let(:level) { 3 }
      let(:data) { 'rspec' }
      let(:timestamp) { Time.now.utc.iso8601 }

      let(:event) do
        event = Log4r::LogEvent.new(level, logger, tracer, data)
      end

      it 'should be properly formatted' do
        expect(formatter.format(event)).to eql("WARN: #{timestamp}: spec/log_spec.rb:9: #{data}\n")
      end
    end

  end

  describe "#common_basedir" do
    subject(:common_basedir) { formatter.common_basedir(path) }

    context "with no common path" do
      let(:path) { "/impossible/path" }

      it "should return basedir" do
        expect(subject).to eq basedir
      end
    end

    context "with a partially shared path" do
      let(:path) { File.expand_path(File.join(basedir, "..", "tmp", "foo.rb")) }

      it "should return shared path" do
        expect(subject).to eq File.expand_path(File.join(basedir, ".."))
      end
    end

    context "with a fully shared path" do
      let(:path) { File.expand_path(File.join(basedir, "tmp.rb")) }
      it "should return full path" do
        expect(subject).to eq basedir
      end
    end
  end
end
