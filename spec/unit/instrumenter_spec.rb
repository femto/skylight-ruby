require 'spec_helper'
require 'securerandom'
require 'base64'
require "stringio"

describe "Skylight::Instrumenter", :http, :agent do

  context "boot" do

    let :logger_out do
      StringIO.new
    end

    let :logger do
      log = Logger.new(logger_out)
      log.level = Logger::DEBUG
      log
    end

    before :each do
      @old_logger = config.logger
      config.logger = logger
    end

    after :each do
      Skylight.stop!
      config.logger = @old_logger
    end

    it 'validates the token' do
      stub_token_verification
      expect(Skylight.start!(config)).to be_truthy
    end

    it 'warns about unvalidated tokens' do
      stub_token_verification(500)
      expect(Skylight.start!(config)).to be_truthy
    end

    it 'fails with invalid token' do
      stub_token_verification(401)
      expect(Skylight.start!(config)).to be_falsey
    end

    it "doesn't crash on failed config" do
      allow(Skylight::Config).to receive(:new).and_raise(Skylight::ConfigError.new("Test Failure"))
      expect(Skylight::Instrumenter).to receive(:warn).
        with("[SKYLIGHT] [#{Skylight::VERSION}] Unable to start Instrumenter; msg=Test Failure; class=Skylight::ConfigError")

      expect do
        Skylight.start!
      end.to_not raise_error
    end

    it "doesn't crash on failed start" do
      allow(Skylight::Instrumenter).to receive(:new).and_raise("Test Failure")
      expect(logger).to receive(:warn).
        with("[SKYLIGHT] [#{Skylight::VERSION}] Unable to start Instrumenter; msg=Test Failure; class=RuntimeError")

      expect do
        Skylight.start!(config)
      end.to_not raise_error
    end

  end

  shared_examples 'an instrumenter' do

    context "when Skylight is running" do
      before :each do
        start!
        clock.freeze
      end

      after :each do
        Skylight.stop!
      end

      it 'records the trace' do
        Skylight.trace 'Testin', 'app.rack' do |t|
          clock.skip 1
        end

        clock.unfreeze
        server.wait resource: '/report'

        expect(server.reports[0].endpoints.count).to eq(1)

        ep = server.reports[0].endpoints[0]
        expect(ep.name).to eq('Testin')
        expect(ep.traces.count).to eq(1)

        t = ep.traces[0]
        expect(t.spans.count).to eq(1)
        expect(t.uuid).to eq('TODO')
        expect(t.spans[0]).to eq(span(
          event:      event('app.rack'),
          started_at: 0,
          duration:   10_000 ))
      end

      it 'ignores disabled parts of the trace' do
        Skylight.trace 'Testin', 'app.rack' do |t|
          Skylight.disable do
            ActiveSupport::Notifications.instrument('sql.active_record', name: "Load User", sql: "SELECT * FROM posts", binds: []) do
              clock.skip 1
            end
          end
        end

        clock.unfreeze
        server.wait resource: '/report'

        expect(server.reports[0].endpoints.count).to eq(1)

        ep = server.reports[0].endpoints[0]
        expect(ep.name).to eq('Testin')
        expect(ep.traces.count).to eq(1)

        t = ep.traces[0]
        expect(t.spans.count).to eq(1)
        expect(t.uuid).to eq('TODO')
        expect(t.spans[0]).to eq(span(
          event:      event('app.rack'),
          started_at: 0,
          duration:   10_000 ))
      end

      it "handles un-lexable SQL" do
        bad_sql = "!!!"

        Skylight.trace 'Testin', 'app.rack' do |t|
          ActiveSupport::Notifications.instrument('sql.active_record', name: "Load User", sql: bad_sql, binds: []) do
            clock.skip 1
          end
        end

        clock.unfreeze
        server.wait resource: '/report'

        expect(server.reports[0].endpoints.count).to eq(1)

        ep = server.reports[0].endpoints[0]
        expect(ep.name).to eq('Testin')
        expect(ep.traces.count).to eq(1)

        t = ep.traces[0]
        expect(t.spans.count).to eq(2)
        expect(t.uuid).to eq('TODO')

        expect(t.spans[0]).to eq(span(
          event:      event('app.rack'),
          started_at: 0,
          duration:   10_000 ))

        expect(t.spans[1]).to eq(span(
          parent:     0,
          event:      event('db.sql.query', 'Load User'),
          started_at: 0,
          duration:   10_000 ))
      end

      it "handles SQL with binary data" do
        bad_sql = "SELECT ???LOL??? \xCE ;;;NOTSQL;;;".force_encoding("BINARY")
        encoded_sql = Base64.encode64(bad_sql)

        Skylight.trace 'Testin', 'app.rack' do |t|
          ActiveSupport::Notifications.instrument('sql.active_record', name: "Load User", sql: bad_sql, binds: []) do
            clock.skip 1
          end
        end

        clock.unfreeze
        server.wait resource: '/report'

        expect(server.reports[0].endpoints.count).to eq(1)

        ep = server.reports[0].endpoints[0]
        expect(ep.name).to eq('Testin')
        expect(ep.traces.count).to eq(1)

        t = ep.traces[0]
        expect(t.spans.count).to eq(2)
        expect(t.uuid).to eq('TODO')

        expect(t.spans[0]).to eq(span(
          event:      event('app.rack'),
          started_at: 0,
          duration:   10_000 ))

        expect(t.spans[1]).to eq(span(
          parent:     0,
          event:      event('db.sql.query', 'Load User'),
          started_at: 0,
          duration:   10_000 ))
      end

      it "handles invalid string encodings" do
        bad_sql = "SELECT ???LOL??? \xCE ;;;NOTSQL;;;".force_encoding("UTF-8")
        encoded_sql = Base64.encode64(bad_sql)

        Skylight.trace 'Testin', 'app.rack' do |t|
          ActiveSupport::Notifications.instrument('sql.active_record', name: "Load User", sql: bad_sql, binds: []) do
            clock.skip 1
          end
        end

        clock.unfreeze
        server.wait resource: '/report'

        expect(server.reports[0].endpoints.count).to eq(1)

        ep = server.reports[0].endpoints[0]
        expect(ep.name).to eq('Testin')
        expect(ep.traces.count).to eq(1)

        t = ep.traces[0]
        expect(t.spans.count).to eq(2)
        expect(t.uuid).to eq('TODO')

        expect(t.spans[0]).to eq(span(
          event:      event('app.rack'),
          started_at: 0,
          duration:   10_000 ))

        expect(t.spans[1]).to eq(span(
          parent:     0,
          event:      event('db.sql.query', 'Load User'),
          started_at: 0,
          duration:   10_000 ))
      end

      it "ignores endpoints" do
        config[:ignored_endpoint] = "foo#heartbeat"
        instrumenter = Skylight::Instrumenter.new(config)

        Skylight.trace 'foo#bar', 'app.rack' do |t|
          clock.skip 1
        end

        Skylight.trace 'foo#heartbeat', 'app.rack' do |t|
          clock.skip 1
        end

        clock.unfreeze
        server.wait resource: '/report'

        expect(server.reports[0]).to have(1).endpoints
        expect(server.reports[0].endpoints.map(&:name)).to eq(["foo#bar"])
      end

      it "ignores multiple endpoints" do
        config[:ignored_endpoint] = "foo#heartbeat"
        config[:ignored_endpoints] = ["bar#heartbeat", "baz#heartbeat"]

        Skylight.trace 'foo#bar', 'app.rack' do |t|
          clock.skip 1
        end

        %w( foo bar baz ).each do |name|
          Skylight.trace "#{name}#heartbeat", 'app.rack' do |t|
            clock.skip 1
          end
        end

        clock.unfreeze
        server.wait resource: '/report'

        expect(server.reports[0]).to have(1).endpoints
        expect(server.reports[0].endpoints.map(&:name)).to eq(["foo#bar"])
      end

      it "ignores multiple endpoints with commas" do
        config[:ignored_endpoints] = "foo#heartbeat, bar#heartbeat,baz#heartbeat"

        Skylight.trace 'foo#bar', 'app.rack' do |t|
          clock.skip 1
        end

        %w( foo bar baz ).each do |name|
          Skylight.trace "#{name}#heartbeat", 'app.rack' do |t|
            clock.skip 1
          end
        end

        clock.unfreeze
        server.wait resource: '/report'

        expect(server.reports[0]).to have(1).endpoints
        expect(server.reports[0].endpoints.map(&:name)).to eq(["foo#bar"])
      end
    end

    def with_endpoint(endpoint)
      config[:trace_info].current = Struct.new(:endpoint).new(endpoint)
      yield
    ensure
      config[:trace_info] = nil
    end

    it "limits unique descriptions to 100" do
      config[:trace_info] = Struct.new(:current).new
      instrumenter = Skylight::Instrumenter.new(config)

      with_endpoint("foo#bar") do
        100.times do
          description = SecureRandom.hex
          expect(instrumenter.limited_description(description)).to eq(description)
        end

        description = SecureRandom.hex
        expect(instrumenter.limited_description(description)).to eq(Skylight::Instrumenter::TOO_MANY_UNIQUES)
      end
    end

  end

  context 'standalone' do

    let(:log_path) { tmp('skylight.log') }
    let(:agent_strategy) { 'standalone' }

    it_behaves_like 'an instrumenter'

  end

end
