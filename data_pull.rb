#!/usr/bin/env ruby

# Requires the following ENV VARS set:
#    KEEN_PROJECT_ID
#    KEEN_MASTER_KEY
#    KEEN_WRITE_KEY
#    KEEN_READ_KEY
#    SONAR_URL
#    DATABOX_TOKEN
#    DATADOG_API_KEY
#    PIVOTAL_TRACKER_TOKEN

require 'rubygems'
require 'bundler/setup'

require 'time'
require 'httparty'
require 'dogapi'
require 'andand'
require 'keen'
require 'databox'
require 'optparse'
require './datatarget'
require './sonar'
require './pivotal_tracker'


@options = {
  :verbose => false,
  :datatargets => {
    :keen    => true,
    :datadog => true,
    :databox => true
  },
  :datasources => {
    :sonar           => true,
    :pivotal_tracker => true
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
    @options[:datatargets][:keen] = v
  end

  opts.on("--[no-]datadog", "Publish data to DataDog\tDefault: true") do |v|
    @options[:datatargets][:datadog] = v
  end

  opts.on("--[no-]databox", "Publish data to Databox\tDefault: true") do |v|
    @options[:datatargets][:databox] = v
  end

  opts.on("--[no-]sonar", "Pull data from Sonar\tDefault: true") do |v|
    @options[:datasources][:sonar] = v
  end

  opts.on("--[no-]pivotal_tracker", "Pull data from PivotalTracker\tDefault: true") do |v|
    @options[:datasources][:pivotal_tracker] = v
  end

  opts.on("-p", "--projects PROJECT_KEYS", "Project filter: comma separated keys") do |p|
    @options[:projects] = p.split(',')
  end

  opts.on("-f", "--from_time SECONDS_AGO", "Seconds ago queries should start") do |t|
    @options[:from_time] = (Time.now - t.to_i).utc.iso8601
  end

  opts.on("-t", "--to_time SECONDS_AGO", "Seconds ago queries should end") do |t|
    @options[:to_time] = (Time.now - t.to_i).utc.iso8601
  end
end.parse!

p @options

def log(msg)
  puts "#{Time.now} > #{msg}"
end

def datatargets
  @options[:datatargets].select{|k,v| v}.keys
end

def is_datatarget_enabled?(target)
  @options[:datatargets][target] == true
end

def is_datasource_enabled?(source)
  @options[:datasources][source] == true
end

def verbose?
  @options[:verbose]
end

#
# Data targets
#
databox = DataboxTarget.new('DATABOX_TOKEN', 
  :submit_time => @options[:to_time].nil? ? nil : Time.parse(@options[:to_time]).strftime("%Y-%m-%d %H:%M:%S"),
  :verbose     => @options[:verbose], 
  :enabled     => @options[:datatargets][:databox])
datadog = DatadogTarget.new('DATADOG_API_KEY', :verbose => @options[:verbose], :enabled => @options[:datatargets][:datadog])
keen    = KeenTarget.new(nil, :verbose => @options[:verbose], :enabled => @options[:datatargets][:keen])

#
# Data sources
#

# Sonar
if is_datasource_enabled?(:sonar)
  s = Sonar.new(
    :projects  => @options[:projects], 
    :verbose   => @options[:verbose],
    :from_time => @options[:from_time],
    :to_time   => @options[:to_time]
  )
  puts "Sonar: #{s.inspect}" if verbose?
  collection = :sonar

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
end

# Pivotal Tracker
# ONLY SUPPORT SINGLE DAY VIEW
if is_datasource_enabled?(:pivotal_tracker)
  pt = PivotalTracker.new(ENV['PIVOTAL_TRACKER_TOKEN'])
  pt.project_ids.each_pair { |project_id, project_name| pt.history(project_id).last.reject{|k,v| k == "date"}.each_pair {|metric_name, metric_value| databox.publish(project_name, {metric_name => metric_value}) } }
end

log "Data published to #{datatargets.join(',')}" unless datatargets.empty?
