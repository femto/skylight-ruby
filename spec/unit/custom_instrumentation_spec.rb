require 'spec_helper'

describe Skylight::Instrumenter, :http do

  let :hello do
    double('hello')
  end

  context 'when the instrumenter is not running' do

    it 'does not break code' do
      hello.should_receive(:hello)

      Skylight.trace 'Zomg', 'app.rack.request' do |t|
        t.should be_nil

        ret = Skylight.instrument 'foo.bar' do |s|
          s.should be_nil
          hello.hello
          1
        end

        ret.should == 1
      end

      Skylight::Instrumenter.instance.should be_nil
    end

  end

  context 'when the instrumenter is running' do

    before :each do
      Skylight.start! config
      clock.freeze
    end

    after :each do
      Skylight.stop!
    end

    it 'tracks custom instrumentation metrics' do
      hello.should_receive(:hello)

      Skylight.trace 'Testin', 'app.rack.request' do |t|
        clock.skip 0.1
        ret = Skylight.instrument 'app.foo' do
          clock.skip 0.1
          hello.hello
          3
        end

        ret.should == 3
      end

      clock.unfreeze
      server.wait

      server.reports[0].should have(1).endpoints

      ep = server.reports[0].endpoints[0]
      ep.name.should == 'Testin'
      ep.should have(1).traces

      t = ep.traces[0]
      t.should have(2).spans
      t.spans[0].should == span(
        event:      event('app.foo'),
        started_at: 1_000,
        duration:   1_000)
      t.spans[1].should == span(
        event:      event('app.rack.request'),
        started_at: 0,
        duration:   2_000,
        children:   1)
    end

    it 'recategorizes unknown events as other' do
      Skylight.trace 'Testin', 'app.rack.request' do |t|
        clock.skip 0.1
        Skylight.instrument 'foo' do
          clock.skip 0.1
        end
      end

      clock.unfreeze
      server.wait

      ep = server.reports[0].endpoints[0]
      t  = ep.traces[0]

      t.spans[0].should == span(
        event:      event('other.foo'),
        started_at: 1_000,
        duration:   1_000)
    end

    class MyClass
      include Skylight::Helpers

      instrument_method
      def one
        yield if block_given?
      end

      def two
        yield if block_given?
      end

      def three
        yield if block_given?
      end

      instrument_method category: "app.winning", title: "Win"
      def custom
        yield if block_given?
      end

      instrument_method :three

      instrument_method
      def self.singleton_method
        yield if block_given?
      end

    end

    it 'tracks instrumented methods using the helper' do
      Skylight.trace 'Testin', 'app.rack.request' do |t|
        inst = MyClass.new

        clock.skip 0.1
        ret = inst.one { clock.skip 0.1; :one }
        ret.should == :one

        clock.skip 0.1
        inst.two { clock.skip 0.1 }

        clock.skip 0.1
        inst.three { clock.skip 0.1 }

        clock.skip 0.1
        inst.custom { clock.skip 0.1 }

        clock.skip 0.1
        MyClass.singleton_method { clock.skip 0.1 }
      end

      clock.unfreeze
      server.wait

      server.reports[0].should have(1).endpoints

      ep = server.reports[0].endpoints[0]
      ep.name.should == 'Testin'
      ep.should have(1).traces

      t = ep.traces[0]
      t.should have(5).spans

      t.spans[0].should == span(
        event:      event('app.method', 'MyClass#one'),
        started_at: 1_000,
        duration:   1_000)

      t.spans[1].should == span(
        event:      event('app.method', 'MyClass#three'),
        started_at: 5_000,
        duration:   1_000)

      t.spans[2].should == span(
        event:      event('app.winning', 'Win'),
        started_at: 7_000,
        duration:   1_000)

      t.spans[3].should == span(
        event:      event('app.method', 'MyClass.singleton_method'),
        started_at: 9_000,
        duration:   1_000)

      # Root span
      t.spans[4].should == span(
        event:      event('app.rack.request'),
        started_at: 0,
        duration:   10_000,
        children:   4)
    end

  end

end