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
require './datatarget'
require './sonar'


@options = {
  :verbose => false,
  :datatargets => {
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
    @options[:datatargets][:keen] = v
  end

  opts.on("--[no-]datadog", "Publish data to DataDog\tDefault: true") do |v|
    @options[:datatargets][:datadog] = v
  end

  opts.on("--[no-]databox", "Publish data to Databox\tDefault: true") do |v|
    @options[:datatargets][:databox] = v
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

def verbose?
  @options[:verbose]
end



s = Sonar.new(
  :projects  => @options[:projects], 
  :verbose   => @options[:verbose],
  :from_time => @options[:from_time],
  :to_time   => @options[:to_time]
)
puts "Sonar: #{s.inspect}" if verbose?
collection = :sonar

databox = DataboxTarget.new('DATABOX_TOKEN', 
  :submit_time => Time.parse(s.to_time).strftime("%Y-%m-%d %H:%M:%S"),
  :verbose     => @options[:verbose], 
  :enabled     => @options[:datatargets][:databox])
datadog = DatadogTarget.new('DATADOG_API_KEY', :verbose => @options[:verbose], :enabled => @options[:datatargets][:datadog])
keen    = KeenTarget.new(nil, :verbose => @options[:verbose], :enabled => @options[:datatargets][:keen])

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

log "Data published to #{datatargets.join(',')}" unless datatargets.empty?
