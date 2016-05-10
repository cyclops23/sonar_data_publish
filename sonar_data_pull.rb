#!/usr/bin/env ruby

# Requires the following ENV VARS set:
#    KEEN_PROJECT_ID
#    KEEN_MASTER_KEY
#    KEEN_WRITE_KEY
#    KEEN_READ_KEY
#    SONAR_URL
#    DATABOX_TOKEN
#    DATADOG_API_KEY

require 'rubygems'
require 'bundler/setup'

require 'time'
require 'httparty'
require 'dogapi'
require 'andand'
require 'keen'
require 'databox'
require 'optparse'


@options = {
  :verbose => false,
  :datasources => {
    :keen    => true,
    :datadog => true,
    :databox => true
  },
  :projects => []
}

OptionParser.new do |opts|
  opts.banner = "Usage: sonar_data_pull.rb [options]"

  opts.on("-h", "--help", "Show help") do
    puts opts
    exit
  end

  opts.on("-v", "--[no-]verbose", "Run verbosely\tDefault: false") do |v|
    @options[:verbose] = v
  end

  opts.on("--[no-]keen", "Publish data to Keen.io\tDefault: true") do |v|
    @options[:datasources][:keen] = v
  end

  opts.on("--[no-]datadog", "Publish data to DataDog\tDefault: true") do |v|
    @options[:datasources][:datadog] = v
  end

  opts.on("--[no-]databox", "Publish data to Databox\tDefault: true") do |v|
    @options[:datasources][:databox] = v
  end

  opts.on("-p", "--projects PROJECT_KEYS", "Project filter: comma separated keys") do |p|
    @options[:projects] = p.split(',')
  end
end.parse!

p @options


def log(msg)
  puts "#{Time.now} > #{msg}"
end

def datasources
  @options[:datasources].select{|k,v| v}.keys
end

def is_datasource_enabled?(source)
  @options[:datasources][source] == true
end


class Datasource
  attr_reader :client, :env_token, :options

  def initialize(env_token, opts={})
    @env_token = env_token
    @options   = {
      :verbose => false,
      :enabled => true
    }.merge(opts)

    init_client
  end

  def init_client
  end

  def verbose?
    options[:verbose]
  end

  def enabled?
    options[:enabled]
  end
end

class DataboxSource < Datasource
  def init_client
    puts "env_token: #{ENV[env_token]}"
    Databox.configure do |c| 
      c.push_token = ENV[env_token]
    end

    @client = Databox::Client.new
  end

  def publish(project_key, metrics)
    if enabled?
      metrics.each_pair { |metric, value| puts "client.push(key: #{metric.to_s}, value: #{value}, attributes: { project: #{project_key} })" } if verbose?
      metrics.each_pair { |metric, value| client.push(key: metric.to_s, value: value, attributes: { project: project_key }) }
    end
  end
end

class DatadogSource < Datasource
  def init_client
    @client = Dogapi::Client.new(ENV[env_token])
  end

  def publish(collection, project_key, metrics)
    if enabled?
      metrics.each_pair { |metric, value| puts "client.emit_point \"#{collection.to_s}.#{metric.to_s}\", #{value}, :tags => [\"project:#{project_key}\"]" } if verbose?
      metrics.each_pair { |metric, value| client.emit_point "#{collection.to_s}.#{metric.to_s}", value, :tags => ["project:#{project_key}"] }
    end
  end
end

class KeenSource < Datasource
  def publish(collection, data)
    if enabled?
      puts "keen_data: #{keen_data.inspect}\nkeen_data.class -> #{keen_data.class}" if verbose?
      ::Keen.publish_batch(collection => keen_data)
    end
  end
end


