# encoding: utf-8
require "spec_helper"
require "logstash/inputs/generator"
require "logstash/filters/multiline"

class PipelinePqFileOutput < LogStash::Outputs::Base
  config_name "pipelinepqfileoutput"
  milestone 2

  attr_reader :num_closes, :event_count

  def self.make_shared
    @concurrency = :shared
  end

  def initialize(params={})
    super
    @num_closes = 0
    @event_count = 0
    @mutex = Mutex.new
  end

  def register
    self.class.make_shared
  end

  def receive(event)
    @mutex.synchronize do
      @event_count = @event_count.succ
    end
  end

  def close
    @num_closes = 1
  end
end

describe LogStash::Pipeline do
  let(:pipeline_settings_obj) { LogStash::SETTINGS }
  let(:pipeline_id) { "main" }

  let(:multiline_id) { "my-multiline" }
  let(:output_id) { "my-pipelinepqfileoutput" }
  let(:generator_id) { "my-generator" }
  let(:config) do
    <<-EOS
    input {
      generator {
        count => #{number_of_events}
        id => "#{generator_id}"
      }
    }
    filter {
      multiline {
        id => "#{multiline_id}"
        pattern => "hello"
        what => next
      }
    }
    output {
      pipelinepqfileoutput {
        id => "#{output_id}"
      }
    }
    EOS
  end

   let(:pipeline_settings) { { "queue.type" => queue_type, "pipeline.workers" => worker_thread_count, "pipeline.id" => pipeline_id} }

  subject { described_class.new(config, pipeline_settings_obj, metric) }

  let(:counting_output) { PipelinePqFileOutput.new({ "id" => output_id }) }
  let(:metric_store) { subject.metric.collector.snapshot_metric.metric_store }
  let(:metric) { LogStash::Instrument::Metric.new(LogStash::Instrument::Collector.new) }
  let(:base_queue_path) { pipeline_settings_obj.get("path.queue") }
  let(:this_queue_folder) { File.join(base_queue_path, SecureRandom.hex(8)) }

  let(:worker_thread_count) { 8 } # 1 4 8
  let(:number_of_events) { 100_000 }
  let(:page_capacity) { 1 * 1024 * 512 } # 1 128
  let(:queue_type) { "persisted" } #  "memory" "memory_acked"
  let(:times) { [] }

  before :each do
    FileUtils.mkdir_p(this_queue_folder)

    pipeline_settings_obj.set("path.queue", this_queue_folder)
    allow(PipelinePqFileOutput).to receive(:new).with(any_args).and_return(counting_output)
    allow(LogStash::Plugin).to receive(:lookup).with("input", "generator").and_return(LogStash::Inputs::Generator)
    allow(LogStash::Plugin).to receive(:lookup).with("codec", "plain").and_return(LogStash::Codecs::Plain)
    allow(LogStash::Plugin).to receive(:lookup).with("filter", "multiline").and_return(LogStash::Filters::Multiline)
    allow(LogStash::Plugin).to receive(:lookup).with("output", "pipelinepqfileoutput").and_return(PipelinePqFileOutput)

    pipeline_workers_setting = LogStash::SETTINGS.get_setting("pipeline.workers")
    allow(pipeline_workers_setting).to receive(:default).and_return(worker_thread_count)
    pipeline_settings.each {|k, v| pipeline_settings_obj.set(k, v) }
    pipeline_settings_obj.set("queue.page_capacity", page_capacity)
    Thread.new do
      # make sure we have received all the generated events
      while counting_output.event_count < number_of_events do
        sleep 1
      end
      subject.shutdown
    end
    times.push(Time.now.to_f)
    subject.run
    times.unshift(Time.now.to_f - times.first)
  end

  after :each do
    # Dir.rm_rf(this_queue_folder)
  end

  let(:collected_metric) { metric_store.get_with_path("stats/pipelines/") }

  it "populates the pipelines core metrics" do
    _metric = collected_metric[:stats][:pipelines][:main][:events]
    expect(_metric[:duration_in_millis].value).not_to be_nil
    expect(_metric[:in].value).to eq(number_of_events)
    expect(_metric[:filtered].value).to eq(number_of_events)
    expect(_metric[:out].value).to eq(number_of_events)
    STDOUT.puts "  queue.type: #{pipeline_settings_obj.get("queue.type")}"
    STDOUT.puts "  queue.page_capacity: #{pipeline_settings_obj.get("queue.page_capacity") / 1024}KB"
    STDOUT.puts "  workers: #{worker_thread_count}"
    STDOUT.puts "  events: #{number_of_events}"
    STDOUT.puts "  took: #{times.first}s"
  end
end
