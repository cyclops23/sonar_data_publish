#!/usr/bin/env ruby

# Requires the following ENV VARS set:
#    KEEN_PROJECT_ID
#    KEEN_MASTER_KEY
#    KEEN_WRITE_KEY
#    KEEN_READ_KEY
#    SONAR_URL

require 'rubygems'
require 'bundler/setup'

require 'time'
require 'httparty'
require 'statsd'
require 'andand'
require 'keen'


class Sonar
  include HTTParty
  base_uri ENV["SONAR_URL"]

  DEFAULT_QUERY_OPTS = {:format => "json"}
  ISSUE_SEVERITIES   = ["blocker", "critical", "major", "minor", "info"]

  def self.last_cell_value(http_response)
    #puts "Debug: #{http_response.body}"
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
        #:fromDateTime => yesterday
      }.merge(DEFAULT_QUERY_OPTS).merge(query_opts)
    }
    
    self.class.get("/api/timemachine", options)
  end

  def resources(query_opts={})
    options = DEFAULT_QUERY_OPTS.merge(query_opts)

    self.class.get("/api/resources/index", options)
  end

  def projects
    JSON.parse(resources(:qualifiers => "TRK").body).collect{|r| r["key"]}
  end

  def project_issues(project_key)
    ISSUE_SEVERITIES.inject({}) do |res, sev|
      num_violations = Sonar::last_cell_value(metrics("#{sev}_violations", project_key)).andand.first
      num_violations.nil? ? res : res.merge("#{sev}_violation_count".to_sym => num_violations)
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
end

DATADOG_CLIENT = Statsd.new

def submit_datadog_metrics(type, collection, project_key, metrics)
  metrics.each_pair { |metric, value| DATADOG_CLIENT.send type, "#{collection.to_s}.#{metric.to_s}", value, :tags => ["project:#{project_key}"] }
end


s = Sonar.new
collection = :sonar

projects = s.projects
keen_data = projects.inject([]) do |res, project|
  data = {:project_key => project}

  issues = s.project_issues(project)
  data.merge!(:issues => issues)
  submit_datadog_metrics(:gauge, collection.to_s, project,  issues)

  complexity = s.project_complexity(project)
  data.merge!(:complexity => complexity)
  submit_datadog_metrics(:gauge, collection.to_s, project,  complexity)

  duplications = s.project_duplications(project)
  data.merge!(:duplications => duplications)
  submit_datadog_metrics(:gauge, collection.to_s, project,  duplications)

  res << data
end

#puts "keen_data: #{keen_data.inspect}"
#puts "keen_data.class -> #{keen_data.class}"
Keen.publish_batch(collection => keen_data)

puts "Data published to DataDog and Keen"