class Sonar
  attr_reader :options

  include HTTParty
  base_uri ENV["SONAR_URL"]

  def initialize(opts={})
    @options   = {
      :verbose  => false,
      :projects => []
    }.merge(opts)

    debug_output $stdout if verbose?
  end

  def verbose?
    options[:verbose]
  end

  DEFAULT_QUERY_OPTS = {:format => "json"}
  ISSUE_SEVERITIES   = ["blocker", "critical", "major", "minor", "info"]

  def self.last_cell_value(http_response)
    #puts "Debug: #{http_response.body}" if options[:verbose]
    JSON.parse(http_response.body).last["cells"].last.andand["v"]
  end

  def today
    Time.now.utc.iso8601
  end

  def yesterday
    (Time.now - 90000).utc.iso8601
  end

  def metrics(metrics,resource,query_opts={})
    options = {
      :query => {
        :metrics      => metrics,
        :resource     => resource,
        :toDateTime   => today,
        :fromDateTime => yesterday
      }.merge(DEFAULT_QUERY_OPTS).merge(query_opts)
    }
    
    self.class.get("/api/timemachine", options)
  end

  def resources(query_opts={})
    options = DEFAULT_QUERY_OPTS.merge(query_opts)

    self.class.get("/api/resources/index", options)
  end

  def projects
    project_keys = JSON.parse(resources(:qualifiers => "TRK").body).collect{|r| r["key"]}
    options[:projects].empty? ? project_keys : project_keys & options[:projects]
  end

  def project_issues(project_key)
    ISSUE_SEVERITIES.inject({}) do |res, sev|
      data = ["#{sev}_violations", "new_#{sev}_violations"].inject({}) do |ires, metric|
        val = Sonar::last_cell_value(metrics(metric, project_key)).andand.first
        val.nil? ? ires : ires.merge(metric.to_sym => val)
      end

      res.merge(data)
    end
  end

  def project_complexity(project_key)
    ["complexity", "class_complexity", "file_complexity", "function_complexity"].inject({}) do |res, metric|
      val = Sonar::last_cell_value(metrics(metric, project_key)).andand.first
      val.nil? ? res : res.merge(metric.to_sym => val)
    end
  end

  def project_duplications(project_key)
    ["duplicated_blocks", "duplicated_files", "duplicated_lines", "duplicated_lines_density"].inject({}) do |res, metric|
      val = Sonar::last_cell_value(metrics(metric, project_key)).andand.first
      val.nil? ? res : res.merge(metric.to_sym => val)
    end
  end

  def quality_gate_map
    {
      "ERROR" => -2,
      "WARN"  => -1,
      "OK"    => 0
    }
  end

  def project_quality_gate(project_key)
    string_val = Sonar::last_cell_value(metrics("alert_status", project_key)).andand.first
    string_val.nil? ? {} : {:quality_gate_status => self.quality_gate_map[string_val]}
  end

  def project_tests(project_key)
    ["coverage", "new_coverage"].inject({}) do |res, metric|
      val = Sonar::last_cell_value(metrics(metric, project_key)).andand.first
      val.nil? ? res : res.merge(metric.to_sym => val)
    end
  end

  def project_tech_debt(project_key)
    ["sqale_index", "sqale_debt_ratio"].inject({}) do |res, metric|
      val = Sonar::last_cell_value(metrics(metric, project_key)).andand.first
      val.nil? ? res : res.merge(metric.to_sym => val)
    end
  end
end



s = Sonar.new(:projects => @options[:projects])
collection = :sonar

databox = DataboxSource.new('DATABOX_TOKEN', :verbose => @options[:verbose], :enabled => @options[:datasources][:databox])
datadog = DatadogSource.new('DATADOG_API_KEY', :verbose => @options[:verbose], :enabled => @options[:datasources][:datadog])
keen    = KeenSource.new(nil, :verbose => @options[:verbose], :enabled => @options[:datasources][:keen])

projects = s.projects
keen_data = projects.inject([]) do |res, project|
  log "project #{project}"
  data = {:project_key => project}

  issues = s.project_issues(project)
  data.merge!(:issues => issues)
  datadog.publish(collection.to_s, project,  issues)
  databox.publish(project, issues)

  complexity = s.project_complexity(project)
  data.merge!(:complexity => complexity)
  datadog.publish(collection.to_s, project,  complexity)
  databox.publish(project, complexity)

  duplications = s.project_duplications(project)
  data.merge!(:duplications => duplications)
  datadog.publish(collection.to_s, project,  duplications)
  databox.publish(project, duplications)

  quality_gate = s.project_quality_gate(project)
  data.merge!(:quality_gate_status => quality_gate)
  datadog.publish(collection.to_s, project,  quality_gate)
  databox.publish(project, quality_gate)

  tests = s.project_tests(project)
  data.merge!(:tests => tests)
  datadog.publish(collection.to_s, project,  tests)
  databox.publish(project, tests)

  tech_debt = s.project_tech_debt(project)
  data.merge!(:tech_debt => tech_debt)
  datadog.publish(collection.to_s, project,  tech_debt)
  databox.publish(project, tech_debt)

  res << data
end

keen.publish(collection, keen_data)

log "Data published to #{datasources.join(',')}" unless datasources.empty?
